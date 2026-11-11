// 验证逐面自动处理顺序、失败隔离及单面确认与导出。
import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowPerImageTests: XCTestCase {
    func testEachFaceFinishesAutomaticStepsBeforeNextFaceStarts() async throws {
        let f = try ExecutorFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = f.services
        services.selectSubject = { snapshot in
            await f.probe.record("select-subject")
            let saved = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "matte", roles: true)
            try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
            return saved
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let calls = await f.probe.values().filter { ["stack", "select-subject", "apply-save"].contains($0) }
        XCTAssertEqual(calls, Array(repeating: ["stack", "select-subject", "apply-save"], count: 4).flatMap { $0 })
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.artifacts.isEmpty })
    }

    func testFailedFaceDoesNotBlockOtherFaces() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let failedID = batch.specimens[0].front.id
        var services = f.services
        services.selectSubject = { snapshot in
            if snapshot.taskID == failedID { throw WorkflowBridgeError.invalidImage("主体无法识别") }
            let saved = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "matte", roles: true)
            try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
            return saved
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertEqual(result.specimens[0].front[.matte].state, .failed)
        XCTAssertEqual(result.specimens[0].front[.geometry].state, .pending)
        XCTAssertEqual(result.specimens[0].back[.geometry].state, .waitingReview)
    }
    func testPauseFinishesCurrentSavedStepWithoutStartingNextStep() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let entered = expectation(description: "stack started"), gate = PerImagePauseGate(entered)
        var services = f.services; let original = services.stack
        services.stack = { job,id in await gate.hold(); return try await original(job,id) }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        let run = Task { try await e.runPending(batchID: batch.id) }
        await fulfillment(of: [entered],timeout: 3)
        await e.pause(batchID: batch.id)
        await gate.release()
        _ = try? await run.value
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.specimens[0].front[.stack].state, .completed)
        XCTAssertEqual(result.specimens[0].front[.matte].state, .pending)
        XCTAssertEqual(result.specimens[0].back[.stack].state, .pending)
    }

    func testSingleFaceConfirmationAndPNGExportDoNotRequireOtherFaceOrJPEG() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = f.services
        services.selectSubject = { snapshot in
            let saved = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "matte", roles: true)
            try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
            return saved
        }
        services.finalize = { url,id in
            var saved = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: url))
            saved.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "a", baseLayer: "b", cutoutLayer: "c")
            return saved
        }
        services.extract = { snapshot in
            var roles = ExecutorFixture.roles(snapshot); roles.isFinalized = snapshot.finalRoles != nil; return roles
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        let id = batch.specimens[0].front.id
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: [id])
        var result = try await e.batch(batchID: batch.id)
        XCTAssertEqual(result.specimens[0].front[.geometry].state, .completed)
        XCTAssertEqual(result.specimens[0].back[.geometry].state, .waitingReview)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.artifacts.isEmpty })
        try await e.requestExports(batchID: batch.id, taskIDs: [id], kinds: [.png4k], policy: .skipExisting, layouts: [:])
        result = try await e.batch(batchID: batch.id)
        XCTAssertEqual(result.specimens[0].front[.png4k].state, .completed)
        XCTAssertEqual(result.specimens[0].front[.hd].state, .pending)
        XCTAssertEqual(result.specimens[0].front.artifacts.filter { $0.state == .completed }.map(\.kind), [.png4k])
        XCTAssertTrue(result.specimens[0].back.artifacts.isEmpty)
    }

    private func nativeServices(_ f: ExecutorFixture) -> WorkflowExecutor.Services {
        var services = f.services
        services.finalize = { url,id in
            var saved = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: url))
            saved.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "a",baseLayer: "b",cutoutLayer: "c")
            return saved
        }
        services.extract = { snapshot in
            var roles = ExecutorFixture.roles(snapshot); roles.isFinalized = snapshot.finalRoles != nil; return roles
        }
        services.acknowledgeManualResult = { _ in await f.probe.record("adopt-current") }
        return services
    }
    private func registered(_ f: ExecutorFixture,services: WorkflowExecutor.Services? = nil) async throws -> WorkflowExecutor {
        var batch = f.batch
        let e = WorkflowExecutor(services: services ?? nativeServices(f),coordinator: PhotoshopExecutionCoordinator())
        try await e.register(batch: batch,manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        return e
    }

    func testSkipCurrentOverwriteAndSkipOutdatedAreDistinct() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = try await registered(f), id = f.batch.specimens[0].front.id
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .skipExisting,layouts: [:])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .skipExisting,layouts: [:])
        var result = try await e.batch(batchID: f.batch.id)
        var calls = await f.probe.values().filter { $0 == "render-png4k" }
        XCTAssertEqual(calls.count,1)
        XCTAssertEqual(result.task(id: id)?.exportNotes?[.png4k],"当前版本已导出，已跳过")
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .overwrite,layouts: [:])
        calls = await f.probe.values().filter { $0 == "render-png4k" }; XCTAssertEqual(calls.count,2)
        var layout = SquareLayout.png4k; layout.center.x += 0.02
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .skipExisting,layouts: [id:layout])
        result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?[.png4k].state,.pending)
        XCTAssertEqual(result.task(id: id)?.exportNotes?[.png4k],"待更新，已跳过")
        calls = await f.probe.values().filter { $0 == "render-png4k" }; XCTAssertEqual(calls.count,2)
    }

    func testPartialExportFailureRetriesOnlyFailedType() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = try await registered(f), id = f.batch.specimens[0].front.id
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        await f.probe.fail([.png4k])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.hd,.png4k],policy: .skipExisting,layouts: [:])
        var result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?[.hd].state,.completed)
        XCTAssertEqual(result.task(id: id)?[.png4k].state,.failed)
        await f.probe.fail([])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.hd,.png4k],policy: .skipExisting,layouts: [:])
        result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?[.png4k].state,.completed)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,1)
        XCTAssertEqual(calls.filter { $0 == "render-png4k" }.count,2)
    }

    func testInterruptedWriteRequiresExplicitManualAdoptionAndNeverAutoResumes() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = nativeServices(f)
        services.apply = { _,_ in throw WorkflowBridgeError.interruptedWrite("injected") }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        var result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.task(id: id)?.manualAdoptionRequired,true)
        XCTAssertEqual(result.specimens[0].back[.stack].state,.pending)
        do { try await e.refreshFinalPSD(batchID: f.batch.id,taskID: id); XCTFail("ordinary refresh must not adopt") }
        catch { XCTAssertTrue(error is WorkflowBridgeError) }
        _ = try await e.beginManualEditing(batchID: f.batch.id,taskID: id)
        try await e.adoptCurrentPSD(batchID: f.batch.id,taskID: id)
        try await e.endManualEditing(batchID: f.batch.id)
        result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.task(id: id)?.manualAdoptionRequired,false)
        XCTAssertNil(result.task(id: id)?.geometryApplySourceVersion)
        XCTAssertEqual(result.task(id: id)?[.geometry].state,.waitingReview)
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.task(id: id)?[.geometry].state,.completed)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.artifacts.isEmpty })
    }

    func testOldManifestIsRejectedWithoutChangingFilesOrUsingPrevious() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var old = f.batch; old.schemaVersion = 1
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: f.manifest)
        try JSONEncoder().encode(f.batch).write(to: f.manifest.appendingPathExtension("previous"))
        do { _ = try await WorkflowBatchStore().load(from: f.manifest); XCTFail("old schema must not resume") }
        catch { XCTAssertTrue(error is WorkflowStateError) }
        XCTAssertEqual(try Data(contentsOf: f.manifest),bytes)
    }

    func testEarlyManualViewCanEndWithoutSkippingFailedMatte() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = nativeServices(f)
        services.selectSubject = { _ in throw WorkflowBridgeError.invalidImage("no subject") }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        _ = try await e.beginManualEditing(batchID: f.batch.id,taskID: id)
        try await e.endManualEditing(batchID: f.batch.id)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.task(id: id)?[.matte].state,.failed)
        XCTAssertEqual(result.task(id: id)?[.geometry].state,.pending)
        do { try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id]); XCTFail() } catch {}
    }

    func testCannotExcludeManuallyOwnedSpecimen() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = try await registered(f), id = f.batch.specimens[0].front.id
        _ = try await e.beginManualEditing(batchID: f.batch.id,taskID: id)
        let before = try await e.batch(batchID: f.batch.id)
        do {
            try await e.update(batchID: f.batch.id,event: .excludeSpecimens(ids: [before.specimens[0].id],reason: "skip",expectedRevision: before.revision))
            XCTFail("manual owner cannot be excluded")
        } catch {}
        try await e.endManualEditing(batchID: f.batch.id)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertFalse(result.specimens[0].isExcluded)
    }

    func testHDExportBecomesOutdatedEvenWhenOnlyMaskVersionChanges() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = try await registered(f), id = f.batch.specimens[0].front.id
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.hd],policy: .skipExisting,layouts: [:])
        let original = try await e.batch(batchID: f.batch.id).task(id: id)!.snapshot!
        var edited = original; edited.contentVersion = "mask-edited"
        try JSONEncoder().encode(edited).write(to: edited.workingURL)
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.hd],policy: .skipExisting,layouts: [:])
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?.exportNotes?[.hd],"待更新，已跳过")
        XCTAssertEqual(result.task(id: id)?[.hd].state,.pending)
    }

    func testReprocessingGeometryUsesMatteCheckpointAndPreservesPreviousPSD() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = nativeServices(f)
        services.restoreCheckpoint = { snapshot,destination in
            XCTAssertEqual(snapshot.contentVersion,"matte")
            var copy = snapshot; copy.workingURL = destination
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),withIntermediateDirectories: true)
            try JSONEncoder().encode(copy).write(to: destination)
            return copy
        }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        let before = try await e.batch(batchID: f.batch.id).task(id: id)!.snapshot!
        let bytes = try Data(contentsOf: before.workingURL)
        try await e.reprocessTask(batchID: f.batch.id,taskID: id,from: .geometry,expectedVersion: before.contentVersion)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertNotEqual(result.task(id: id)?.snapshot?.workingURL,before.workingURL)
        XCTAssertEqual(try Data(contentsOf: before.workingURL),bytes)
        XCTAssertEqual(result.task(id: id)?[.geometry].state,.waitingReview)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "stack" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,3)
    }

    func testExportPauseStopsRefillingQueueAfterAlreadyStartedFiles() async throws {
        let f = try ExecutorFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = try await registered(f), ids = Set(f.batch.activeTasks.map(\.id))
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: ids)
        await f.probe.block()
        let request = Task { try await e.requestExports(batchID: f.batch.id,taskIDs: ids,kinds: [.hd],policy: .skipExisting,layouts: [:]) }
        for _ in 0..<300 {
            if await f.probe.values().filter({ $0 == "render-hd" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await e.pause(batchID: f.batch.id)
        await f.probe.release(); try await request.value
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        let calls = await f.probe.values().filter { $0 == "render-hd" }
        XCTAssertEqual(calls.count,2)
        XCTAssertEqual(result.activeTasks.filter { $0[.hd].state == .completed }.count,2)
        XCTAssertEqual(result.activeTasks.filter { $0[.hd].state == .pending }.count,2)
    }

    func testManualMaskRefreshUpdatesTheGeometryRestartCheckpoint() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = nativeServices(f)
        services.selectSubject = { _ in throw WorkflowBridgeError.invalidImage("no subject") }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        let url = try await e.beginManualEditing(batchID: f.batch.id,taskID: id)
        let manual = ExecutorFixture.snapshot(id,url,"manual-mask",roles: true)
        try JSONEncoder().encode(manual).write(to: url)
        try await e.refreshManualPSD(batchID: f.batch.id,taskID: id)
        try await e.endManualEditing(batchID: f.batch.id)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?.checkpoints?[.matte]?.contentVersion,"manual-mask")
        XCTAssertEqual(result.task(id: id)?[.geometry].state,.pending)
        XCTAssertTrue(result.isPaused)
    }

    func testExportUsesReextractedRolesAndRejectsCacheReplacementDuringRender() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let paths = PerImageRolePath(f.batch.outputDirectory.appendingPathComponent("old.png"))
        var services = nativeServices(f)
        services.extract = { snapshot in
            var roles = ExecutorFixture.roles(snapshot); roles.isFinalized = snapshot.finalRoles != nil
            roles.cutoutPNG = await paths.url; return roles
        }
        services.render = { kind,roles,_,_,_,url in
            let expected = await paths.url; XCTAssertEqual(roles?.cutoutPNG,expected)
            try await f.probe.render(kind,to: url)
            await paths.replaceAfterRender()
        }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        try await e.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        await paths.set(f.batch.outputDirectory.appendingPathComponent("fresh.png"))
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .skipExisting,layouts: [:])
        let first = try await e.batch(batchID: f.batch.id).task(id: id)!.artifacts.first!
        XCTAssertEqual(first.state,.completed)
        let bytes = try Data(contentsOf: first.url)
        await paths.replaceNextRender()
        try await e.requestExports(batchID: f.batch.id,taskIDs: [id],kinds: [.png4k],policy: .overwrite,layouts: [:])
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: id)?[.png4k].state,.failed)
        XCTAssertEqual(try Data(contentsOf: first.url),bytes)
    }

    func testManualOpenCannotRaceWithCheckpointReplacement() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let entered = expectation(description: "restoring checkpoint"), gate = PerImagePauseGate(entered)
        var services = nativeServices(f)
        services.restoreCheckpoint = { snapshot,destination in
            await gate.hold()
            var copy = snapshot; copy.workingURL = destination
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),withIntermediateDirectories: true)
            try JSONEncoder().encode(copy).write(to: destination)
            return copy
        }
        let e = try await registered(f,services: services), id = f.batch.specimens[0].front.id
        let redo = Task { try await e.reprocessTask(batchID: f.batch.id,taskID: id,from: .geometry,expectedVersion: "geometry") }
        await fulfillment(of: [entered],timeout: 3)
        do { _ = try await e.beginManualEditing(batchID: f.batch.id,taskID: id); XCTFail("must wait for the replacement transaction") } catch {}
        await gate.release(); try await redo.value
        let result = try await e.batch(batchID: f.batch.id)
        let opened = try await e.beginManualEditing(batchID: f.batch.id,taskID: id)
        XCTAssertEqual(opened,result.task(id: id)?.snapshot?.workingURL)
        try await e.endManualEditing(batchID: f.batch.id)
    }

    func testUnavailablePhotoshopPausesQueueBeforeOtherImages() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var services = nativeServices(f)
        services.stack = { _,_ in throw FocusStackError.photoshopNotFound }
        let e = try await registered(f,services: services)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(result.isPaused)
        XCTAssertEqual(result.specimens[0].front[.stack].state,.failed)
        XCTAssertEqual(result.specimens[0].back[.stack].state,.pending)
    }

}

private actor PerImagePauseGate {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<Void,Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func hold() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PerImageRolePath {
    var url: URL
    var replace = false
    init(_ url: URL) { self.url = url }
    func set(_ url: URL) { self.url = url }
    func replaceNextRender() { replace = true }
    func replaceAfterRender() { if replace { url = url.appendingPathExtension("replaced"); replace = false } }
}
