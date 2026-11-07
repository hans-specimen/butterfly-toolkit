import XCTest
import Darwin
@testable import Butterfly_Toolkit

@MainActor final class AIInferenceWorkerTests: XCTestCase {
    func testTwoRequestsShareOneProcessAndShutdownWaitsForExit() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        let first = try await worker.infer(f.request("one"))
        let second = try await worker.infer(f.request("two"))
        XCTAssertEqual(first.input,f.request("one").input.path); XCTAssertEqual(second.input,f.request("two").input.path)
        await worker.shutdown(); await worker.shutdown()
        XCTAssertEqual(try f.starts().count,1)
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1,"shutdown must reap the worker") }
    }
    func testQueuedCancellationKeepsActiveRequestAndLease() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        let first = Task { try await worker.infer(f.request("hold")) }
        try await waitUntil { f.events().contains("hold") }
        let queued = Task { try await worker.infer(f.request("cancelled")) }
        try await waitUntil { await worker.queuedCount == 1 }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(f.events().contains("cancelled")); XCTAssertEqual(try f.starts().count,1)
        try Data().write(to: f.root.appendingPathComponent("release"))
        _ = try await first.value; _ = try await worker.infer(f.request("last"))
        await worker.shutdown(); XCTAssertEqual(try f.starts().count,1)
    }
    func testActiveCancellationTerminatesWorkerAndClearsQueueThenExplicitRetryRestarts() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        let first = Task { try await worker.infer(f.request("ignore-term-hold")) }
        try await waitUntil { f.events().contains("ignore-term-hold") }
        let queued = Task { try await worker.infer(f.request("queued")) }
        try await waitUntil { await worker.queuedCount == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        await worker.shutdown()
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1) }
        _ = try await worker.infer(f.request("retry")); await worker.shutdown()
        XCTAssertEqual(try f.starts().count,2); XCTAssertFalse(f.events().contains("queued"))
    }
    func testInvalidProtocolOrExitFailsQueueWithoutAutomaticRestart() async throws {
        for mode in ["wrong-id","wrong-input","malformed","exit","wrong-order"] {
            let f = try Fixture(); defer { f.remove() }
            let worker = AIInferenceWorker()
            let first = Task { try await worker.infer(f.request(mode+"-hold")) }
            try await waitUntil { f.events().contains(mode+"-hold") }
            let queued = Task { try await worker.infer(f.request("queued")) }
            try await waitUntil { await worker.queuedCount == 1 }
            try Data().write(to: f.root.appendingPathComponent("release"))
            do { _ = try await first.value; XCTFail("Invalid protocol accepted: \(mode)") } catch {}
            do { _ = try await queued.value; XCTFail("Queue survived broken worker") } catch {}
            await worker.shutdown(); XCTAssertEqual(try f.starts().count,1)
            XCTAssertFalse(f.events().contains("queued"))
            _ = try await worker.infer(f.request("retry")); await worker.shutdown()
            XCTAssertEqual(try f.starts().count,2)
        }
    }
    func testRequestErrorAndLargeStderrDoNotMislabelNextRequest() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        do { _ = try await worker.infer(f.request("error")); XCTFail("Expected request error") } catch {}
        let result = try await worker.infer(f.request("stderr"))
        XCTAssertEqual(result.input,f.request("stderr").input.path)
        await worker.shutdown(); XCTAssertEqual(try f.starts().count,1)
    }
    func testConcurrentRequestsExecuteOneAtATime() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        let first = Task { try await worker.infer(f.request("hold")) }
        try await waitUntil { f.events().contains("hold") }
        let second = Task { try await worker.infer(f.request("second")) }
        try await waitUntil { await worker.queuedCount == 1 }
        XCTAssertFalse(f.events().contains("second"))
        try Data().write(to: f.root.appendingPathComponent("release"))
        _ = try await first.value; _ = try await second.value
        await worker.shutdown(); XCTAssertEqual(try f.starts().count,1)
        XCTAssertEqual(f.events().split(separator: "\n"),["hold","second"])
    }
    func testCancellationDuringStartupAndRepeatedShutdown() async throws {
        let f = try Fixture(); defer { f.remove() }
        try Data().write(to: f.root.appendingPathComponent("hold-ready"))
        let worker = AIInferenceWorker(),request = f.request("one")
        let pending = Task { try await worker.infer(request) }
        try await waitUntil { (try? f.starts().count) == 1 }
        async let first: Void = worker.shutdown()
        async let second: Void = worker.shutdown()
        _ = await (first,second)
        do { _ = try await pending.value; XCTFail("Startup must be cancelled") } catch is CancellationError {}
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1) }
    }
    func testPauseDuringInferenceWaitsForWorkerExit() async throws {
        let f = try Fixture(); defer { f.remove() }
        let workflow = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: workflow.batch.outputDirectory) }
        let worker = AIInferenceWorker()
        var services = workflow.services
        let infer = services.infer
        services.infer = { input in _ = try await worker.infer(f.request("hold")); return try await infer(input) }
        services.endInferenceSession = { await worker.shutdown() }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: workflow.batch,manifestURL: workflow.manifest)
        let running = Task { try await executor.runPending(batchID: workflow.batch.id) }
        try await waitUntil { f.events().contains("hold") }
        await executor.pause(batchID: workflow.batch.id)
        try await running.value
        let calls = await workflow.probe.values()
        XCTAssertFalse(calls.contains("ai"),"Paused inference must not complete after its worker exits")
        let paused = try await executor.batch(batchID: workflow.batch.id)
        XCTAssertTrue(paused.isPaused)
        XCTAssertTrue(paused.activeTasks.allSatisfy { $0[.matte].state != .failed })
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1) }
    }
    func testConcurrentIdleShutdownBothWaitForProcessExit() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        _ = try await worker.infer(f.request("ignore-term-idle"))
        let first = Task { await worker.shutdown() }
        try await waitUntil { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("term").path) }
        await worker.shutdown()
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1,"Every shutdown caller must wait for exit, including idle sessions") }
        await first.value
    }
    func testExecutorDoesNotRestartCrashedWorkerForNextAutomaticFace() async throws {
        let f = try Fixture(); defer { f.remove() }
        let workflow = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: workflow.batch.outputDirectory) }
        let worker = AIInferenceWorker()
        var services = workflow.services
        let infer = services.infer
        services.infer = { input in
            let mode = await workflow.probe.values().contains("user-retry") ? "success" : "exit"
            _ = try await worker.infer(f.request(mode))
            return try await infer(input)
        }
        services.endInferenceSession = { await worker.shutdown() }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: workflow.batch,manifestURL: workflow.manifest)
        try await executor.runPending(batchID: workflow.batch.id)
        XCTAssertEqual(try f.starts().count,1,"The next automatic face must not restart a crashed process")
        await workflow.probe.record("user-retry")
        try await executor.retry(batchID: workflow.batch.id,specimenIDs: workflow.batch.specimens.map(\.id),stage: .matte)
        XCTAssertEqual(try f.starts().count,2,"An explicit retry may start a new session shared by both faces")
        let recovered = try await executor.batch(batchID: workflow.batch.id)
        XCTAssertTrue(recovered.activeTasks.allSatisfy { $0[.matte].state == .completed })
    }
    func testShutdownDuringFatalCleanupAllowsExplicitNewSession() async throws {
        let f = try Fixture(); defer { f.remove() }
        let worker = AIInferenceWorker()
        let failed = Task { try await worker.infer(f.request("wrong-id-ignore-term")) }
        try await waitUntil { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("term").path) }
        async let first: Void = worker.shutdown()
        async let second: Void = worker.shutdown()
        _ = await (first,second)
        do { _ = try await failed.value; XCTFail("Expected protocol failure") } catch {}
        _ = try await worker.infer(f.request("retry")); await worker.shutdown()
        XCTAssertEqual(try f.starts().count,2)
        for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1) }
    }
    func testRealMatteWorkerWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["WORKFLOW_WORKER_REAL_INPUT"],let evidencePath = environment["WORKFLOW_WORKER_REAL_EVIDENCE"],
              let enginePath = environment["WORKFLOW_WORKER_REAL_ENGINE"] else { throw XCTSkip("Real MPS worker service test is opt-in") }
        let workspace = URL(fileURLWithPath: evidencePath),source = URL(fileURLWithPath: sourcePath)
        guard !FileManager.default.fileExists(atPath: workspace.path) else { throw WorkflowBridgeError.ownershipConflict }
        let inputURL = workspace.appendingPathComponent("data/processed/input.png")
        try FileManager.default.createDirectory(at: inputURL.deletingLastPathComponent(),withIntermediateDirectories: true)
        let originalHash = try AIFileValidation.hash(source.path)
        try FileManager.default.copyItem(at: source,to: inputURL)
        let raster = try WorkflowRaster.read(inputURL)
        let input = StackPNG(snapshotVersion: "task8-real",pngURL: inputURL,fingerprint: originalHash,pixelSize: raster.size,orientation: raster.orientation,colorProfile: raster.profileName ?? "embedded ICC")
        let service = WorkflowMatteService(engine: URL(fileURLWithPath: enginePath),workspace: workspace)
        let started = Date(),result: MatteArtifact
        do { result = try await service.infer(input: input) }
        catch { await service.shutdown(); throw error }
        await service.shutdown()
        XCTAssertEqual(result.inputPNGFingerprint,originalHash)
        XCTAssertEqual(try AIFileValidation.hash(source.path),originalHash)
        XCTAssertEqual(try AIFileValidation.hash(inputURL.path),originalHash)
        let summary: [String:Any] = ["seconds":Date().timeIntervalSince(started),"alpha":result.alphaURL.path,"cutout":result.cutoutURL.path,"inputSHA256":originalHash]
        try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: workspace.appendingPathComponent("service-validation.json"))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AIWorkspaceError(message: "Timed out waiting for fake worker")
    }
    struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-\(UUID())")
            for name in [".venv/bin","scripts","data/processed"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name),withIntermediateDirectories: true) }
            let executable = root.appendingPathComponent(".venv/bin/python")
            try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: executable,atomically: true,encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: executable.path)
            try Self.script.write(to: root.appendingPathComponent("scripts/toolkit_bridge.py"),atomically: true,encoding: .utf8)
        }
        func request(_ name: String) -> WorkflowInferenceRequest { WorkflowInferenceRequest(engine: root,workspace: root,input: root.appendingPathComponent("data/processed/"+name),device: "cpu") }
        func starts() throws -> [Int32] { try String(contentsOf: root.appendingPathComponent("starts"),encoding: .utf8).split(separator: "\n").compactMap { Int32($0) } }
        func events() -> String { (try? String(contentsOf: root.appendingPathComponent("events"),encoding: .utf8)) ?? "" }
        func remove() { try? FileManager.default.removeItem(at: root) }
        static let script = #"""
        import json,sys,os,time,signal
        from pathlib import Path
        root=Path(sys.argv[sys.argv.index('--workspace')+1])
        with (root/'starts').open('a') as f:f.write(str(os.getpid())+'\n')
        def emit(event,**kw):print(json.dumps(dict(event=event,**kw)),flush=True)
        def respond(r):
            name=Path(r['input']).name
            with (root/'events').open('a') as f:f.write(name+'\n')
            if 'ignore-term' in name:signal.signal(signal.SIGTERM,lambda *_: (root/'term').touch())
            while 'hold' in name and not (root/'release').exists():time.sleep(.01)
            if 'exit' in name:sys.exit(3)
            if 'malformed' in name:print('broken json',flush=True);return
            if 'stderr' in name:sys.stderr.write('x'*3000000);sys.stderr.flush()
            rid=r['requestID']
            if 'wrong-id' in name:rid='wrong'
            if 'wrong-order' in name:emit('ready',protocol=1);return
            if 'error' in name:emit('error',requestID=rid,message='injected');return
            directory=root/'outputs'/rid
            emit('completed',requestID=rid,input='/wrong' if 'wrong-input' in name else r['input'],outputDirectory=str(directory),prediction=str(directory/'predicted-foreground.png'),predictionAlpha=str(directory/'predicted-alpha.png'))
        if 'infer' in sys.argv:respond(dict(requestID='single',input=sys.argv[sys.argv.index('--input')+1]))
        else:
            while (root/'hold-ready').exists():time.sleep(.01)
            emit('ready',protocol=1)
            for line in sys.stdin:respond(json.loads(line))
        """#
    }
}

@MainActor extension AIInferenceWorkerTests {
    func testRepeatedStartupShutdownCompletesWithinDeadline() async {
        let finished = expectation(description: "Repeated worker shutdowns finish after child exit")
        Task {
            do {
                for _ in 0..<10 {
                    let f = try Fixture(); defer { f.remove() }
                    try Data().write(to: f.root.appendingPathComponent("hold-ready"))
                    let worker = AIInferenceWorker()
                    let pending = Task { try await worker.infer(f.request("one")) }
                    try await waitUntil { (try? f.starts().count) == 1 }
                    async let a: Void = worker.shutdown()
                    async let b: Void = worker.shutdown()
                    _ = await (a,b)
                    do { _ = try await pending.value; XCTFail("Startup accepted after shutdown") } catch is CancellationError {}
                    for pid in try f.starts() { XCTAssertEqual(kill(pid,0),-1) }
                }
            } catch { XCTFail("\(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished],timeout: 15)
    }
}
