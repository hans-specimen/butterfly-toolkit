import XCTest
import Darwin
@testable import Butterfly_Toolkit

private nonisolated final class PipelinePublications: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [Double] = []
    func measure(_ body: () throws -> WorkflowArtifact) throws -> WorkflowArtifact {
        let start = ProcessInfo.processInfo.systemUptime,result = try body()
        lock.withLock { seconds.append(ProcessInfo.processInfo.systemUptime-start) }; return result
    }
    func values() -> [Double] { lock.withLock { seconds } }
}

private actor PipelineMeasurements {
    struct Sample: Codable, Sendable { let stage: String; let start: Double; let seconds: Double }
    let origin = ProcessInfo.processInfo.systemUptime
    var samples: [Sample] = []
    func measure<T: Sendable>(_ stage: String,_ body: @Sendable () async throws -> T) async throws -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await body()
        samples.append(Sample(stage: stage,start: start-origin,seconds: ProcessInfo.processInfo.systemUptime-start))
        return result
    }
    func save(_ url: URL) throws { try JSONEncoder().encode(samples).write(to: url) }
}

@MainActor final class WorkflowPipelinePerformanceTests: XCTestCase {
    /// Starts from identical immutable stacks, so focus-stack variability cannot mask scheduling differences.
    func testRealPipelineFromSavedStacksWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let batchPath = env["WORKFLOW_PIPELINE_BATCH"],let rawPath = env["WORKFLOW_PIPELINE_STACKS"],
              let destination = env["WORKFLOW_PIPELINE_EVIDENCE"],let enginePath = env["WORKFLOW_PIPELINE_ENGINE"] else {
            throw XCTSkip("Real Photoshop/MPS pipeline measurement is opt-in")
        }
        let count = Int(env["WORKFLOW_PIPELINE_COUNT"] ?? "4")!,limit = Int(env["WORKFLOW_PIPELINE_LIMIT"] ?? "2")!
        let pauseEnabled = env["WORKFLOW_PIPELINE_PAUSE"] == "1"
        guard [1,2,4].contains(count),[1,2].contains(limit) else { throw WorkflowStateError.invalidTransition }
        guard !pauseEnabled || (count == 2 && limit == 2) else { throw WorkflowStateError.invalidTransition }
        let root = URL(fileURLWithPath: destination),fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        try fm.createDirectory(at: root,withIntermediateDirectories: true)
        let reference = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        try reference.validate()
        let raw = try JSONDecoder().decode([[String:String]].self,from: Data(contentsOf: URL(fileURLWithPath: rawPath)))
        let ps = PhotoshopExecutionCoordinator(),workspace = root.appendingPathComponent(".work")
        let pauseGate = WorkflowPipelineProbe()
        let bridge = PhotoshopWorkflowBridge(workspace: workspace,coordinator: ps,installCheckpoint: { checkpoint in
            if pauseEnabled {
                switch checkpoint {
                case .prepared: await pauseGate.mark("prepared"); await pauseGate.hold("finish-install")
                case .published: await pauseGate.mark("install-published")
                }
            }
        })
        let worker = AIInferenceWorker(),matte = WorkflowMatteService(engine: URL(fileURLWithPath: enginePath),workspace: workspace,worker: worker)
        let setupStart = ProcessInfo.processInfo.systemUptime
        var specimens: [WorkflowSpecimen] = []
        for specimen in reference.specimens.prefix(max(1,count/2)) {
            var pair: [WorkflowSideTask] = []
            for old in [specimen.front,specimen.back] {
                var sources: [WorkflowSourceFile] = []
                for source in old.sources.files {
                    let copy = root.appendingPathComponent("origin/"+source.url.lastPathComponent)
                    try fm.createDirectory(at: copy.deletingLastPathComponent(),withIntermediateDirectories: true)
                    try fm.copyItem(at: source.url,to: copy)
                    XCTAssertEqual(try AIFileValidation.hash(copy.path),source.fingerprint)
                    sources.append(WorkflowSourceFile(url: copy,fingerprint: source.fingerprint))
                }
                var task = WorkflowSideTask(side: old.side,sources: WorkflowSources(first: sources[0],second: sources[1],third: sources[2]))
                let name = specimen.baseName+"_"+old.side.fileSuffix
                let alreadyMatted = count == 1 && old.side == .back
                let source = alreadyMatted ? try XCTUnwrap(old.snapshot).snapshotURL : URL(fileURLWithPath: try XCTUnwrap(raw.first { $0["name"] == name }?["source"]))
                let document = root.appendingPathComponent(name+".psd")
                try fm.copyItem(at: source,to: document)
                try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath: document.path)
                var ownership: [String:Any] = ["owner":task.id.uuidString]
                if alreadyMatted { ownership["roles"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(old.snapshot?.roles))) }
                try JSONSerialization.data(withJSONObject: ownership).write(to: document.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
                task.snapshot = try await bridge.refreshSavedPSD(document: document,owner: task.id)
                task[.stack].state = .completed; task[.stack].outputVersion = task.snapshot!.contentVersion; task[.stack].confirmedVersion = task.snapshot!.contentVersion
                if alreadyMatted {
                    task[.matte].state = .completed; task[.matte].outputVersion = task.snapshot!.contentVersion
                } else { XCTAssertNil(task.snapshot?.roles) }
                pair.append(task)
            }
            specimens.append(WorkflowSpecimen(baseName: specimen.baseName,front: pair[0],back: pair[1]))
        }
        var batch = WorkflowBatch(sourceDirectory: root.appendingPathComponent("origin"),outputDirectory: root,checkAfterStack: false,checkAfterMatte: count == 1,specimens: specimens)
        batch.checkGeometry = false; batch.check4K = false
        let measures = PipelineMeasurements(),publications = PipelinePublications(),base = WorkflowExecutor.Services.live(bridge: bridge,matte: matte)
        var services = base
        services.exportStack = { s in try await measures.measure("exportStack") { try await base.exportStack(s) } }
        services.infer = { s in try await measures.measure("infer") { try await base.infer(s) } }
        services.install = { s,m in try await measures.measure("install") { try await base.install(s,m) } }
        services.extract = { s in try await measures.measure("extract") { try await base.extract(s) } }
        services.analyze = { s,r in try await measures.measure("analyze") { try await base.analyze(s,r) } }
        services.validateGeometry = { s,r in try await measures.measure("validateGeometry") { try await base.validateGeometry(s,r) } }
        services.apply = { s,r in try await measures.measure("apply") { try await base.apply(s,r) } }
        services.render = { k,r,l,s,w,u in try await measures.measure("render-"+k.rawValue) { try await base.render(k,r,l,s,w,u) } }
        // Publication remains synchronous inside the executor's version fence.
        services.publish = { temp,artifact in try publications.measure { try base.publish(temp,artifact) } }
        let e = WorkflowExecutor(services: services,coordinator: ps,exportLimit: limit,matteLimit: limit)
        let manifest = root.appendingPathComponent("batch.json")
        try await e.register(batch: batch,manifestURL: manifest)
        let setup = ProcessInfo.processInfo.systemUptime-setupStart,started = ProcessInfo.processInfo.systemUptime
        let after: WorkflowBatch
        if pauseEnabled {
            let run = Task { try await e.runPending(batchID: batch.id) }
            for _ in 0..<6000 {
                if await pauseGate.contains("prepared") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let prepared = await pauseGate.contains("prepared")
            guard prepared else {
                await e.pause(batchID: batch.id); await pauseGate.release("finish-install"); _ = try? await run.value
                throw WorkflowBridgeError.invalidImage("Timed out waiting for the real install transaction")
            }
            let pauseStart = ProcessInfo.processInfo.systemUptime
            await e.pause(batchID: batch.id)
            let pauseSeconds = ProcessInfo.processInfo.systemUptime-pauseStart,owner = batch.activeTasks[0].id
            let manualStart = ProcessInfo.processInfo.systemUptime
            let manual = Task { try await ps.beginManualEditing(owner: owner); await pauseGate.mark("manual-granted") }
            let grantedEarly = await pauseGate.contains("manual-granted"); XCTAssertFalse(grantedEarly)
            await pauseGate.release("finish-install"); try await run.value; try await manual.value
            let pauseEvents = await pauseGate.events
            XCTAssertLessThan(try XCTUnwrap(pauseEvents.firstIndex(of: "install-published")),try XCTUnwrap(pauseEvents.firstIndex(of: "manual-granted")))
            let manualSeconds = ProcessInfo.processInfo.systemUptime-manualStart
            let paused = try await e.batch(batchID: batch.id),cached = paused.activeTasks.compactMap(\.matteArtifact)
            XCTAssertTrue(paused.isPaused); XCTAssertGreaterThanOrEqual(cached.count,1)
            XCTAssertFalse(paused.activeTasks.contains { $0[.matte].state == .running })
            XCTAssertFalse(paused.sideTasks.flatMap(\.artifacts).contains { $0.state == .completed })
            let callsBefore = await measures.samples.filter { $0.stage == "infer" }.count
            await ps.endManualEditing(owner: owner)
            let reopened = WorkflowExecutor(services: services,coordinator: ps,exportLimit: limit,matteLimit: limit)
            _ = try await reopened.register(manifestURL: manifest)
            try await reopened.continueAutomatic(batchID: batch.id)
            after = try await reopened.batch(batchID: batch.id)
            let callsAfter = await measures.samples.filter { $0.stage == "infer" }.count
            XCTAssertEqual(callsAfter-callsBefore,2-cached.count,"Only inference without a durable result may repeat")
            let installs = await measures.samples.filter { $0.stage == "install" }.count
            XCTAssertEqual(installs,2,"Recovery must validate the published PSD instead of installing it again")
            for saved in cached {
                XCTAssertEqual(try AIFileValidation.hash(saved.alphaURL.path),saved.alphaFingerprint)
                XCTAssertEqual(try AIFileValidation.hash(saved.cutoutURL.path),saved.cutoutFingerprint)
            }
            let pauseRecord: [String:Any] = ["pauseSeconds":pauseSeconds,"manualLeaseWaitSeconds":manualSeconds,"durableInferenceCount":cached.count,"additionalSuccessfulInferenceCalls":callsAfter-callsBefore,"successfulInstallCalls":installs,"events":pauseEvents,"allSucceededAfterRestart":after.allSucceeded]
            try JSONSerialization.data(withJSONObject: pauseRecord,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("pause.json"))
        } else {
            do { try await e.runPending(batchID: batch.id) }
            catch { await matte.shutdown(); throw error }
            after = try await e.batch(batchID: batch.id)
        }
        let seconds = ProcessInfo.processInfo.systemUptime-started
        await matte.shutdown()
        try await measures.save(root.appendingPathComponent("stages.json"))
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        let summary: [String:Any] = ["count":count,"limit":limit,"seconds":seconds,"setupSeconds":setup,"publicationSeconds":publications.values(),"appPeakRSSBytes":usage.ru_maxrss,"allSucceeded":after.allSucceeded,"singleFaceMatteCheckpoint":count == 1]
        try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("performance.json"))
        if count == 1 { XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview }) }
        else { XCTAssertTrue(after.allSucceeded,"Inspect the retained manifest for failed stages") }
        XCTAssertEqual(after.sideTasks.count,max(2,count))
    }
}
