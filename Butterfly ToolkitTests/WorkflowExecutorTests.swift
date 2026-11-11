import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowExecutorTests: XCTestCase {
    func testAutomaticStopsAtGeometryReview() async throws {
        let fixture = try ExecutorFixture()
        let executor = WorkflowExecutor(services: fixture.services)
        try await executor.register(batch: fixture.batch, manifestURL: fixture.manifest)
        try await executor.runPending(batchID: fixture.batch.id)
        let result = try await executor.batch(batchID: fixture.batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.hd].state == .pending })
    }
}

actor ExecutorProbe {
    var calls: [String] = []
    var failing: Set<WorkflowAssetKind> = []
    var gates: [CheckedContinuation<Void, Never>] = []
    var blockRender = false
    func record(_ call: String) { calls.append(call) }
    func values() -> [String] { calls }
    func fail(_ kinds: Set<WorkflowAssetKind>) { failing = kinds }
    func render(_ kind: WorkflowAssetKind, to url: URL) async throws {
        calls.append("render-\(kind.rawValue)")
        if blockRender { await withCheckedContinuation { gates.append($0) } }
        if failing.contains(kind) { throw WorkflowBridgeError.invalidImage("injected") }
        try Data(kind.rawValue.utf8).write(to: url)
    }
    func block() { blockRender = true }
    func release() { blockRender = false; let old = gates; gates = []; for gate in old { gate.resume() } }
}

struct ExecutorFixture {
    let batch: WorkflowBatch
    let manifest: URL
    var services: WorkflowExecutor.Services
    let probe: ExecutorProbe
    nonisolated init(count: Int = 1, storageRoot: URL? = nil) throws {
        let root = storageRoot.map { $0.appendingPathComponent(UUID().uuidString) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("executor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("素材", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let probe = ExecutorProbe(); self.probe = probe
        func sources(_ offset: Int) throws -> WorkflowSources {
            let files = try (offset..<(offset+3)).map { index -> WorkflowSourceFile in
                let url = source.appendingPathComponent("\(index).jpg")
                try Data("source\(index)".utf8).write(to: url)
                return try WorkflowSourceFile(url: url, fingerprint: AIFileValidation.hash(url.path))
            }
            return WorkflowSources(first: files[0], second: files[1], third: files[2])
        }
        batch = try WorkflowBatch(sourceDirectory: source.resolvingSymlinksInPath(), sourceDirectoryName: source.lastPathComponent, outputDirectory: root,
            specimens: (0..<count).map { index in
                try WorkflowSpecimen(baseName: "sample\(index)",
                    front: WorkflowSideTask(side: .front, sources: sources(index*6)),
                    back: WorkflowSideTask(side: .back, sources: sources(index*6+3)))
            })
        manifest = root.appendingPathComponent("batch.json")
        services = WorkflowExecutor.Services(
            stack: { job, owner in
                await probe.record("stack")
                try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let snapshot = Self.snapshot(owner, job.destinationURL, "stack", roles: false)
                try JSONEncoder().encode(snapshot).write(to: job.destinationURL)
                return snapshot
            },
            refresh: { url, owner, sources in
                await probe.record(sources == nil ? "refresh" : "adopt")
                return try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: url))
            },
            extract: { snapshot in await probe.record("extract"); return Self.roles(snapshot) },
            analyze: { roles, _ in await probe.record("analyze"); return Self.solution(roles.snapshotVersion) },
            validateGeometry: { roles, solution in
                guard roles.snapshotVersion == solution.sourceVersion, solution.isApplicable else { throw WorkflowStateError.staleVersion }
                return solution
            },
            apply: { snapshot, _ in
                await probe.record("apply-save")
                let saved = Self.snapshot(snapshot.taskID, snapshot.workingURL, "geometry", roles: true)
                try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
                return saved
            },
            render: { kind, _, _, _, _, url in try await probe.render(kind, to: url) },
            publish: { temp, artifact in
                var result = artifact
                try FileManager.default.createDirectory(at: artifact.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: temp).write(to: artifact.url, options: .atomic)
                result.fileFingerprint = try AIFileValidation.hash(artifact.url.path); result.state = .completed
                try JSONEncoder().encode(result).write(to: artifact.url.appendingPathExtension("test-receipt"))
                return result
            },
            recover: { artifact in
                guard FileManager.default.fileExists(atPath: artifact.url.path) else { return nil }
                let saved = try JSONDecoder().decode(WorkflowArtifact.self,from: Data(contentsOf: artifact.url.appendingPathExtension("test-receipt")))
                guard saved.ownerTaskID == artifact.ownerTaskID, saved.kind == artifact.kind else { throw WorkflowArtifactError.ownershipConflict }
                guard saved.sourceFingerprint == artifact.sourceFingerprint, saved.presetFingerprint == artifact.presetFingerprint else { return nil }
                guard try AIFileValidation.hash(saved.url.path) == saved.fileFingerprint else { throw WorkflowArtifactError.fingerprintMismatch }
                return saved
            },
            contentFingerprint: { _ in "base-content" },
            selectSubject: { snapshot in
                await probe.record("select-subject")
                let saved = Self.snapshot(snapshot.taskID,snapshot.workingURL,"matte",roles: true)
                try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
                return saved
            })
        services.verifyPublishedArtifact = { artifact in
            let receipt = try JSONDecoder().decode(WorkflowArtifact.self, from: Data(contentsOf: artifact.url.appendingPathExtension("test-receipt")))
            guard receipt == artifact, try AIFileValidation.hash(artifact.url.path) == artifact.fileFingerprint else { throw WorkflowArtifactError.ownershipConflict }
        }
        services.openDocuments = { [] }
        services.verifyManualSaveOwnership = { url, owner in
            let saved = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: url))
            guard saved.taskID == owner else { throw WorkflowBridgeError.ownershipConflict }
        }
        services.prepareAcceptedFinalPSD = { accepted in
            await probe.record("prepare-final")
            var saved = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: accepted.snapshotURL))
            saved.snapshotURL = accepted.snapshotURL; saved.contentVersion = accepted.contentVersion
            saved.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "final-a", baseLayer: "final-b", cutoutLayer: "final-c")
            var roles = Self.roles(saved); roles.isFinalized = true
            return (saved, roles)
        }
        services.finalize = { url, owner in
            var saved = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: url))
            guard saved.taskID == owner else { throw WorkflowBridgeError.ownershipConflict }
            saved.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "final-a", baseLayer: "final-b", cutoutLayer: "final-c")
            return saved
        }
    }
    nonisolated static func snapshot(_ id: UUID, _ url: URL, _ version: String, roles: Bool) -> PSDSnapshot {
        PSDSnapshot(taskID: id, workingURL: url, snapshotURL: url.appendingPathExtension("snapshot"), contentVersion: version,
            pixelSize: CGSize(width: 100, height: 80), roles: roles ? PSDRoleIdentifiers(originalStackGroup: "o", adjustmentGroup: "a", baseLayer: "b", cutoutLayer: "c", mask: "m") : nil, structureSummary: "valid")
    }
    nonisolated static func roles(_ snapshot: PSDSnapshot) -> RoleImages {
        RoleImages(snapshotVersion: snapshot.contentVersion, basePNG: snapshot.snapshotURL, cutoutPNG: snapshot.snapshotURL, maskPNG: snapshot.snapshotURL,
            pixelSize: snapshot.pixelSize, coordinateOrigin: .zero, editableExtent: CGRect(origin: .zero, size: snapshot.pixelSize), cropViewport: CGRect(origin: .zero, size: snapshot.pixelSize), isFinalized: snapshot.finalRoles != nil)
    }
    nonisolated static func solution(_ version: String) -> GeometrySolution {
        GeometrySolution(sourceVersion: version, angleDegrees: 0, rotationPivot: CGPoint(x: 50,y: 40), subjectBounds: CGRect(x: 10,y: 10,width: 80,height: 60),
            sourceCropRect: CGRect(x: 0,y: 0,width: 100,height: 80), outputSize: CGSize(width: 100,height: 80),
            actualMargins: WorkflowMargins(left: 0.1, top: 0.125, right: 0.1,bottom: 0.125), isApplicable: true)
    }
}

extension WorkflowExecutorTests {
    private func ready(count: Int = 1) async throws -> (ExecutorFixture, WorkflowExecutor) {
        let f = try ExecutorFixture(count: count), e = WorkflowExecutor(services: f.services)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        return (f,e)
    }
    private func geometry(_ f: ExecutorFixture, _ e: WorkflowExecutor, exportHD: Bool = true, count: Int? = nil) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        let tasks = b.specimens.prefix(count ?? b.specimens.count).flatMap { [$0.front,$0.back] }
        try await e.confirmSavedTasks(batchID: b.id, taskIDs: Set(tasks.map(\.id)))
        if exportHD { try await e.requestExports(batchID: b.id, taskIDs: Set(tasks.map(\.id)), kinds: [.hd], policy: .skipExisting, layouts: [:]) }
    }
    private func square(_ f: ExecutorFixture, _ e: WorkflowExecutor) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        try await e.requestExports(batchID: b.id, taskIDs: Set(b.activeTasks.filter { $0[.geometry].state == .completed }.map(\.id)), kinds: [.png4k], policy: .skipExisting, layouts: [:])
    }

    func testSaveAndReadbackBeforeHD() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        let calls = await f.probe.values()
        let hd = try XCTUnwrap(calls.firstIndex(of: "render-hd")), save = try XCTUnwrap(calls.lastIndex(of: "apply-save"))
        XCTAssertLessThan(save,hd); XCTAssertTrue(calls[(save+1)..<hd].contains("extract"))
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0.acceptedFinalPSD?.contentVersion == $0.snapshot?.contentVersion && $0.roleImages?.isFinalized == true })
    }
    func testPNGRequiresExplicitExportRequest() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("render-png4k"))
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.png4k].state == .pending && $0[.derivatives].state == .pending })
    }


    func test4KLayoutChangeDoesNotTouchHD() async throws {
        let (f,e) = try await ready(); try await geometry(f,e); try await square(f,e)
        let before = try await e.batch(batchID: f.batch.id), calls = await f.probe.values()
        try await e.update(batchID: before.id,event: .presetChanged(scope: .png4k,preset: WorkflowPreset(version: 2,fingerprint: "margin300"),expectedRevision: before.revision))
        try await e.runPending(batchID: before.id)
        let b = try await e.batch(batchID: before.id)
        var layouts = Dictionary(uniqueKeysWithValues: b.activeTasks.map { ($0.id,$0.squareLayout) })
        for id in layouts.keys { layouts[id]?.safeMargin = 300 }
        try await e.requestExports(batchID: b.id, taskIDs: Set(layouts.keys), kinds: [.png4k], policy: .overwrite, layouts: layouts)
        let afterCalls = await f.probe.values(), after = try await e.batch(batchID: b.id)
        XCTAssertEqual(afterCalls.filter { $0 == "render-hd" }.count,calls.filter { $0 == "render-hd" }.count)
        XCTAssertEqual(after.specimens[0].front[.hd],before.specimens[0].front[.hd])
    }
    func testRetryOnlyFailedAsset() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        await f.probe.fail([.png4k]); try await square(f,e)
        var b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.png4k].state == .failed })
        let old = await f.probe.values()
        await f.probe.fail([])
        try await e.retryTasks(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)), stage: .png4k)
        b = try await e.batch(batchID: b.id); XCTAssertTrue(b.allSucceeded)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,old.filter { $0 == "render-hd" }.count)
        XCTAssertEqual(calls.filter { $0 == "render-png4k" }.count,old.filter { $0 == "render-png4k" }.count+2)
    }
    func testStaleRenderCannotPublishAfterSourceChange() async throws {
        let (f,e) = try await ready(); await f.probe.block()
        let job = Task { try await self.geometry(f,e) }
        while !(await f.probe.values()).contains("render-hd") { await Task.yield() }
        let b = try await e.batch(batchID: f.batch.id), side = b.activeTasks.first { $0[.hd].state == .running }!
        try await e.update(batchID: b.id,event: .sourceChanged(taskID: side.id,sources: side.sources,expectedVersion: side.sourceRevision))
        await f.probe.release(); try await job.value
        let after = try await e.batch(batchID: b.id)
        XCTAssertFalse(after.task(id: side.id)!.artifacts.contains { $0.kind == .hd && $0.state == .completed })
        let file = b.exportDirectory(for: .hd)!.appendingPathComponent("sample0_\(side.side.fileSuffix).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testPauseFinishesDispatchedExportsBeforeResume() async throws {
        let (f,e) = try await ready(); await f.probe.block()
        let job = Task { try await self.geometry(f,e) }
        while !(await f.probe.values()).contains("render-hd") { await Task.yield() }
        await e.pause(batchID: f.batch.id); await f.probe.release(); try await job.value
        let paused = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(paused.isPaused)
        XCTAssertTrue(paused.activeTasks.flatMap(\.artifacts).contains { $0.kind == .hd && $0.state == .completed })
        try await e.continueAutomatic(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id); XCTAssertTrue(b.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testOnlyCurrentExportsRunAfterReload() async throws {
        let (f,e) = try await ready()
        let reopened = WorkflowExecutor(services: f.services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await geometry(f,reopened); try await square(f,reopened)
        let b = try await reopened.batch(batchID: f.batch.id)
        XCTAssertTrue(b.allSucceeded)
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("render-white1k"))
    }
}

private nonisolated final class ExecutorInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    func value() -> Int { lock.withLock { count } }
}

extension WorkflowExecutorTests {
    func testFileBeforeManifestRecoveryDoesNotRenderAgain() async throws {
        let f = try ExecutorFixture(), interruption = ExecutorInterruption()
        var services = f.services; let publish = services.publish
        services.publish = { temp, artifact in
            let disk = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: f.manifest))
            guard disk.task(id: artifact.ownerTaskID)?.artifacts.contains(where: { $0.url == artifact.url && $0.state == .pending && $0.sourceFingerprint == artifact.sourceFingerprint }) == true else {
                throw WorkflowStateError.invalidManifest("publication intent missing")
            }
            let result = try publish(temp,artifact)
            if artifact.kind == .hd && interruption.next() == 1 { throw WorkflowBridgeError.photoshop("exit after file") }
            return result
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        try await geometry(f,e)
        let before = await f.probe.values(), b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.contains { $0[.hd].state == .failed })
        let recovered = WorkflowExecutor(services: services)
        _ = try await recovered.register(manifestURL: f.manifest)
        try await recovered.retryTasks(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)), stage: .hd)
        let after = await f.probe.values(), result = try await recovered.batch(batchID: b.id)
        XCTAssertEqual(after.filter { $0 == "render-hd" }.count,before.filter { $0 == "render-hd" }.count)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testInterruptedStackAdoptsOnlyPersistedAttemptAndDoesNotTreatConflictAsSuccess() async throws {
        let f = try ExecutorFixture(), interruption = ExecutorInterruption()
        var services = f.services; let stack = services.stack
        services.stack = { job, owner in
            let result = try await stack(job,owner)
            if interruption.next() == 1 { throw WorkflowBridgeError.photoshop("exit after stack") }
            return result
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.contains { $0[.stack].state == .failed && $0.stackAttemptURL != nil })
        try await e.retryTasks(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)), stage: .stack)
        let calls = await f.probe.values(); XCTAssertEqual(calls.filter { $0 == "stack" }.count,2); XCTAssertTrue(calls.contains("adopt"))
        let result = try await e.batch(batchID: b.id); XCTAssertTrue(result.activeTasks.allSatisfy { $0[.stack].state == .completed })
        var conflicted = b
        conflicted.id = UUID()
        let failedID = b.activeTasks.first { $0[.stack].state == .failed }!.id
        services.refresh = { _,_,_ in throw WorkflowBridgeError.ownershipConflict }
        let blocked = WorkflowExecutor(services: services)
        try await blocked.register(batch: conflicted,manifestURL: f.manifest.appendingPathExtension("conflict"))
        try await blocked.retryTasks(batchID: conflicted.id, taskIDs: Set(conflicted.activeTasks.map(\.id)), stage: .stack)
        let conflict = try await blocked.batch(batchID: conflicted.id)
        XCTAssertEqual(conflict.task(id: failedID)?[.stack].state,.failed)
    }

    func testCancellationAtRenderNeverPublishes() async throws {
        let (f,e) = try await ready(); await f.probe.block()
        let job = Task { try await self.geometry(f,e) }
        while !(await f.probe.values()).contains("render-hd") { await Task.yield() }
        job.cancel(); await f.probe.release()
        do { try await job.value; XCTFail("cancelled work succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.isPaused)
        XCTAssertFalse(b.activeTasks.flatMap(\.artifacts).contains { $0.kind == .hd && $0.state == .completed })
    }
    func testDirtyManualRefreshKeepsLeaseUntilExplicitContinue() async throws {
        let f = try ExecutorFixture(), coordinator = PhotoshopExecutionCoordinator()
        var services = f.services
        let dirty = ExecutorInterruption(), finalize = services.finalize!
        services.finalize = { url,owner in
            if dirty.value() == 0 { throw WorkflowBridgeError.unsavedDocument }
            return try await finalize(url,owner)
        }
        let e = WorkflowExecutor(services: services,coordinator: coordinator)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let before = try await e.batch(batchID: f.batch.id), side = before.activeTasks[0]
        _ = try await e.beginManualEditing(batchID: before.id,taskID: side.id)
        do { try await e.refreshManualPSD(batchID: before.id, taskID: side.id); XCTFail("dirty PSD accepted") } catch WorkflowBridgeError.unsavedDocument {}
        let queued = Task { try await coordinator.run(owner: side.id) { await f.probe.record("automatic-write") } }
        for _ in 0..<100 { await Task.yield() }
        let held = await f.probe.values(); XCTAssertFalse(held.contains("automatic-write"))
        let b = try await e.batch(batchID: before.id); XCTAssertTrue(b.isPaused); XCTAssertEqual(b.task(id: side.id)?.snapshot,side.snapshot)
        do { try await e.continueAutomatic(batchID: b.id); XCTFail("dirty Continue released manual lease") } catch WorkflowBridgeError.unsavedDocument {}
        let stillHeld = await f.probe.values(); XCTAssertFalse(stillHeld.contains("automatic-write"))
        _ = dirty.next()
        try await e.refreshManualPSD(batchID: b.id, taskID: side.id)
        try await e.continueAutomatic(batchID: b.id); try await queued.value
        let resumed = await f.probe.values(); XCTAssertTrue(resumed.contains("automatic-write"))
    }
    func testInvalidationClearsAttemptsAndSavedAuthorizations() async throws {
        var f = try ExecutorFixture().batch
        let id = f.specimens[0].front.id
        f.specimens[0].front.stackAttemptURL = f.generatedPSDDirectory.appendingPathComponent("sample0_D.psd")
        f.specimens[0].front.geometryApplySourceVersion = "old"
        f.specimens[0].front.requestedExports = [.hd: WorkflowExportRequest(snapshotVersion: "old", directory: f.exportDirectory(for: .hd)!, policy: .overwrite)]
        let source = f.specimens[0].front.sources
        let changed = try WorkflowStateMachine.reduce(batch: f,event: .sourceChanged(taskID: id,sources: source,expectedVersion: 1))
        XCTAssertNil(changed.task(id: id)?.stackAttemptURL); XCTAssertNil(changed.task(id: id)?.geometryApplySourceVersion)
        XCTAssertTrue(changed.task(id: id)?.requestedExports?.isEmpty == true)
    }

}

extension WorkflowExecutorTests {


}

extension WorkflowExecutorTests {

}

private actor ExecutorBarrier {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

extension WorkflowExecutorTests {

    func testRegistrationAndLoadRejectUnsafeNamesAndOutputSymlinkEscape() async throws {
        let f = try ExecutorFixture()
        for name in ["../../escape","../escape","a/b","a\\b",".","..","\u{0}bad"] {
            var invalid = f.batch; invalid.specimens[0].baseName = name
            let e = WorkflowExecutor(services: f.services)
            do { try await e.register(batch: invalid,manifestURL: f.manifest); XCTFail("registered \(name)") } catch {}
            try JSONEncoder().encode(invalid).write(to: f.manifest)
            do { _ = try await WorkflowExecutor(services: f.services).register(manifestURL: f.manifest); XCTFail("loaded \(name)") } catch {}
        }
        var valid = f.batch; valid.specimens[0].baseName = "红云扶蛱蝶 Fountainea titan (♂) 01"
        try valid.validate()
        let outside = f.batch.outputDirectory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.batch.exportDirectory(for: .png4k)!,withDestinationURL: outside)
        do { try await WorkflowExecutor(services: f.services).register(batch: valid,manifestURL: f.manifest); XCTFail("symlink escape registered") } catch {}
        try JSONEncoder().encode(valid).write(to: f.manifest)
        do { _ = try await WorkflowExecutor(services: f.services).register(manifestURL: f.manifest); XCTFail("symlink escape loaded") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}

extension WorkflowExecutorTests {
    func testCanonicalOutputAliasIsAllowedAndLateSymlinkWritesNothingOutside() async throws {
        let f = try ExecutorFixture()
        let directory = "executor-alias-\(UUID())"
        let canonical = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(directory)
        let alias = URL(fileURLWithPath: "/tmp").appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: canonical,withIntermediateDirectories: true)
        var batch = f.batch; batch.outputDirectory = alias
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch,manifestURL: alias.appendingPathComponent("batch.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.appendingPathComponent("batch.json").path))
        let outside = canonical.deletingLastPathComponent().appendingPathComponent("outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: batch.generatedPSDDirectory,withDestinationURL: outside)
        try await e.runPending(batchID: batch.id)
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.stack].state == .failed })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        do { try batch.validateOutputURL(alias.appendingPathComponent("../escape.psd")); XCTFail("normalized parent escaped output") } catch {}
    }

}

extension WorkflowExecutorTests {
    func testPersistedAttemptRejectsParentNavigationThroughNestedSymlink() async throws {
        let f = try ExecutorFixture()
        let outside = f.batch.outputDirectory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("child"),withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.batch.outputDirectory.appendingPathComponent("nested-link"),withDestinationURL: outside.appendingPathComponent("child"))
        var batch = f.batch
        batch.specimens[0].front.stackAttemptURL = batch.outputDirectory.appendingPathComponent("nested-link/../escape.psd")
        do { try await WorkflowExecutor(services: f.services).register(batch: batch,manifestURL: f.manifest); XCTFail("persisted parent navigation accepted") } catch {}
        try JSONEncoder().encode(batch).write(to: f.manifest)
        do { _ = try await WorkflowExecutor(services: f.services).register(manifestURL: f.manifest); XCTFail("forged attempt loaded") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.psd").path))
    }
}

actor WorkflowRenderGate {
    let entered: XCTestExpectation
    var starts: [URL] = []
    var active = 0, peak = 0
    var open = false
    var waiting: [CheckedContinuation<Void,Never>] = []
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold(_ url: URL) async {
        starts.append(url); active += 1; peak = max(peak,active)
        if starts.count <= 2 { entered.fulfill() }
        if !open { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
    }
    func release() { open = true; let old = waiting; waiting = []; for item in old { item.resume() } }
    func counts() -> (Int,Int) { (starts.count,peak) }
}

extension WorkflowExecutorTests {
    func testExportsOverlapWithMaximumTwoActiveRenders() async throws {
        for kind in [WorkflowAssetKind.hd,.png4k] {
            let f = try ExecutorFixture(count: 2)
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            let entered = expectation(description: "Two independent renders entered"); entered.expectedFulfillmentCount = 2
            let gate = WorkflowRenderGate(entered),render = f.services.render
            var services = f.services
            services.render = { k,r,l,s,w,u in if k == kind { await gate.hold(u) }; try await render(k,r,l,s,w,u) }
            let e = WorkflowExecutor(services: services)
            try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
            if kind == .png4k { try await geometry(f,e) }
            let job = Task { if kind == .hd { try await geometry(f,e) } else { try await square(f,e) } }
            await fulfillment(of: [entered],timeout: 2)
            let during = try await e.batch(batchID: f.batch.id)
            XCTAssertEqual(during.activeTasks.filter { $0[kind.stage].state == .running }.count,2)
            XCTAssertFalse(during.allSucceeded)
            await gate.release(); try await job.value
            let counts = await gate.counts(),after = try await e.batch(batchID: f.batch.id)
            XCTAssertEqual(counts.0,4); XCTAssertEqual(counts.1,2)
            XCTAssertTrue(after.activeTasks.allSatisfy { $0[kind.stage].state == .completed })
            let disk = try await WorkflowBatchStore().load(from: f.manifest)
            XCTAssertEqual(disk,after)
        }
    }
    func testParallelExportPauseDrainsOnlyDispatchedFaces() async throws {
        let f = try ExecutorFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let entered = expectation(description: "Two renders before pause"); entered.expectedFulfillmentCount = 2
        let gate = WorkflowRenderGate(entered),render = f.services.render
        var services = f.services
        services.render = { k,r,l,s,w,u in await gate.hold(u); try await render(k,r,l,s,w,u) }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let job = Task { try await geometry(f,e) }
        await fulfillment(of: [entered],timeout: 2)
        await e.pause(batchID: f.batch.id); await gate.release(); try await job.value
        let count = await gate.counts(),paused = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(count.0,2,"Pause must stop dispatching the other two faces")
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.sideTasks.flatMap(\.artifacts).filter { $0.state == .completed }.count, 2)
        XCTAssertEqual(paused.sideTasks.flatMap(\.artifacts).filter { FileManager.default.fileExists(atPath: $0.url.path) }.count, 2)
        try await e.continueAutomatic(batchID: paused.id)
        let resumed = try await e.batch(batchID: paused.id)
        XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testParallelExportFailureKeepsSuccessfulSide() async throws {
        let f = try ExecutorFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let failed = f.batch.activeTasks[0].id,render = f.services.render
        var services = f.services
        services.render = { k,r,l,s,w,u in
            if u.path.contains(failed.uuidString) { throw WorkflowBridgeError.invalidImage("injected side") }
            try await render(k,r,l,s,w,u)
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        try await geometry(f,e)
        let before = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(before.task(id: failed)?[.hd].state,.failed)
        XCTAssertEqual(before.activeTasks.filter { $0[.hd].state == .completed }.count,3)
        let artifacts = before.sideTasks.filter { $0.id != failed }.flatMap(\.artifacts)
        let reopened = WorkflowExecutor(services: f.services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.retryTasks(batchID: before.id, taskIDs: Set(before.activeTasks.map(\.id)), stage: .hd)
        let after = try await reopened.batch(batchID: before.id),calls = await f.probe.values()
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.hd].state == .completed })
        XCTAssertEqual(after.sideTasks.filter { $0.id != failed }.flatMap(\.artifacts),artifacts)
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,4,"Retry renders only the failed face")
    }
}

extension WorkflowExecutorTests {
    func testManualLeaseWaitsForNativeMatteCheckpointAfterPause() async throws {
        let f = try ExecutorFixture(count: 2), ps = PhotoshopExecutionCoordinator()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let id = batch.activeTasks[0].id, gate = ExecutorBarrier(), probe = f.probe
        var services = f.services
        let select = try XCTUnwrap(services.selectSubject)
        services.selectSubject = { snapshot in try await ps.run(owner: snapshot.taskID) {
            if snapshot.taskID == id { await gate.wait() }
            let saved = try await select(snapshot)
            await probe.record("PS-finished")
            return saved
        } }
        let executor = WorkflowExecutor(services: services,coordinator: ps)
        try await executor.register(batch: batch,manifestURL: f.manifest)
        let batchID = batch.id
        let run = Task { try await executor.runPending(batchID: batchID) }
        for _ in 0..<200 where !(await gate.entered) { try await Task.sleep(for: .milliseconds(10)) }
        let entered = await gate.entered
        guard entered else {
            await gate.release()
            _ = try? await run.value
            return XCTFail("Native Photoshop selection did not start")
        }
        await executor.pause(batchID: batchID)
        let manual = Task {
            _ = try await executor.beginManualEditing(batchID: batchID,taskID: id)
            await probe.record("manual-opened")
        }
        let before = await probe.values()
        XCTAssertFalse(before.contains("PS-finished"))
        XCTAssertFalse(before.contains("manual-opened"))
        await gate.release()
        try await run.value
        try await manual.value
        await ps.endManualEditing(owner: id)

        let calls = await probe.values(), saved = try await WorkflowBatchStore().load(from: f.manifest)
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "PS-finished")),try XCTUnwrap(calls.firstIndex(of: "manual-opened")))
        XCTAssertEqual(calls.filter { $0 == "stack" }.count,1)
        XCTAssertTrue(saved.isPaused)
        XCTAssertEqual(saved.task(id: id)?[.matte].state,.completed)
        XCTAssertEqual(saved.task(id: id)?[.geometry].state,.pending)
    }
}

extension WorkflowExecutorTests {
    func testResumeCannotChangeStateUntilPausedRunDrains() async throws {
        let f = try ExecutorFixture(),entered = expectation(description: "Two renders before resume")
        entered.expectedFulfillmentCount = 2
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let gate = WorkflowRenderGate(entered),render = f.services.render
        var services = f.services
        services.render = { k,r,l,s,w,u in await gate.hold(u); try await render(k,r,l,s,w,u) }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let run = Task { try await geometry(f,e) }
        await fulfillment(of: [entered],timeout: 2); await e.pause(batchID: f.batch.id)
        do { try await e.continueAutomatic(batchID: f.batch.id); XCTFail("Resume before drain must be rejected") }
        catch WorkflowStateError.invalidTransition { }
        let pausing = try await e.batch(batchID: f.batch.id); XCTAssertFalse(pausing.isPaused, "Pause becomes durable only after the current saved work drains")
        await e.pause(batchID: f.batch.id); await gate.release(); try await run.value
        try await e.continueAutomatic(batchID: f.batch.id)
        let resumed = try await e.batch(batchID: f.batch.id)
        XCTAssertFalse(resumed.isPaused); XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
}

private actor PublicationValidationGate {
    let entered: XCTestExpectation
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func arm() { armed = true }
    func observe() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension WorkflowExecutorTests {
    func testExportRootReplacedDuringFinalRoleReadCannotPublishOutsideSource() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let entered = expectation(description: "Final role read before publication")
        let gate = PublicationValidationGate(entered)
        var services = f.services
        let extract = services.extract, render = services.render
        services.extract = { saved in
            await gate.observe()
            return try await extract(saved)
        }
        services.render = { kind, roles, layout, source, watermark, destination in
            try await render(kind, roles, layout, source, watermark, destination)
            await gate.arm()
        }
        let executor = WorkflowExecutor(services: services, coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: f.batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: f.batch.id)
        let id = f.batch.specimens[0].front.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        let export = Task {
            try await executor.requestExports(batchID: f.batch.id, taskIDs: [id], kinds: [.hd], policy: .overwrite, layouts: [:])
        }
        await fulfillment(of: [entered], timeout: 3)
        let outside = f.batch.outputDirectory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.batch.exportDirectory(for: .hd)!, withDestinationURL: outside)
        await gate.release()
        _ = try? await export.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "Neither output nor owner receipt may be written through the replaced root")
    }
}
