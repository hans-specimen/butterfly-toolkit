import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowExecutorTests: XCTestCase {
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
    var gate: CheckedContinuation<Void, Never>?
    var blockRender = false
    func record(_ call: String) { calls.append(call) }
    func values() -> [String] { calls }
    func fail(_ kinds: Set<WorkflowAssetKind>) { failing = kinds }
    func render(_ kind: WorkflowAssetKind, to url: URL) async throws {
        calls.append("render-\(kind.rawValue)")
        if blockRender { await withCheckedContinuation { gate = $0 } }
        if failing.contains(kind) { throw WorkflowBridgeError.invalidImage("injected") }
        try Data(kind.rawValue.utf8).write(to: url)
    }
    func block() { blockRender = true }
    func release() { blockRender = false; gate?.resume(); gate = nil }
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
        try await e.configureDerivatives(batchID: f.batch.id,kinds: [.white1k,.footage],watermarkURL: nil)
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
        await f.probe.fail([.white1k]); try await square(f,e)
        var b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.derivatives].state == .failed })
        let old = await f.probe.values()
        await f.probe.fail([])
        try await e.retry(batchID: b.id,specimenIDs: b.specimens.map(\.id),stage: .derivatives)
        b = try await e.batch(batchID: b.id); XCTAssertTrue(b.allSucceeded)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "render-footage" }.count,old.filter { $0 == "render-footage" }.count)
        XCTAssertEqual(calls.filter { $0 == "render-png4k" }.count,2)
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
        try await e.configureDerivatives(batchID: f.batch.id,kinds: [],watermarkURL: nil)
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
    func testSavedPSDChangedOutsideExecutorRejectsGeometryConfirmation() async throws {
        let f = try ExecutorFixture(checks: false)
        var services = f.services
        services.refresh = { url,owner,_ in ExecutorFixture.snapshot(owner,url,"unrefreshed-manual-edit",roles: true) }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        do { try await geometry(f,e); XCTFail("stale saved PSD accepted") } catch WorkflowStateError.staleVersion {}
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("apply-save"))
    }
    func testWatermarkFailureIsIsolatedAndContentChangeRerendersOnlyXianyu() async throws {
        let f = try ExecutorFixture(checks: false)
        var services = f.services; let render = services.render
        services.render = { kind,roles,layout,source,mark,url in
            if kind == .xianyu && mark == nil { throw WorkflowBridgeError.invalidImage("missing watermark") }
            try await render(kind,roles,layout,source,mark,url)
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        try await geometry(f,e); try await square(f,e)
        var b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { task in task[.derivatives].state == .failed && task.artifacts.contains { $0.kind == .footage && $0.state == .completed } && task.artifacts.contains { $0.kind == .xianyu && $0.state == .failed } })
        let mark = f.batch.outputDirectory.appendingPathComponent("watermark.png")
        try Data("watermark1".utf8).write(to: mark)
        try await e.configureDerivatives(batchID: b.id,kinds: [.xianyu,.white1k,.footage],watermarkURL: mark)
        try await e.runPending(batchID: b.id)
        let old = await f.probe.values()
        try Data("watermark2".utf8).write(to: mark)
        try await e.configureDerivatives(batchID: b.id,kinds: [.xianyu,.white1k,.footage],watermarkURL: mark)
        try await e.runPending(batchID: b.id)
        let calls = await f.probe.values(); b = try await e.batch(batchID: b.id)
        XCTAssertTrue(b.allSucceeded)
        XCTAssertEqual(calls.filter { $0 == "render-xianyu" }.count,old.filter { $0 == "render-xianyu" }.count+2)
        XCTAssertEqual(calls.filter { $0 == "render-footage" }.count,old.filter { $0 == "render-footage" }.count)
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,2)
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
            var services = f.services; let refresh = services.refresh
            services.refresh = { url,owner,sources in
                let index = count.next()
                if index == 1 { await f.probe.record("read-owner-\(owner.uuidString)") }
                if index == 2 { await barrier.wait() }
                return try await refresh(url,owner,sources)
            }
            let e = WorkflowExecutor(services: services)
            _ = try await e.register(manifestURL: f.manifest)
            let work = Task { try await self.square(f,e) }
            while !(await barrier.entered) { await Task.yield() }
            // Exactly the first-read side must change; the probe records refresh ordering deterministically.
            let firstOwner = await servicesOwnerFromRefreshOrder(f: f, batch: b)
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
    private func servicesOwnerFromRefreshOrder(f: ExecutorFixture, batch: WorkflowBatch) async -> UUID {
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
