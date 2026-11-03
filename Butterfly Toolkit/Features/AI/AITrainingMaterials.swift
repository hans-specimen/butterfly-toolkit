import AppKit
import UniformTypeIdentifiers

extension AIWorkspaceStore {
    func choosePSDs(correction: Bool = false) {
        guard !busy, catalog != nil else { return }
        let panel = NSOpenPanel()
        panel.title = correction ? "读取在 Photoshop 中保存的修正" : "导入三层训练 PSD"
        panel.message = correction
            ? "先在 Photoshop 保存。读取后自动检查，再由你确认标准答案。"
            : "自上而下：第一层参考答案、第二层原始底图、第三层背景。其他结构直接提示提取失败。"
        panel.allowedContentTypes = [UTType(filenameExtension: "psd") ?? .data]
        panel.allowsMultipleSelection = true
        panel.directoryURL = workspaceURL.appendingPathComponent(correction ? "PS修正" : "待处理PSD")
        guard panel.runModal() == .OK else { return }
        Task { await importPSDs(panel.urls, correction: correction) }
    }

    func importPSDs(_ urls: [URL], correction: Bool = false) async {
        guard !busy, catalog != nil, !urls.isEmpty else { return }
        isLoading = true; error = nil; importSummary = []
        defer { isLoading = false }
        var added = 0
        for (index, url) in urls.enumerated() {
            status = "检查 \(index + 1)/\(urls.count)：\(url.lastPathComponent)…"
            do {
                let event = try await AIProcessRunner().run(engine: engineURL,
                    arguments: [correction ? "import-correction" : "import-psd", "--input", url.path], workspace: workspaceURL) { _ in }
                guard let sample = event.sample, sample.reference != nil, sample.alpha != nil, sample.psdHash != nil else {
                    throw AIWorkspaceError(message: "PSD 提取没有返回完整素材记录。")
                }
                if samples.contains(where: { $0.id == sample.id }) {
                    selectedID = sample.id
                    importSummary.append("\(url.lastPathComponent)：已在素材库中，跳过重复导入")
                    continue
                }
                curation.imported.append(sample)
                curation.samples[sample.id] = AISampleCuration(referenceKind: sample.materialKind ?? "人工精扣 PSD")
                samples.append(sample); selectedID = sample.id
                guard saveCuration() else {
                    curation.imported.removeAll { $0.id == sample.id }; curation.samples.removeValue(forKey: sample.id)
                    samples.removeAll { $0.id == sample.id }; selectedID = nil
                    throw AIWorkspaceError(message: error ?? "素材记录未保存；请重试导入，已有导出不会覆盖。")
                }
                added += 1
                importSummary.append("\(url.lastPathComponent)：\(sample.alignmentTitle) · 待确认答案")
            } catch {
                importSummary.append("\(url.lastPathComponent)：提取失败 · \(error.localizedDescription)")
            }
        }
        status = "已导入 \(added) 份 · 详细检查结果见素材页"
        do {
            let directory = workspaceURL.appendingPathComponent("outputs/素材检查")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try importSummary.joined(separator: "\n").write(to: directory.appendingPathComponent("导入-\(UUID().uuidString).txt"), atomically: true, encoding: .utf8)
        } catch { self.error = "导入检查报告未保存：\(error.localizedDescription)" }
    }

    var pendingAnswerCount: Int {
        pairedSamples.filter { materialSelection.contains($0.id) && $0.answerConfirmed != true }.count
    }

    func confirmSelectedAnswers() async {
        guard !busy else { return }
        let snapshot = pairedSamples.filter { materialSelection.contains($0.id) }
        guard !snapshot.isEmpty else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        status = "正在复核所选 \(snapshot.count) 份答案…"
        let checked = await Task.detached { snapshot.map(AIFileValidation.revalidateImported) }.value
        var confirmed = 0
        var failures: [String] = []
        for item in checked {
            guard let index = samples.firstIndex(where: { $0.id == item.id }),
                  let importedIndex = curation.imported.firstIndex(where: { $0.id == item.id }) else {
                failures.append("\(item.name)：素材记录缺失，请重新导入")
                continue
            }
            var updated = item
            updated.answerConfirmed = item.alignment == "aligned" && item.reference != nil
            samples[index] = updated; curation.imported[importedIndex] = updated
            if updated.answerConfirmed == true { confirmed += 1 }
            else {
                trainingSelection.remove(item.id)
                failures.append("\(item.name)：\(item.alignmentTitle) · \(item.alignmentNote)")
            }
        }
        guard saveCuration() else {
            // Failed persistence must not leave newly approved answers eligible in memory.
            for original in snapshot {
                guard let index = samples.firstIndex(where: { $0.id == original.id }),
                      let importedIndex = curation.imported.firstIndex(where: { $0.id == original.id }),
                      samples[index].answerConfirmed == true else { continue }
                samples[index].answerConfirmed = original.answerConfirmed
                curation.imported[importedIndex].answerConfirmed = original.answerConfirmed
            }
            status = "答案确认未保存，请重试"
            return
        }
        status = "已确认 \(confirmed) 份标准答案，可用于训练" + (failures.isEmpty ? "" : " · \(failures.count) 份未通过")
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func editSelectedInPhotoshop() {
        guard !busy, let sample = selected, let prediction = sample.prediction else { return }
        isLoading = true; error = nil; status = "正在创建三层 Photoshop 修正文件…"
        Task {
            defer { isLoading = false }
            do {
                let key = try await Task.detached { try AIFileValidation.correctionKey(sample) }.value
                if let path = curation.corrections?[key], FileManager.default.fileExists(atPath: path) {
                    openInPhotoshop(path)
                    return
                }
                let event = try await AIProcessRunner().run(engine: engineURL,
                    arguments: ["create-correction", "--input", sample.original, "--prediction", prediction], workspace: workspaceURL) { _ in }
                guard let path = event.correctionPSD else { throw AIWorkspaceError(message: "没有生成修正 PSD。") }
                guard key == (try await Task.detached { try AIFileValidation.correctionKey(sample) }.value) else {
                    throw AIWorkspaceError(message: "原图或 AI 结果已变化，请重新打开修正流程。")
                }
                if curation.corrections == nil { curation.corrections = [:] }
                curation.corrections?[key] = path
                guard saveCuration() else { return }
                openInPhotoshop(path)
            } catch { self.error = error.localizedDescription; status = "创建修正文件失败" }
        }
    }

    func refreshTrainingEligibility() async {
        guard !busy else { return }
        isLoading = true
        defer { isLoading = false }
        let snapshot = samples
        let checked = await Task.detached { snapshot.map(AIFileValidation.revalidateImported) }.value
        var changed = false
        for item in checked {
            guard let index = samples.firstIndex(where: { $0.id == item.id }) else { continue }
            if samples[index].alignment != item.alignment || samples[index].answerConfirmed != item.answerConfirmed {
                samples[index] = item
                if let importedIndex = curation.imported.firstIndex(where: { $0.id == item.id }) {
                    curation.imported[importedIndex] = item
                }
                changed = true
            }
        }
        trainingSelection = trainingSelection.filter { id in samples.contains { $0.id == id && canTrain($0) } }
        if changed {
            saveCuration()
            status = "素材已变化，相关答案确认和训练选择已撤销；请重新检查导入"
        }
    }

    func selectForTraining(_ sample: AISample, enabled: Bool) async {
        if !enabled { trainingSelection.remove(sample.id); return }
        guard !busy else { return }
        await refreshTrainingEligibility()
        if let current = samples.first(where: { $0.id == sample.id }), canTrain(current) {
            trainingSelection.insert(sample.id)
        }
    }

    private func openInPhotoshop(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            error = "没有找到 Photoshop。修正文件已保存在 PS修正 目录，可安装后继续打开。"
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: .init()) { [weak self] _, failure in
            Task { @MainActor in
                if let failure { self?.error = "Photoshop 打开失败：\(failure.localizedDescription)" }
                else { self?.status = "请修正第一层并保存，再点击“读取 PS 修正”" }
            }
        }
    }
}
