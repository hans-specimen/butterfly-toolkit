import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowExecutorTests: XCTestCase {
    func testMatteSessionEndsBeforeReviewOrGeometryAndOnPause() async throws {
        for checkMatte in [true,false] {
            let f = try ExecutorFixture(checks: false,checkMatte: checkMatte)
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            var services = f.services
            services.endInferenceSession = { await f.probe.record("end-session") }
            let executor = WorkflowExecutor(services: services)
            try await executor.register(batch: f.batch,manifestURL: f.manifest)
            try await executor.runPending(batchID: f.batch.id)
            let calls = await f.probe.values()
            let ai = calls.indices.filter { calls[$0] == "ai" }
            XCTAssertEqual(ai.count,2)
            let ended = try XCTUnwrap(calls.firstIndex(of: "end-session"))
            XCTAssertGreaterThan(ended,try XCTUnwrap(ai.last),"Both consecutive faces must share a session")
            if let analysis = calls.firstIndex(of: "analyze") { XCTAssertLessThan(ended,analysis) }
            let count = calls.filter { $0 == "end-session" }.count
            await executor.pause(batchID: f.batch.id)
            let after = await f.probe.values()
            XCTAssertGreaterThan(after.filter { $0 == "end-session" }.count,count)
        }
    }
    func testAutomaticUntilGeometryWhenOff() async throws {
        let fixture = try ExecutorFixture(checks: false)
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
    let services: WorkflowExecutor.Services
    let probe: ExecutorProbe
    nonisolated init(checks: Bool, count: Int = 1, checkMatte: Bool? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("executor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = ExecutorProbe(); self.probe = probe
        func sources(_ offset: Int) throws -> WorkflowSources {
            let files = try (offset..<(offset+3)).map { index -> WorkflowSourceFile in
                let url = root.appendingPathComponent("\(index).jpg")
                try Data("source\(index)".utf8).write(to: url)
                return try WorkflowSourceFile(url: url, fingerprint: AIFileValidation.hash(url.path))
            }
            return WorkflowSources(first: files[0], second: files[1], third: files[2])
        }
        batch = try WorkflowBatch(sourceDirectory: root, outputDirectory: root,
            checkAfterStack: checks, checkAfterMatte: checkMatte ?? checks,
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
            exportStack: { snapshot in
                await probe.record("export-stack")
                return StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: root.appendingPathComponent("stack.png"), fingerprint: "png", pixelSize: snapshot.pixelSize, orientation: 1, colorProfile: "sRGB")
            },
            infer: { input in
                await probe.record("ai")
                return MatteArtifact(inputPNGFingerprint: input.fingerprint, alphaURL: root.appendingPathComponent("alpha.png"), alphaFingerprint: "alpha", cutoutURL: root.appendingPathComponent("cutout.png"), cutoutFingerprint: "cutout", orientation: 1, pixelSize: input.pixelSize)
            },
            install: { snapshot, _ in
                await probe.record("install")
                let saved = Self.snapshot(snapshot.taskID, snapshot.workingURL, "matte", roles: true)
                try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
                return saved
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
            validateInstalledMatte: { _,_,_ in await probe.record("validate-installed") })
    }
    nonisolated static func snapshot(_ id: UUID, _ url: URL, _ version: String, roles: Bool) -> PSDSnapshot {
        PSDSnapshot(taskID: id, workingURL: url, snapshotURL: url.appendingPathExtension("snapshot"), contentVersion: version,
            pixelSize: CGSize(width: 100, height: 80), roles: roles ? PSDRoleIdentifiers(originalStackGroup: "o", adjustmentGroup: "a", baseLayer: "b", cutoutLayer: "c", mask: "m") : nil, structureSummary: "valid")
    }
    nonisolated static func roles(_ snapshot: PSDSnapshot) -> RoleImages {
        RoleImages(snapshotVersion: snapshot.contentVersion, basePNG: snapshot.snapshotURL, cutoutPNG: snapshot.snapshotURL, maskPNG: snapshot.snapshotURL,
            pixelSize: snapshot.pixelSize, coordinateOrigin: .zero, editableExtent: CGRect(origin: .zero, size: snapshot.pixelSize), cropViewport: CGRect(origin: .zero, size: snapshot.pixelSize))
    }
    nonisolated static func solution(_ version: String) -> GeometrySolution {
        GeometrySolution(sourceVersion: version, angleDegrees: 0, rotationPivot: CGPoint(x: 50,y: 40), subjectBounds: CGRect(x: 10,y: 10,width: 80,height: 60),
            sourceCropRect: CGRect(x: 0,y: 0,width: 100,height: 80), outputSize: CGSize(width: 100,height: 80),
            actualMargins: WorkflowMargins(left: 0.1, top: 0.125, right: 0.1,bottom: 0.125), isApplicable: true)
    }
}

extension WorkflowExecutorTests {
    private func ready(checks: Bool = false, count: Int = 1) async throws -> (ExecutorFixture, WorkflowExecutor) {
        let f = try ExecutorFixture(checks: checks,count: count), e = WorkflowExecutor(services: f.services)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        return (f,e)
    }
    private func geometry(_ f: ExecutorFixture, _ e: WorkflowExecutor, exportHD: Bool = true, count: Int? = nil) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        let tasks = b.specimens.prefix(count ?? b.specimens.count).flatMap { [$0.front,$0.back] }
        try await e.confirmGeometry(batchID: b.id,solutions: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id,$0.geometrySolution!) }),exportHD: exportHD)
    }
    private func square(_ f: ExecutorFixture, _ e: WorkflowExecutor) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        try await e.confirm4K(batchID: b.id,layouts: Dictionary(uniqueKeysWithValues: b.activeTasks.filter { $0[.png4k].state == .waitingReview }.map { ($0.id,$0.squareLayout) }))
    }
    func testHappyPathBothCheckpointsOn() async throws {
        let (f,e) = try await ready(checks: true)
        var b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.stack].state == .waitingReview })
        var calls = await f.probe.values(); XCTAssertEqual(calls.filter { $0 == "stack" }.count,2); XCTAssertFalse(calls.contains("ai"))
        try await e.continueAfterReview(batchID: b.id,stage: .stack,specimenIDs: b.specimens.map(\.id))
        b = try await e.batch(batchID: b.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
        calls = await f.probe.values(); XCTAssertFalse(calls.contains("analyze"))
        try await e.continueAfterReview(batchID: b.id,stage: .matte,specimenIDs: b.specimens.map(\.id))
        try await geometry(f,e); try await square(f,e)
        b = try await e.batch(batchID: b.id); XCTAssertTrue(b.allSucceeded)
        let disk = try await WorkflowBatchStore().load(from: f.manifest); XCTAssertEqual(disk,b)
    }
    func testSaveAndReadbackBeforeHD() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        let calls = await f.probe.values()
        let hd = try XCTUnwrap(calls.firstIndex(of: "render-hd")), save = try XCTUnwrap(calls.lastIndex(of: "apply-save"))
        XCTAssertLessThan(save,hd); XCTAssertTrue(calls[(save+1)..<hd].contains("extract"))
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0.geometrySolution?.angleDegrees == 0 && $0.geometrySolution?.sourceVersion == $0.snapshot?.contentVersion })
    }
    func test4KRequiresSeparateConfirmation() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("render-png4k"))
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.png4k].state == .waitingReview && $0[.derivatives].state == .pending })
    }
    func testSelectedSpecimenDoesNotApproveOthersOrOneSide() async throws {
        let (f,e) = try await ready(count: 2)
        let before = try await e.batch(batchID: f.batch.id), front = before.specimens[0].front
        do { try await e.confirmGeometry(batchID: before.id,solutions: [front.id: front.geometrySolution!],exportHD: false); XCTFail("one side accepted") }
        catch {}
        try await geometry(f,e,exportHD: false,count: 1)
        let b = try await e.batch(batchID: before.id)
        XCTAssertEqual(b.specimens[1].front[.geometry].state,.waitingReview)
        XCTAssertEqual(b.specimens[0].front[.hd].outputVersion,"not-selected")
        XCTAssertFalse(b.specimens[0].front.artifacts.contains { $0.kind == .hd })
    }
    func testMaskEditDoesNotRunAI() async throws {
        let (f,e) = try await ready(); try await geometry(f,e)
        let b = try await e.batch(batchID: f.batch.id), side = b.specimens[0].front
        var snapshot = side.snapshot!; snapshot.contentVersion = "mask-edited"
        try JSONEncoder().encode(snapshot).write(to: snapshot.workingURL)
        let callsBefore = await f.probe.values()
        try await e.update(batchID: b.id,event: .savedPSDChanged(taskID: side.id,snapshot: snapshot,change: .maskOnly,expectedSourceVersion: side.sourceRevision,expectedSnapshotVersion: side.snapshot?.contentVersion))
        try await e.runPending(batchID: b.id)
        let callsAfter = await f.probe.values()
        XCTAssertEqual(callsAfter.filter { $0 == "ai" }.count,callsBefore.filter { $0 == "ai" }.count)
        XCTAssertEqual(callsAfter.filter { $0 == "analyze" }.count,callsBefore.filter { $0 == "analyze" }.count)
        let after = try await e.batch(batchID: b.id)
        XCTAssertEqual(after.task(id: side.id)?.geometrySolution?.angleDegrees,0)
        XCTAssertEqual(after.task(id: side.id)?.geometrySolution?.sourceVersion,"mask-edited")
    }
    func test4KLayoutChangeDoesNotTouchHD() async throws {
        let (f,e) = try await ready(); try await geometry(f,e); try await square(f,e)
        let before = try await e.batch(batchID: f.batch.id), calls = await f.probe.values()
        try await e.update(batchID: before.id,event: .presetChanged(scope: .png4k,preset: WorkflowPreset(version: 2,fingerprint: "margin300"),expectedRevision: before.revision))
        try await e.runPending(batchID: before.id)
        let b = try await e.batch(batchID: before.id)
        var layouts = Dictionary(uniqueKeysWithValues: b.activeTasks.map { ($0.id,$0.squareLayout) })
        for id in layouts.keys { layouts[id]?.safeMargin = 300 }
        try await e.confirm4K(batchID: b.id,layouts: layouts)
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
        try await e.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .png4k)
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
        let file = b.outputDirectory.appendingPathComponent("高清堆栈/sample0_\(side.side.fileSuffix).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testPausePreventsPublicationAndExplicitContinueResumes() async throws {
        let (f,e) = try await ready(); await f.probe.block()
        let job = Task { try await self.geometry(f,e) }
        while !(await f.probe.values()).contains("render-hd") { await Task.yield() }
        await e.pause(batchID: f.batch.id); await f.probe.release(); try await job.value
        let paused = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.activeTasks.flatMap(\.artifacts).contains { $0.kind == .hd && $0.state == .completed })
        try await e.continueAutomatic(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id); XCTAssertTrue(b.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testNoDerivativesSelectionSurvivesReload() async throws {
        let (f,e) = try await ready()
        let reopened = WorkflowExecutor(services: f.services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await geometry(f,reopened); try await square(f,reopened)
        let b = try await reopened.batch(batchID: f.batch.id)
        XCTAssertEqual(b.selectedDerivativeKinds,[]); XCTAssertTrue(b.allSucceeded)
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
    func testMatteInstallRetryUsesDurableOldSnapshotAndSameAIArtifact() async throws {
        let f = try ExecutorFixture(checks: false), interruption = ExecutorInterruption()
        var services = f.services
        let install = services.install
        services.install = { snapshot, matte in
            let manifest = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: f.manifest))
            guard manifest.task(id: snapshot.taskID)?.snapshot == snapshot,
                  manifest.task(id: snapshot.taskID)?.matteArtifact == matte else { throw WorkflowStateError.invalidManifest("install intent missing") }
            _ = try await install(snapshot,matte)
            if interruption.next() == 1 { throw WorkflowBridgeError.photoshop("interrupted install") }
            return ExecutorFixture.snapshot(snapshot.taskID,snapshot.workingURL,"matte",roles: true)
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let before = await f.probe.values()
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.contains { $0[.matte].state == .failed && $0.snapshot?.roles == nil && $0.matteArtifact != nil })
        try await e.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .matte)
        let after = await f.probe.values()
        XCTAssertEqual(after.filter { $0 == "ai" }.count,before.filter { $0 == "ai" }.count)
        let result = try await e.batch(batchID: b.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
    }
    func testFileBeforeManifestRecoveryDoesNotRenderAgain() async throws {
        let f = try ExecutorFixture(checks: false), interruption = ExecutorInterruption()
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
        try await recovered.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .hd)
        let after = await f.probe.values(), result = try await recovered.batch(batchID: b.id)
        XCTAssertEqual(after.filter { $0 == "render-hd" }.count,before.filter { $0 == "render-hd" }.count)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testInterruptedStackAdoptsOnlyPersistedAttemptAndDoesNotTreatConflictAsSuccess() async throws {
        let f = try ExecutorFixture(checks: false), interruption = ExecutorInterruption()
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
        try await e.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .stack)
        let calls = await f.probe.values(); XCTAssertEqual(calls.filter { $0 == "stack" }.count,2); XCTAssertTrue(calls.contains("adopt"))
        let result = try await e.batch(batchID: b.id); XCTAssertTrue(result.activeTasks.allSatisfy { $0[.stack].state == .completed })
        var conflicted = b
        conflicted.id = UUID()
        let failedID = b.activeTasks.first { $0[.stack].state == .failed }!.id
        services.refresh = { _,_,_ in throw WorkflowBridgeError.ownershipConflict }
        let blocked = WorkflowExecutor(services: services)
        try await blocked.register(batch: conflicted,manifestURL: f.manifest.appendingPathExtension("conflict"))
        try await blocked.retry(batchID: conflicted.id,specimenIDs: conflicted.specimens.map(\.id),stage: .stack)
        let conflict = try await blocked.batch(batchID: conflicted.id)
        XCTAssertEqual(conflict.task(id: failedID)?[.stack].state,.failed)
    }
    func testGeometryInterruptedSecondSideRequiresCurrentPoseRefreshWithoutDoubleAngle() async throws {
        let f = try ExecutorFixture(checks: false), interruption = ExecutorInterruption()
        var services = f.services; let apply = services.apply
        services.apply = { snapshot, solution in
            await f.probe.record("angle-\(solution.angleDegrees)-\(snapshot.contentVersion)")
            if interruption.next() == 2 { throw WorkflowBridgeError.photoshop("interrupted apply") }
            return try await apply(snapshot,solution)
        }
        services.refresh = { url,owner,_ in
            let current = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: url))
            if current.contentVersion == "matte" && interruption.value() >= 2 {
                let saved = ExecutorFixture.snapshot(owner,url,"current-manual-pose",roles: true)
                try JSONEncoder().encode(saved).write(to: url)
                return saved
            }
            return current
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let initial = try await e.batch(batchID: f.batch.id)
        var solutions = Dictionary(uniqueKeysWithValues: initial.activeTasks.map { ($0.id,$0.geometrySolution!) })
        for id in solutions.keys { solutions[id]?.angleDegrees = 5 }
        do { try await e.confirmGeometry(batchID: initial.id,solutions: solutions,exportHD: true); XCTFail("interruption accepted") } catch {}
        var b = try await e.batch(batchID: initial.id)
        XCTAssertTrue(b.isPaused)
        let uncertain = try XCTUnwrap(b.activeTasks.first { $0.geometryApplySourceVersion != nil })
        do { try await e.confirmGeometry(batchID: b.id,solutions: solutions,exportHD: true); XCTFail("blind replay") } catch {}
        try await e.refreshSavedPSD(batchID: b.id,taskID: uncertain.id,change: .geometry)
        try await e.continueAutomatic(batchID: b.id)
        b = try await e.batch(batchID: b.id)
        XCTAssertEqual(b.task(id: uncertain.id)?.geometrySolution?.angleDegrees,0)
        try await geometry(f,e)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "angle-5.0-matte" }.count,2)
        XCTAssertTrue(calls.contains("angle-0.0-current-manual-pose"))
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
        let f = try ExecutorFixture(checks: false), coordinator = PhotoshopExecutionCoordinator()
        var services = f.services
        let dirty = ExecutorInterruption(), refresh = services.refresh
        services.refresh = { url,owner,sources in
            if dirty.value() == 0 { throw WorkflowBridgeError.unsavedDocument }
            return try await refresh(url,owner,sources)
        }
        let e = WorkflowExecutor(services: services,coordinator: coordinator)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let before = try await e.batch(batchID: f.batch.id), side = before.activeTasks[0]
        _ = try await e.beginManualEditing(batchID: before.id,taskID: side.id)
        do { try await e.refreshSavedPSD(batchID: before.id,taskID: side.id,change: .maskOnly); XCTFail("dirty PSD accepted") } catch WorkflowBridgeError.unsavedDocument {}
        let queued = Task { try await coordinator.run(owner: side.id) { await f.probe.record("automatic-write") } }
        for _ in 0..<100 { await Task.yield() }
        let held = await f.probe.values(); XCTAssertFalse(held.contains("automatic-write"))
        let b = try await e.batch(batchID: before.id); XCTAssertTrue(b.isPaused); XCTAssertEqual(b.task(id: side.id)?.snapshot,side.snapshot)
        do { try await e.continueAutomatic(batchID: b.id); XCTFail("dirty Continue released manual lease") } catch WorkflowBridgeError.unsavedDocument {}
        let stillHeld = await f.probe.values(); XCTAssertFalse(stillHeld.contains("automatic-write"))
        _ = dirty.next()
        try await e.refreshSavedPSD(batchID: b.id,taskID: side.id,change: .maskOnly)
        try await e.continueAutomatic(batchID: b.id); try await queued.value
        let resumed = await f.probe.values(); XCTAssertTrue(resumed.contains("automatic-write"))
    }
    func testInvalidationClearsAttemptsAndSavedAuthorizations() async throws {
        var f = try ExecutorFixture(checks: false).batch
        let id = f.specimens[0].front.id
        f.specimens[0].front.stackAttemptURL = f.outputDirectory.appendingPathComponent("old.psd")
        f.specimens[0].front.geometryApplySourceVersion = "old"
        f.specimens[0].front.fourKExportRequested = true
        f.specimens[0].front.exportHD = true
        let source = f.specimens[0].front.sources
        let changed = try WorkflowStateMachine.reduce(batch: f,event: .sourceChanged(taskID: id,sources: source,expectedVersion: 1))
        XCTAssertNil(changed.task(id: id)?.stackAttemptURL); XCTAssertNil(changed.task(id: id)?.geometryApplySourceVersion)
        XCTAssertNil(changed.task(id: id)?.fourKExportRequested); XCTAssertNil(changed.task(id: id)?.exportHD)
    }
    func testOneSideMaskReconfirmKeepsOtherSideAndReusesHDByContent() async throws {
        let (f,e) = try await ready(count: 2); try await geometry(f,e)
        var b = try await e.batch(batchID: f.batch.id)
        let changed = b.specimens[0].front, opposite = b.specimens[0].back
        var saved = changed.snapshot!; saved.contentVersion = "mask-current"
        try JSONEncoder().encode(saved).write(to: saved.workingURL)
        let oldCalls = await f.probe.values()
        try await e.update(batchID: b.id,event: .savedPSDChanged(taskID: changed.id,snapshot: saved,change: .maskOnly,expectedSourceVersion: changed.sourceRevision,expectedSnapshotVersion: changed.snapshot?.contentVersion))
        try await e.runPending(batchID: b.id)
        b = try await e.batch(batchID: b.id)
        let both = [b.specimens[0].front,b.specimens[0].back]
        try await e.confirmGeometry(batchID: b.id,solutions: Dictionary(uniqueKeysWithValues: both.map { ($0.id,$0.geometrySolution!) }),exportHD: true)
        let after = try await e.batch(batchID: b.id), calls = await f.probe.values()
        XCTAssertEqual(after.task(id: opposite.id)?.snapshot,opposite.snapshot)
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,oldCalls.filter { $0 == "render-hd" }.count)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,oldCalls.filter { $0 == "apply-save" }.count+1)
    }
}

extension WorkflowExecutorTests {
    func testConfirmationUsesSingleVerifiedExtraction() async throws {
        for phase in ["initialGeometry", "geometryAgain", "png4k"] {
            let (f,initial) = try await ready(count: 2)
            if phase != "initialGeometry" { try await geometry(f,initial,exportHD: false,count: 1) }
            let before = try await initial.batch(batchID: f.batch.id)
            let selected = [before.specimens[0].front,before.specimens[0].back]
            let reads = ExecutorProbe()
            var services = f.services
            let refresh = services.refresh
            services.refresh = { url,owner,sources in
                await reads.record("refresh")
                return try await refresh(url,owner,sources)
            }
            services.extract = { snapshot in
                await reads.record("\(snapshot.taskID)/\(snapshot.contentVersion)")
                var roles = ExecutorFixture.roles(snapshot)
                roles.basePNG = snapshot.workingURL.appendingPathExtension("verified.png")
                return roles
            }
            let e = WorkflowExecutor(services: services)
            _ = try await e.register(manifestURL: f.manifest)
            if phase != "png4k" {
                try await e.confirmGeometry(batchID: before.id,solutions: Dictionary(uniqueKeysWithValues: selected.map { ($0.id,$0.geometrySolution!) }),exportHD: false)
            } else {
                try await e.confirm4K(batchID: before.id,layouts: Dictionary(uniqueKeysWithValues: selected.map { ($0.id,$0.squareLayout) }))
            }
            let calls = await reads.values(), after = try await e.batch(batchID: before.id)
            XCTAssertEqual(calls.filter { $0 == "refresh" }.count,0)
            for task in selected {
                XCTAssertEqual(calls.filter { $0 == "\(task.id)/\(task.snapshot!.contentVersion)" }.count,1)
                // First confirmation must still read the new saved version after applying geometry.
                XCTAssertEqual(calls.filter { $0.hasPrefix("\(task.id)/") }.count,phase == "initialGeometry" ? 2 : 1)
                XCTAssertEqual(after.task(id: task.id)?.roleImages?.basePNG,task.snapshot!.workingURL.appendingPathExtension("verified.png"))
            }
            XCTAssertEqual(after.specimens[1],before.specimens[1],"Confirmation must not approve or replace roles for an unselected specimen")
        }
    }
    func testSavedPSDChangedOutsideExecutorRejectsGeometryConfirmation() async throws {
        let (f,initial) = try await ready()
        let before = try await initial.batch(batchID: f.batch.id)
        var changed = before.activeTasks[0].snapshot!
        changed.contentVersion = "unrefreshed-manual-edit"
        try JSONEncoder().encode(changed).write(to: changed.workingURL)
        var services = f.services
        services.extract = { snapshot in
            let saved = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: snapshot.workingURL))
            guard saved == snapshot else { throw WorkflowBridgeError.staleSource }
            return ExecutorFixture.roles(snapshot)
        }
        let e = WorkflowExecutor(services: services)
        _ = try await e.register(manifestURL: f.manifest)
        do { try await geometry(f,e); XCTFail("stale saved PSD accepted") }
        catch WorkflowBridgeError.staleSource {} catch WorkflowStateError.staleVersion {}
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("apply-save"))
    }
}

extension WorkflowExecutorTests {
    func testPublishedMatteBeforeManifestAdoptsVerifiedRolesWithoutSecondInstall() async throws {
        let f = try ExecutorFixture(checks: false), interruption = ExecutorInterruption()
        var services = f.services; let install = services.install
        services.install = { snapshot,matte in
            guard try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: snapshot.workingURL)).contentVersion == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
            let saved = try await install(snapshot,matte)
            if interruption.next() == 1 { throw WorkflowBridgeError.photoshop("exit after committed install") }
            return saved
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id), oldCalls = await f.probe.values()
        let reopened = WorkflowExecutor(services: services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .matte)
        let after = try await reopened.batch(batchID: b.id), calls = await f.probe.values()
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .completed })
        XCTAssertEqual(calls.filter { $0 == "install" }.count,oldCalls.filter { $0 == "install" }.count)
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,oldCalls.filter { $0 == "ai" }.count)
    }
    func testLegacyManifestDecodesOptionalExecutionChoices() throws {
        let f = try ExecutorFixture(checks: false)
        let data = try JSONEncoder().encode(f.batch)
        let decoded = try JSONDecoder().decode(WorkflowBatch.self,from: data)
        XCTAssertNil(decoded.selectedDerivativeKinds); XCTAssertNil(decoded.watermarkURL)
        XCTAssertNil(decoded.activeTasks[0].stackAttemptURL); XCTAssertNil(decoded.activeTasks[0].exportHD)
        XCTAssertNil(decoded.activeTasks[0].geometryApplySourceVersion); XCTAssertNil(decoded.activeTasks[0].fourKExportRequested)
        try decoded.validate()
    }
}

private actor ExecutorBarrier {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

extension WorkflowExecutorTests {
    func testGeometryWholePairRejectsFirstSideInvalidationWhileSecondApplies() async throws {
        for maskChange in [false,true] {
            let f = try ExecutorFixture(checks: false), barrier = ExecutorBarrier()
            let ordered = f.batch.activeTasks.sorted { $0.id.uuidString < $1.id.uuidString }
            var services = f.services; let apply = services.apply
            services.apply = { snapshot,solution in
                if snapshot.taskID == ordered[1].id { await barrier.wait() }
                return try await apply(snapshot,solution)
            }
            let e = WorkflowExecutor(services: services)
            try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
            let work = Task { try await self.geometry(f,e) }
            while !(await barrier.entered) { await Task.yield() }
            let b = try await e.batch(batchID: f.batch.id), first = b.task(id: ordered[0].id)!
            if maskChange {
                var saved = first.snapshot!; saved.contentVersion = "concurrent-mask"
                try await e.update(batchID: b.id,event: .savedPSDChanged(taskID: first.id,snapshot: saved,change: .maskOnly,
                    expectedSourceVersion: first.sourceRevision,expectedSnapshotVersion: first.snapshot?.contentVersion))
            } else {
                try await e.update(batchID: b.id,event: .sourceChanged(taskID: first.id,sources: first.sources,expectedVersion: first.sourceRevision))
            }
            await barrier.release()
            do { try await work.value; XCTFail("stale pair confirmed") } catch WorkflowStateError.staleVersion {}
            let after = try await e.batch(batchID: b.id)
            XCTAssertNil(after.task(id: first.id)?[.geometry].confirmedVersion)
            XCTAssertFalse(after.activeTasks.flatMap(\.artifacts).contains { $0.kind == .hd && $0.state == .completed })
        }
    }
    func test4KWholePairRejectsFirstSideInvalidationWhileSecondReads() async throws {
        for presetChange in [false,true] {
            let (f,initial) = try await ready(); try await geometry(f,initial)
            let b = try await initial.batch(batchID: f.batch.id), barrier = ExecutorBarrier(), count = ExecutorInterruption()
            var services = f.services; let extract = services.extract
            services.extract = { snapshot in
                let index = count.next()
                if index == 1 { await f.probe.record("read-owner-\(snapshot.taskID.uuidString)") }
                if index == 2 { await barrier.wait() }
                return try await extract(snapshot)
            }
            let e = WorkflowExecutor(services: services)
            _ = try await e.register(manifestURL: f.manifest)
            let work = Task { try await self.square(f,e) }
            while !(await barrier.entered) { await Task.yield() }
            // Exactly the first-read side must change; the probe records extraction ordering deterministically.
            let firstOwner = await servicesOwnerFromExtractOrder(f: f, batch: b)
            if presetChange {
                let current = try await e.batch(batchID: b.id)
                try await e.update(batchID: b.id,event: .presetChanged(scope: .png4k,preset: WorkflowPreset(version: 2,fingerprint: "during-read"),expectedRevision: current.revision))
            } else {
                let first = b.task(id: firstOwner)!
                var saved = first.snapshot!; saved.contentVersion = "mask-during-read"
                try await e.update(batchID: b.id,event: .savedPSDChanged(taskID: first.id,snapshot: saved,change: .maskOnly,
                    expectedSourceVersion: first.sourceRevision,expectedSnapshotVersion: first.snapshot?.contentVersion))
            }
            await barrier.release()
            do { try await work.value; XCTFail("stale 4K approval accepted") } catch WorkflowStateError.staleVersion {}
            let after = try await e.batch(batchID: b.id)
            XCTAssertTrue(after.activeTasks.allSatisfy { $0.fourKExportRequested != true })
            XCTAssertFalse(after.activeTasks.flatMap(\.artifacts).contains { $0.kind == .png4k && $0.state == .completed })
        }
    }
    private func servicesOwnerFromExtractOrder(f: ExecutorFixture, batch: WorkflowBatch) async -> UUID {
        let values = await f.probe.values()
        let owner = values.last { $0.hasPrefix("read-owner-") }.map { String($0.dropFirst("read-owner-".count)) }
        return owner.flatMap(UUID.init(uuidString:)) ?? batch.activeTasks[0].id
    }
    func testRegistrationAndLoadRejectUnsafeNamesAndOutputSymlinkEscape() async throws {
        let f = try ExecutorFixture(checks: false)
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
        try FileManager.default.createSymbolicLink(at: f.batch.outputDirectory.appendingPathComponent("png 4k"),withDestinationURL: outside)
        do { try await WorkflowExecutor(services: f.services).register(batch: valid,manifestURL: f.manifest); XCTFail("symlink escape registered") } catch {}
        try JSONEncoder().encode(valid).write(to: f.manifest)
        do { _ = try await WorkflowExecutor(services: f.services).register(manifestURL: f.manifest); XCTFail("symlink escape loaded") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}

extension WorkflowExecutorTests {
    func testCanonicalOutputAliasIsAllowedAndLateSymlinkWritesNothingOutside() async throws {
        let f = try ExecutorFixture(checks: false)
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
        try FileManager.default.createSymbolicLink(at: canonical.appendingPathComponent("PSD"),withDestinationURL: outside)
        do { try await e.runPending(batchID: batch.id); XCTFail("late symlink used for stack output") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        do { try batch.validateOutputURL(alias.appendingPathComponent("../escape.psd")); XCTFail("normalized parent escaped output") } catch {}
    }
    func testSavedManualChangeMustBeRefreshedBeforeContinueReleasesLease() async throws {
        let (f,_) = try await ready(), coordinator = PhotoshopExecutionCoordinator()
        let e = WorkflowExecutor(services: f.services,coordinator: coordinator)
        _ = try await e.register(manifestURL: f.manifest)
        let b = try await e.batch(batchID: f.batch.id), side = b.activeTasks[0]
        _ = try await e.beginManualEditing(batchID: b.id,taskID: side.id)
        var saved = side.snapshot!; saved.contentVersion = "manual-current"
        try JSONEncoder().encode(saved).write(to: saved.workingURL)
        let queued = Task { try await coordinator.run(owner: side.id) { await f.probe.record("manual-changed-write") } }
        do { try await e.continueAutomatic(batchID: b.id); XCTFail("unrefreshed edit resumed") } catch WorkflowStateError.staleVersion {}
        let stillPaused = try await e.batch(batchID: b.id); XCTAssertTrue(stillPaused.isPaused)
        let blocked = await f.probe.values(); XCTAssertFalse(blocked.contains("manual-changed-write"))
        try await e.refreshSavedPSD(batchID: b.id,taskID: side.id,change: .geometry)
        try await e.continueAutomatic(batchID: b.id); try await queued.value
        let calls = await f.probe.values(); XCTAssertTrue(calls.contains("manual-changed-write"))
    }
}

extension WorkflowExecutorTests {
    func testPersistedAttemptRejectsParentNavigationThroughNestedSymlink() async throws {
        let f = try ExecutorFixture(checks: false)
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
            let f = try ExecutorFixture(checks: false,count: 2)
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
    func testParallelExportPausePreventsLatePublication() async throws {
        let f = try ExecutorFixture(checks: false,count: 2)
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
        XCTAssertFalse(paused.sideTasks.flatMap(\.artifacts).contains { $0.state == .completed })
        XCTAssertFalse(paused.sideTasks.flatMap(\.artifacts).contains { FileManager.default.fileExists(atPath: $0.url.path) })
        try await e.continueAutomatic(batchID: paused.id)
        let resumed = try await e.batch(batchID: paused.id)
        XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testParallelExportFailureKeepsSuccessfulSide() async throws {
        let f = try ExecutorFixture(checks: false,count: 2)
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
        try await reopened.retry(batchID: before.id,specimenIDs: before.specimens.map(\.id),stage: .hd)
        let after = try await reopened.batch(batchID: before.id),calls = await f.probe.values()
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.hd].state == .completed })
        XCTAssertEqual(after.sideTasks.filter { $0.id != failed }.flatMap(\.artifacts),artifacts)
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,4,"Retry renders only the failed face")
    }
}

actor WorkflowPipelineProbe {
    var events: [String] = []
    var psActive = 0, psPeak = 0
    var held: [String: CheckedContinuation<Void,Never>] = [:]
    var opened: Set<String> = []
    func mark(_ event: String) { events.append(event) }
    func beginPS(_ event: String) { psActive += 1; psPeak = max(psPeak,psActive); events.append(event) }
    func endPS(_ event: String) { psActive -= 1; events.append(event) }
    func hold(_ name: String) async { if !opened.contains(name) { await withCheckedContinuation { held[name] = $0 } } }
    func release(_ name: String) { opened.insert(name); held.removeValue(forKey: name)?.resume() }
    func contains(_ name: String) -> Bool { events.contains(name) }
}

extension WorkflowExecutorTests {
    private func pipelineWait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Pipeline event did not arrive"); throw WorkflowStateError.invalidTransition
    }
    func testMattePipelineOverlapsPSAndAIWithoutParallelAI() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: true),fake = try AIInferenceWorkerTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); fake.remove() }
        let script = AIInferenceWorkerTests.Fixture.script.replacingOccurrences(of: "root/'release'",with: "root/('release-'+name)")
        try script.write(to: fake.root.appendingPathComponent("scripts/toolkit_bridge.py"),atomically: true,encoding: .utf8)
        let ps = PhotoshopExecutionCoordinator(),worker = AIInferenceWorker(),probe = WorkflowPipelineProbe()
        let a = f.batch.activeTasks[0].id,b = f.batch.activeTasks[1].id
        let original = f.services
        var services = original
        services.exportStack = { snapshot in
            if snapshot.taskID != a {
                for _ in 0..<500 {
                    if fake.events().contains("hold-A") { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            return try await ps.run(owner: snapshot.taskID) {
                let name = snapshot.taskID == a ? "A" : "B"
                await probe.beginPS("export-"+name)
                let old = try await original.exportStack(snapshot)
                await probe.endPS("export-done-"+name)
                return StackPNG(snapshotVersion: old.snapshotVersion,pngURL: fake.request("hold-"+name).input,fingerprint: name,pixelSize: old.pixelSize,orientation: 1,colorProfile: old.colorProfile)
            }
        }
        services.infer = { input in
            _ = try await worker.infer(fake.request(input.pngURL.lastPathComponent))
            return try await original.infer(input)
        }
        services.install = { snapshot,matte in
            try await ps.run(owner: snapshot.taskID) {
                let name = snapshot.taskID == a ? "A" : "B"
                await probe.beginPS("install-"+name)
                if snapshot.taskID == a { await probe.hold("install-A") }
                let result = try await original.install(snapshot,matte)
                await probe.endPS("install-done-"+name); return result
            }
        }
        services.endInferenceSession = { await worker.shutdown() }
        let e = WorkflowExecutor(services: services,coordinator: ps)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        // Always release gates, even when old serial scheduling fails the overlap assertion.
        do {
            try await pipelineWait { fake.events().contains("hold-A") }
            try await pipelineWait { await probe.contains("export-B") }
        } catch { }
        XCTAssertFalse(fake.events().contains("hold-B"),"The second AI request must wait behind A")
        try Data().write(to: fake.root.appendingPathComponent("release-hold-A"))
        do {
            try await pipelineWait { fake.events().contains("hold-B") }
            try await pipelineWait { await probe.contains("install-A") }
        } catch { }
        let during = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(during.activeTasks.filter { $0[.matte].state == .running }.count,2)
        XCTAssertEqual(during.task(id: b)?[.matte].state,.running)
        await probe.release("install-A")
        try Data().write(to: fake.root.appendingPathComponent("release-hold-B"))
        try await run.value
        let after = try await e.batch(batchID: f.batch.id),peak = await probe.psPeak
        XCTAssertEqual(peak,1); XCTAssertEqual(try fake.starts().count,1)
        XCTAssertEqual(fake.events().split(separator: "\n").map(String.init),["hold-A","hold-B"])
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
    }
    func testPipelinePauseAndManualLeaseDrainSafely() async throws {
        let f = try ExecutorFixture(checks: false,count: 2),ps = PhotoshopExecutionCoordinator(),probe = WorkflowPipelineProbe()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let a = f.batch.activeTasks[0].id,original = f.services
        var services = original
        services.exportStack = { snapshot in try await ps.run(owner: snapshot.taskID) {
            await probe.mark("export-"+snapshot.taskID.uuidString); return try await original.exportStack(snapshot)
        } }
        services.install = { snapshot,matte in try await ps.run(owner: snapshot.taskID) {
            await probe.beginPS("install-"+snapshot.taskID.uuidString)
            if snapshot.taskID == a { await probe.hold("PS") }
            let saved = try await original.install(snapshot,matte)
            await probe.endPS("PS-finished"); return saved
        } }
        let e = WorkflowExecutor(services: services,coordinator: ps)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        try await pipelineWait { await probe.contains("install-"+a.uuidString) }
        await e.pause(batchID: f.batch.id)
        let manual = Task { _ = try await e.beginManualEditing(batchID: f.batch.id,taskID: a); await probe.mark("manual-opened") }
        let before = await probe.events
        XCTAssertFalse(before.contains("PS-finished")); XCTAssertFalse(before.contains("manual-opened"))
        await probe.release("PS"); try await run.value; try await manual.value
        let events = await probe.events,after = try await e.batch(batchID: f.batch.id)
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "PS-finished")),try XCTUnwrap(events.firstIndex(of: "manual-opened")))
        XCTAssertLessThanOrEqual(events.filter { $0.hasPrefix("export-") }.count,2)
        XCTAssertTrue(after.isPaused); XCTAssertFalse(after.activeTasks.contains { $0[.matte].state == .completed })
        await ps.endManualEditing(owner: a)
    }
    func testPipelineRestartReusesCompletedInference() async throws {
        let f = try ExecutorFixture(checks: false),ps = PhotoshopExecutionCoordinator(),probe = WorkflowPipelineProbe()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let a = f.batch.activeTasks[0].id,original = f.services
        var services = original
        services.exportStack = { snapshot in try await ps.run(owner: snapshot.taskID) { try await original.exportStack(snapshot) } }
        services.install = { snapshot,matte in try await ps.run(owner: snapshot.taskID) {
            let saved = try await original.install(snapshot,matte)
            if snapshot.taskID == a { await probe.mark("saved-A"); await probe.hold("saved-A") }
            return saved
        } }
        let e = WorkflowExecutor(services: services,coordinator: ps)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        try await pipelineWait { await probe.contains("saved-A") }
        // Both immutable AI results must become durable even while A holds Photoshop's lease.
        do { try await pipelineWait {
            let batch = try? await e.batch(batchID: f.batch.id)
            return batch?.activeTasks.allSatisfy { $0.matteArtifact != nil } == true
        } } catch { }
        await e.pause(batchID: f.batch.id); await probe.release("saved-A"); try await run.value
        let saved = try await WorkflowBatchStore().load(from: f.manifest)
        XCTAssertEqual(saved.activeTasks.filter { $0.matteArtifact != nil }.count,2)
        let reopened = WorkflowExecutor(services: original,coordinator: ps)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.continueAutomatic(batchID: saved.id)
        let calls = await f.probe.values(),after = try await reopened.batch(batchID: saved.id)
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2,"Persisted inference must not repeat")
        XCTAssertEqual(calls.filter { $0 == "install" }.count,2,"A's saved PSD must not be installed twice")
        XCTAssertTrue(calls.contains("validate-installed"))
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
    }
}

extension WorkflowExecutorTests {
    func testResumeCannotChangeStateUntilPausedRunDrains() async throws {
        let f = try ExecutorFixture(checks: false),entered = expectation(description: "Two renders before resume")
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
        let paused = try await e.batch(batchID: f.batch.id); XCTAssertTrue(paused.isPaused)
        await e.pause(batchID: f.batch.id); await gate.release(); try await run.value
        try await e.continueAutomatic(batchID: f.batch.id)
        let resumed = try await e.batch(batchID: f.batch.id)
        XCTAssertFalse(resumed.isPaused); XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.hd].state == .completed })
    }
    func testPipelineWorkerCrashDoesNotMasqueradeAsBatchPause() async throws {
        let f = try ExecutorFixture(checks: false),fake = try AIInferenceWorkerTests.Fixture(),worker = AIInferenceWorker()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); fake.remove() }
        let a = f.batch.activeTasks[0].id,original = f.services
        var services = original
        services.exportStack = { snapshot in
            if snapshot.taskID != a {
                for _ in 0..<500 {
                    if FileManager.default.fileExists(atPath: fake.root.appendingPathComponent("term").path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let old = try await original.exportStack(snapshot)
            return StackPNG(snapshotVersion: old.snapshotVersion,pngURL: fake.request(snapshot.taskID == a ? "wrong-id-ignore-term" : "second").input,fingerprint: old.fingerprint,pixelSize: old.pixelSize,orientation: 1,colorProfile: old.colorProfile)
        }
        services.infer = { input in _ = try await worker.infer(fake.request(input.pngURL.lastPathComponent)); return try await original.infer(input) }
        services.endInferenceSession = { await worker.shutdown() }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        do { try await e.runPending(batchID: f.batch.id) } catch { XCTFail("Crash is a per-face failure, not parent cancellation: \(error)") }
        let after = try await e.batch(batchID: f.batch.id)
        XCTAssertFalse(after.isPaused)
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .failed })
        XCTAssertEqual(try fake.starts().count,1)
    }
}

extension ExecutorFixture {
    /// Real immutable cache identities, without Photoshop or model inference.
    nonisolated var cachedServices: WorkflowExecutor.Services {
        var result = services
        let original = services, root = batch.outputDirectory.appendingPathComponent(".work")
        result.exportStack = { snapshot in
            _ = try await original.exportStack(snapshot)
            let url = root.appendingPathComponent("data/processed/\(snapshot.taskID).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
            try Data(snapshot.taskID.uuidString.utf8).write(to: url)
            return StackPNG(snapshotVersion: snapshot.contentVersion,pngURL: url,fingerprint: try AIFileValidation.hash(url.path),pixelSize: snapshot.pixelSize,orientation: 1,colorProfile: "sRGB")
        }
        result.infer = { input in
            _ = try await original.infer(input)
            let folder = root.appendingPathComponent("AI/\(input.pngURL.lastPathComponent)")
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let alpha = folder.appendingPathComponent("alpha.png"), cutout = folder.appendingPathComponent("cutout.png")
            try Data("alpha".utf8).write(to: alpha); try Data("cutout".utf8).write(to: cutout)
            return MatteArtifact(inputPNGFingerprint: input.fingerprint,alphaURL: alpha,alphaFingerprint: try AIFileValidation.hash(alpha.path),cutoutURL: cutout,cutoutFingerprint: try AIFileValidation.hash(cutout.path),orientation: 1,pixelSize: input.pixelSize)
        }
        return result
    }
}

extension WorkflowExecutorTests {
    func testPhasedMatteCompletesInputsBeforeStartingWorkerAndWaitsForExit() async throws {
        let f = try ExecutorFixture(checks: false,count: 2,checkMatte: true)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let worker = AIInferenceWorker(), fake = try AIInferenceWorkerTests.Fixture(), original = f.cachedServices
        defer { fake.remove() }
        var services = original
        services.infer = { input in
            _ = try await worker.infer(fake.request(input.pngURL.lastPathComponent))
            return try await original.infer(input)
        }
        services.endInferenceSession = {
            await worker.shutdown()
            if let starts = try? fake.starts() { for pid in starts { XCTAssertEqual(kill(pid,0),-1) } }
            await f.probe.record("worker-exit")
        }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        let calls = await f.probe.values(), result = try await e.batch(batchID: f.batch.id)
        let firstAI = try XCTUnwrap(calls.firstIndex(of: "ai")), lastAI = try XCTUnwrap(calls.lastIndex(of: "ai"))
        XCTAssertEqual(try fake.starts().count,1)
        XCTAssertEqual(calls[..<firstAI].filter { $0 == "export-stack" }.count,4)
        XCTAssertFalse(calls[firstAI...lastAI].contains { ["refresh","extract","export-stack","install"].contains($0) })
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "worker-exit")),try XCTUnwrap(calls.firstIndex(of: "install")))
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.matte].state == .waitingReview && $0.stackPNG == nil && $0.matteArtifact == nil })
    }
    func testPreparedInferenceDoesNotCompleteMatteOrCleanFiles() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: true), gate = WorkflowPipelineProbe()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = f.cachedServices
        services.endInferenceSession = { await gate.mark("shutdown"); await gate.hold("exit") }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        do { try await pipelineWait { await gate.contains("shutdown") } } catch { await gate.release("exit"); _ = try? await run.value; throw error }
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.matte].state == .pending && $0[.matte].outputVersion == nil && $0[.geometry].state == .pending })
        for t in b.activeTasks {
            if let input = t.stackPNG, let matte = t.matteArtifact {
                XCTAssertTrue(FileManager.default.fileExists(atPath: input.pngURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: matte.alphaURL.path))
            } else { XCTFail("Preparation must remain durable until install") }
        }
        await gate.release("exit"); try await run.value
    }
}

extension WorkflowExecutorTests {
    func testPhasedResumeReusesArtifactsAcrossAllBoundaries() async throws {
        for boundary in ["input","prepared","published"] {
            let f = try ExecutorFixture(checks: false,checkMatte: true), original = f.cachedServices
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            var interrupted = original
            if boundary == "input" { interrupted.infer = { _ in throw WorkflowBridgeError.photoshop("interrupted before AI") } }
            else { interrupted.install = { snapshot,matte in
                if boundary == "published" { _ = try await original.install(snapshot,matte) }
                throw WorkflowBridgeError.photoshop("interrupted install")
            } }
            let e = WorkflowExecutor(services: interrupted,matteScheduling: .phased)
            try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
            let failed = try await e.batch(batchID: f.batch.id)
            XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.matte].state == .failed && $0.stackPNG != nil })
            let reopened = WorkflowExecutor(services: original,matteScheduling: .phased)
            _ = try await reopened.register(manifestURL: f.manifest)
            try await reopened.retry(batchID: failed.id,specimenIDs: failed.specimens.map(\.id),stage: .matte)
            let after = try await reopened.batch(batchID: failed.id), calls = await f.probe.values()
            XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
            XCTAssertEqual(calls.filter { $0 == "export-stack" }.count,2,boundary)
            XCTAssertEqual(calls.filter { $0 == "ai" }.count,2,boundary)
            XCTAssertEqual(calls.filter { $0 == "install" }.count,2,boundary)
            if boundary == "published" { XCTAssertEqual(calls.filter { $0 == "validate-installed" }.count,2) }
        }
    }
    func testInstallPhaseCannotInferAgainAndFailurePreservesBatchBarrier() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: false), original = f.cachedServices
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let first = f.batch.activeTasks[0].id
        var services = original
        services.endInferenceSession = {
            let alpha = f.batch.outputDirectory.appendingPathComponent(".work/AI/\(first).png/alpha.png")
            if FileManager.default.fileExists(atPath: alpha.path) { try? Data("tampered".utf8).write(to: alpha) }
        }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id), calls = await f.probe.values()
        XCTAssertEqual(b.task(id: first)?[.matte].state,.failed)
        XCTAssertEqual(b.activeTasks.filter { $0[.matte].state == .completed }.count,1)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.geometry].state == .pending })
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "install" }.count,1)
        XCTAssertTrue(b.specimens.allSatisfy { !$0.isExcluded })
        let retry = WorkflowExecutor(services: original,matteScheduling: .phased)
        _ = try await retry.register(manifestURL: f.manifest)
        try await retry.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .matte)
        let repaired = try await retry.batch(batchID: b.id), retriedCalls = await f.probe.values()
        XCTAssertTrue(repaired.activeTasks.allSatisfy { $0[.matte].state == .completed })
        XCTAssertEqual(retriedCalls.filter { $0 == "ai" }.count,3,"Only explicit retry may recompute the damaged result")
        XCTAssertEqual(retriedCalls.filter { $0 == "export-stack" }.count,2)
    }
    func testPhasedPreparationFailureSkipsOnlyFailedFaceAndUserSaveRejectsStaleInput() async throws {
        for boundary in ["export","save"] {
            let f = try ExecutorFixture(checks: false,checkMatte: false), original = f.cachedServices
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            let first = f.batch.activeTasks[0].id
            var services = original
            if boundary == "export" { services.exportStack = { snapshot in
                if snapshot.taskID == first { throw WorkflowBridgeError.photoshop("PS unavailable") }
                return try await original.exportStack(snapshot)
            } } else { services.refresh = { url,owner,sources in
                var snapshot = try await original.refresh(url,owner,sources)
                if owner == first { snapshot.contentVersion = "user-saved" }
                return snapshot
            } }
            let e = WorkflowExecutor(services: services,matteScheduling: .phased)
            try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
            let b = try await e.batch(batchID: f.batch.id), calls = await f.probe.values()
            XCTAssertEqual(b.task(id: first)?[.matte].state,.failed)
            XCTAssertEqual(calls.filter { $0 == "ai" }.count,1)
            XCTAssertEqual(calls.filter { $0 == "install" }.count,1)
            XCTAssertFalse(calls.contains("analyze"))
        }
    }
    func testPhasedFatalWorkerErrorCannotAutoRestart() async throws {
        let f = try ExecutorFixture(checks: false), fake = try AIInferenceWorkerTests.Fixture(), worker = AIInferenceWorker()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); fake.remove() }
        let original = f.cachedServices, first = f.batch.activeTasks[0].id
        var services = original
        services.infer = { input in
            _ = try await worker.infer(fake.request(input.pngURL.lastPathComponent == "\(first).png" ? "wrong-id" : "second"))
            return try await original.infer(input)
        }
        services.endInferenceSession = { await worker.shutdown() }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertFalse(b.isPaused); XCTAssertTrue(b.activeTasks.allSatisfy { $0[.matte].state == .failed })
        XCTAssertEqual(try fake.starts().count,1)
        for pid in try fake.starts() { XCTAssertEqual(kill(pid,0),-1,"Shutdown must await actual process exit") }
    }
}

private actor PhasedShutdownGate {
    var entered = false
    var released = false
    var waiting: [CheckedContinuation<Void,Never>] = []
    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() { released = true; let old = waiting; waiting = []; for waiter in old { waiter.resume() } }
}

extension WorkflowExecutorTests {
    func testPhasedPauseAfterInferenceRetainsResultsAndCannotInstallBeforeDrain() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: true), gate = PhasedShutdownGate(), original = f.cachedServices
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = original; services.endInferenceSession = { await gate.hold() }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        try await pipelineWait { await gate.entered }
        let pause = Task { await e.pause(batchID: f.batch.id) }
        try await pipelineWait { (try? await e.batch(batchID: f.batch.id).isPaused) == true }
        let during = await f.probe.values(); XCTAssertFalse(during.contains("install"))
        do { try await e.continueAutomatic(batchID: f.batch.id); XCTFail("Resume before drain") } catch WorkflowStateError.invalidTransition {}
        await gate.release(); await pause.value; try await run.value
        let reopened = WorkflowExecutor(services: original,matteScheduling: .phased)
        let id = try await reopened.register(manifestURL: f.manifest)
        try await reopened.continueAutomatic(batchID: id)
        let calls = await f.probe.values(), after = try await reopened.batch(batchID: id)
        XCTAssertEqual(calls.filter { $0 == "export-stack" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "install" }.count,2)
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
    }
    func testPhasedPauseDuringInputRejectsLateCacheAndReusesEarlierInput() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: true), gate = WorkflowPipelineProbe(), original = f.cachedServices
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let last = f.batch.activeTasks[1].id
        var services = original
        services.exportStack = { snapshot in
            let input = try await original.exportStack(snapshot)
            if snapshot.taskID == last { await gate.mark("input"); await gate.hold("finish") }
            return input
        }
        let e = WorkflowExecutor(services: services,matteScheduling: .phased)
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: f.batch.id) }
        try await pipelineWait { await gate.contains("input") }
        await e.pause(batchID: f.batch.id); await gate.release("finish"); try await run.value
        let paused = try await e.batch(batchID: f.batch.id)
        XCTAssertNotNil(paused.activeTasks[0].stackPNG); XCTAssertNil(paused.activeTasks[1].stackPNG)
        let reopened = WorkflowExecutor(services: original,matteScheduling: .phased)
        _ = try await reopened.register(manifestURL: f.manifest); try await reopened.continueAutomatic(batchID: f.batch.id)
        let calls = await f.probe.values(); XCTAssertEqual(calls.filter { $0 == "export-stack" }.count,3)
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
    }
    func testPhasedInstalledSnapshotNeedsNoCleanedAIInputs() async throws {
        let f = try ExecutorFixture(checks: false,checkMatte: true), original = f.cachedServices
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let first = WorkflowExecutor(services: original,matteScheduling: .phased)
        try await first.register(batch: f.batch,manifestURL: f.manifest); try await first.runPending(batchID: f.batch.id)
        var b = try await first.batch(batchID: f.batch.id)
        for i in b.specimens.indices {
            b.specimens[i].front[.matte].state = .pending; b.specimens[i].back[.matte].state = .pending
        }
        let resumed = WorkflowExecutor(services: original,matteScheduling: .phased)
        try await resumed.register(batch: b,manifestURL: f.manifest); try await resumed.runPending(batchID: b.id)
        let after = try await resumed.batch(batchID: b.id), calls = await f.probe.values()
        XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "export-stack" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "install" }.count,2)
    }
}

extension WorkflowExecutorTests {
    func testPhasedActiveInferenceCancellationDrainsWorkerAndRejectsLateResults() async throws {
        for parentCancellation in [false,true] {
            let f = try ExecutorFixture(checks: false,checkMatte: true), fake = try AIInferenceWorkerTests.Fixture(), worker = AIInferenceWorker()
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); fake.remove() }
            let original = f.cachedServices
            var services = original
            services.infer = { input in
                _ = try await worker.infer(fake.request("ignore-term-hold"))
                return try await original.infer(input)
            }
            services.endInferenceSession = { await worker.shutdown() }
            let e = WorkflowExecutor(services: services,matteScheduling: .phased)
            try await e.register(batch: f.batch,manifestURL: f.manifest)
            let run = Task { try await e.runPending(batchID: f.batch.id) }
            try await pipelineWait { fake.events().contains("ignore-term-hold") }
            if parentCancellation { run.cancel() } else { await e.pause(batchID: f.batch.id) }
            do { try await run.value; XCTAssertFalse(parentCancellation) }
            catch is CancellationError { XCTAssertTrue(parentCancellation) }
            let paused = try await e.batch(batchID: f.batch.id), calls = await f.probe.values()
            XCTAssertTrue(paused.isPaused)
            XCTAssertTrue(paused.activeTasks.allSatisfy { $0[.matte].state == .pending && $0.stackPNG != nil && $0.matteArtifact == nil })
            XCTAssertFalse(calls.contains("install")); XCTAssertFalse(calls.contains("ai"))
            XCTAssertEqual(try fake.starts().count,1)
            XCTAssertEqual(fake.events().split(separator: "\n").count,1)
            for pid in try fake.starts() { XCTAssertEqual(kill(pid,0),-1) }
            let resumed = WorkflowExecutor(services: original,matteScheduling: .phased)
            _ = try await resumed.register(manifestURL: f.manifest); try await resumed.continueAutomatic(batchID: f.batch.id)
            let after = try await resumed.batch(batchID: f.batch.id)
            XCTAssertTrue(after.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
        }
    }
}
