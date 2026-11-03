import Foundation

extension AIWorkspaceStore {
    var trainedModels: [AITrainingRun] { trainingRuns.filter(\.isUsable) }
    var canStartTraining: Bool {
        !busy && catalog?.model.available == true && !taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !trainingSelection.isEmpty && trainingSelection.allSatisfy { id in trainingCandidates.contains { $0.id == id } }
    }

    func selectAllForTraining() async {
        guard !busy else { return }
        await refreshTrainingEligibility()
        trainingSelection = Set(trainingCandidates.map(\.id))
    }

    func loadTrainingHistory() async {
        guard !enginePath.isEmpty else { return }
        do {
            let event = try await AIProcessRunner().run(engine: engineURL, arguments: ["training-history"], workspace: workspaceURL) { _ in }
            trainingRuns = event.trainingRuns ?? []
            if !isTraining { currentTraining = trainingRuns.first }
            if inferenceModelID != "base" && !trainedModels.contains(where: { $0.id == inferenceModelID }) { inferenceModelID = "base" }
        } catch { self.error = "训练记录读取失败：\(error.localizedDescription)" }
    }

    func startTraining() {
        guard canStartTraining else { return }
        isTraining = true; error = nil; currentTraining = nil
        status = "正在检查训练素材…"
        let worker = AIProcessRunner(); trainingRunner = worker
        let selectedIDs = samples.filter { trainingSelection.contains($0.id) }.map(\.id)
        let request: [String: Any] = ["name": taskName, "sampleIDs": selectedIDs,
                                     "epochs": trainingEpochs, "inputSize": trainingInputSize,
                                     "learningRate": 0.00001, "device": "cpu", "parentPID": ProcessInfo.processInfo.processIdentifier]
        let engine = engineURL, workspace = workspaceURL
        trainingOperation = Task {
            defer { isTraining = false; trainingRunner = nil; trainingOperation = nil }
            do {
                // Persist approval records before the backend independently rechecks every selected file.
                guard saveCuration() else { throw AIWorkspaceError(message: error ?? "素材确认记录未保存") }
                let folder = workspace.appendingPathComponent("outputs/toolkit-ai/requests")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent("\(UUID().uuidString).json")
                try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: path, options: .atomic)
                let event = try await worker.run(engine: engine, arguments: ["train", "--request", path.path], workspace: workspace) { [self] event in
                    if let run = event.trainingRun { await self.receiveTraining(run) }
                }
                guard let run = event.trainingRun else { throw AIWorkspaceError(message: "训练进程结束但未返回任务结果。") }
                receiveTraining(run)
            } catch is CancellationError {
                status = "训练已停止"
            } catch {
                self.error = error.localizedDescription; status = "训练未完成：\(error.localizedDescription)"
            }
            // The persisted record is authoritative, including cancellation and failure.
            await loadTrainingHistory()
        }
    }

    func receiveTraining(_ run: AITrainingRun) {
        currentTraining = run
        status = run.message
        trainingRuns.removeAll { $0.id == run.id }
        trainingRuns.insert(run, at: 0)
    }

    func stopTraining() {
        guard isTraining else { return }
        status = "正在停止训练，等待当前计算结束…"
        trainingRunner?.cancel()
    }
}
