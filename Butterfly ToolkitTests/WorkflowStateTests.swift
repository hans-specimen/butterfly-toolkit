import XCTest
@testable import Butterfly_Toolkit

final class WorkflowStateTests: XCTestCase {

    // Dropping a failed task from the readiness predicate would silently advance the batch.
    func testFailureRequiresRetryOrExplicitExclusion() throws {
        var batch = fixture()
        let failedID = batch.specimens[0].front.id
        batch = try start(batch, taskID: failedID, stage: .stack)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageFailed(taskID: failedID,
            stage: .stack, expectedVersion: batch.task(id: failedID)![.stack].revision, reason: "Photoshop failed"))
        for task in batch.sideTasks where task.id != failedID { try complete(&batch, taskID: task.id, stage: .stack) }
        XCTAssertEqual(batch.currentStage, .stack)
        XCTAssertEqual(batch.task(id: failedID)?[.stack].error, "Photoshop failed")
        var retried = batch
        try complete(&retried, taskID: failedID, stage: .stack)
        XCTAssertEqual(retried.currentStage, .matte)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .excludeSpecimens(
            ids: [batch.specimens[0].id], reason: "Retake later", expectedRevision: batch.revision))
        XCTAssertEqual(batch.currentStage, .matte)
        XCTAssertTrue([batch.specimens[0].front, batch.specimens[0].back].allSatisfy { $0[.stack].state == .excluded })
        XCTAssertEqual(batch.specimens[0].front[.stack].error, "Photoshop failed")
        XCTAssertFalse(batch.allSucceeded)
    }

    // Exclusion must never rebuild positional groups or shift their names and source triplets.
    func testGroupingDoesNotShiftAfterExclusion() throws {
        let batch = fixture()
        let second = batch.specimens[1]
        let changed = try WorkflowStateMachine.reduce(batch: batch, event: .excludeSpecimens(
            ids: [batch.specimens[0].id], reason: "Test shot", expectedRevision: batch.revision))
        XCTAssertEqual(changed.specimens.count, 2)
        XCTAssertEqual(changed.specimens[1], second)
        XCTAssertEqual(changed.specimens[1].front.sources.files.map(\.url.lastPathComponent), ["7.jpg", "8.jpg", "9.jpg"])
        XCTAssertEqual(changed.specimens[1].back.sources.files.map(\.url.lastPathComponent), ["10.jpg", "11.jpg", "12.jpg"])
        XCTAssertEqual(WorkflowSide.front.fileSuffix, "D")
        XCTAssertEqual(WorkflowSide.back.fileSuffix, "V")
    }



    // Changing the square composition must not erase verified matte or HD results.
    func test4KChangeKeepsHDAndMatte() async throws {
        var batch = try await finishedFixture()
        let before = batch.specimens[0].front
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .presetChanged(scope: .png4k,
            preset: WorkflowPreset(version: 2, fingerprint: "4k-margin-300"), expectedRevision: batch.revision))
        let after = batch.specimens[0].front
        XCTAssertEqual(after[.matte], before[.matte])
        XCTAssertEqual(after[.geometry], before[.geometry])
        XCTAssertEqual(after[.hd], before[.hd])
        XCTAssertEqual(after[.png4k].state, .pending)
        XCTAssertNil(after[.png4k].confirmedVersion)
        XCTAssertEqual(after[.derivatives].state, .pending)
        XCTAssertEqual(after.artifacts.first { $0.kind == .hd }?.state, .completed)
        XCTAssertEqual(after.artifacts.first { $0.kind == .png4k }?.state, .pending)
        XCTAssertEqual(batch.currentStage, .png4k)
    }

    func testCancelledAttemptCannotCompleteAfterRetry() throws {
        var batch = fixture()
        let id = batch.specimens[0].front.id
        batch = try start(batch, taskID: id, stage: .stack)
        let cancelledVersion = batch.task(id: id)![.stack].revision
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .cancelRunning(expectedRevision: batch.revision))
        XCTAssertTrue(batch.isPaused)
        XCTAssertThrowsError(try start(batch, taskID: id, stage: .stack))
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .resume(expectedRevision: batch.revision))
        batch = try start(batch, taskID: id, stage: .stack)
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: id,
            stage: .stack, expectedVersion: cancelledVersion, outputVersion: "late")))
        XCTAssertEqual(batch.task(id: id)?[.stack].state, .running)
    }

    func testSourceChangeInvalidatesOnlyTheChangedSide() async throws {
        var batch = try await finishedFixture()
        let otherSide = batch.specimens[0].back
        let otherSpecimen = batch.specimens[1]
        let task = batch.specimens[0].front
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .sourceChanged(taskID: task.id,
            sources: sources(start: 31), expectedVersion: task.sourceRevision))
        XCTAssertEqual(batch.specimens[0].back, otherSide)
        XCTAssertEqual(batch.specimens[1], otherSpecimen)
        XCTAssertTrue(batch.specimens[0].front.records.values.allSatisfy { $0.state == .pending && $0.outputVersion == nil })
        XCTAssertTrue(batch.specimens[0].front.artifacts.allSatisfy { $0.state == .pending })
    }

    func testSnapshotRolesRequiredOnlyFromMatteCompletion() throws {
        var batch = fixture()
        let id = batch.specimens[0].front.id
        batch.specimens[0].front.snapshot = snapshot(taskID: id, roles: nil)
        try completeAll(&batch, stage: .stack)
        batch = try start(batch, taskID: id, stage: .matte)
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: id,
            stage: .matte, expectedVersion: batch.task(id: id)![.matte].revision, outputVersion: "matte")))
    }

    func testOnlyFullySuccessfulBatchIsAllSucceededEvenWhenExcludedQueueIsEmpty() async throws {
        var batch = try await finishedFixture()
        XCTAssertTrue(batch.allSucceeded)
        XCTAssertNil(batch.currentStage)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .excludeSpecimens(
            ids: Set(batch.specimens.map(\.id)), reason: "Do not deliver these specimens", expectedRevision: batch.revision))
        XCTAssertNil(batch.currentStage)
        XCTAssertFalse(batch.allSucceeded)
        XCTAssertEqual(batch.specimens.count, 2)
        XCTAssertTrue(batch.sideTasks.allSatisfy { $0.records.values.allSatisfy { $0.state == .excluded } })
    }

    func testPauseAllowsCurrentOperationToFinishButBlocksStartingTheNextOne() throws {
        var batch = fixture()
        let id = batch.specimens[0].front.id
        batch = try start(batch, taskID: id, stage: .stack)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .pause(expectedRevision: batch.revision))
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: id, stage: .stack,
            expectedVersion: batch.specimens[0].front[.stack].revision, outputVersion: "saved-stack"))
        XCTAssertEqual(batch.specimens[0].front[.stack].state, .completed)
        let other = batch.specimens[0].back.id
        XCTAssertThrowsError(try start(batch, taskID: other, stage: .stack))
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .resume(expectedRevision: batch.revision))
        batch = try start(batch, taskID: other, stage: .stack)
        XCTAssertEqual(batch.specimens[0].back[.stack].state, .running)
    }

    func testInvalidManifestIdentityIsRejected() throws {
        var batch = fixture()
        batch.specimens[0].back.id = batch.specimens[0].front.id
        XCTAssertThrowsError(try batch.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(WorkflowBatch.self, from: JSONEncoder().encode(batch)).validate())
    }

    func testJSONRoundTripKeepsUncroppedCoordinateSpaceAndVersions() async throws {
        var batch = try await finishedFixture()
        let id = batch.specimens[0].front.id
        batch.specimens[0].front.roleImages = RoleImages(snapshotVersion: "psd-v1", basePNG: URL(fileURLWithPath: "/output/base.png"),
            cutoutPNG: URL(fileURLWithPath: "/output/cutout.png"), maskPNG: URL(fileURLWithPath: "/output/mask.png"),
            pixelSize: CGSize(width: 8000, height: 6000), coordinateOrigin: CGPoint(x: -100, y: -200),
            editableExtent: CGRect(x: -100, y: -200, width: 8000, height: 6000), cropViewport: CGRect(x: 0, y: 0, width: 5000, height: 4000))
        let decoded = try JSONDecoder().decode(WorkflowBatch.self, from: JSONEncoder().encode(batch))
        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(decoded.task(id: id)?.roleImages?.editableExtent.width, 8000)
        XCTAssertEqual(decoded.task(id: id)?.roleImages?.coordinateOrigin.x, -100)
    }

    private func fixture() -> WorkflowBatch {
        WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/input"), sourceDirectoryName: "input", outputDirectory: URL(fileURLWithPath: "/output"),
            specimens: [
                WorkflowSpecimen(baseName: "one", front: WorkflowSideTask(side: .front, sources: sources(start: 1)), back: WorkflowSideTask(side: .back, sources: sources(start: 4))),
                WorkflowSpecimen(baseName: "two", front: WorkflowSideTask(side: .front, sources: sources(start: 7)), back: WorkflowSideTask(side: .back, sources: sources(start: 10)))])
    }

    private func sources(start: Int) -> WorkflowSources {
        let files = (start..<(start + 3)).map { WorkflowSourceFile(url: URL(fileURLWithPath: "/input/\($0).jpg"), fingerprint: "source-\($0)") }
        return WorkflowSources(first: files[0], second: files[1], third: files[2])
    }

    private func start(_ batch: WorkflowBatch, taskID: UUID, stage: WorkflowStage) throws -> WorkflowBatch {
        try WorkflowStateMachine.reduce(batch: batch, event: .stageStarted(taskID: taskID, stage: stage,
            expectedVersion: batch.task(id: taskID)![stage].revision))
    }

    private func complete(_ batch: inout WorkflowBatch, taskID: UUID, stage: WorkflowStage) throws {
        if stage == .matte {
            let index = batch.specimens.firstIndex { $0.front.id == taskID || $0.back.id == taskID }!
            var saved = snapshot(taskID: taskID, roles: .fixture)
            let side = batch.specimens[index].front.id == taskID ? WorkflowSide.front : .back
            saved.workingURL = batch.generatedPSDDirectory.appendingPathComponent("\(batch.specimens[index].baseName)_\(side.fileSuffix).psd")
            if side == .front { batch.specimens[index].front.snapshot = saved }
            else { batch.specimens[index].back.snapshot = saved }
        }
        batch = try start(batch, taskID: taskID, stage: stage)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: taskID, stage: stage,
            expectedVersion: batch.task(id: taskID)![stage].revision, outputVersion: "\(stage.rawValue)-\(UUID())"))
    }

    private func completeAll(_ batch: inout WorkflowBatch, stage: WorkflowStage) throws {
        for id in batch.sideTasks.map(\.id) { try complete(&batch, taskID: id, stage: stage) }
    }

    private func finishedFixture() async throws -> WorkflowBatch {
        let f = try ExecutorFixture(count: 2)
        let executor = WorkflowExecutor(services: f.services, coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: f.batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: f.batch.id)
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)))
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        return try await executor.batch(batchID: f.batch.id)
    }

    private func snapshot(taskID: UUID, roles: PSDRoleIdentifiers?) -> PSDSnapshot {
        PSDSnapshot(taskID: taskID, workingURL: URL(fileURLWithPath: "/input/input_psd/one_D.psd"), snapshotURL: URL(fileURLWithPath: "/output/snapshot.psd"),
            contentVersion: "psd-v1", pixelSize: CGSize(width: 8000, height: 6000), roles: roles, structureSummary: "stack and roles")
    }
}

private extension PSDRoleIdentifiers {
    static var fixture: Self { Self(originalStackGroup: "1", adjustmentGroup: "2", baseLayer: "3", cutoutLayer: "4", mask: "5") }
}

final class WorkflowBatchStoreTests: XCTestCase {
    func testCurrentSchemaRequiresSavedAcceptanceForCompletedGeometry() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let executor = WorkflowExecutor(services: f.services, coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: f.batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: f.batch.id)
        let id = f.batch.specimens[0].front.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        var accepted = try await executor.batch(batchID: f.batch.id)
        XCTAssertNoThrow(try accepted.validate())
        accepted.specimens[0].front.acceptedFinalPSD = nil
        XCTAssertThrowsError(try accepted.validate())
    }

    func testSchemaTwoCannotLoadOrOverwriteEvenWithCurrentPrevious() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let store = WorkflowBatchStore()
        var old = f.batch; old.schemaVersion = 2
        let bytes = try JSONEncoder().encode(old)
        let previous = try JSONEncoder().encode(f.batch)
        try bytes.write(to: f.manifest)
        try previous.write(to: f.manifest.appendingPathExtension("previous"))
        do { _ = try await store.load(from: f.manifest); XCTFail("Old schema loaded") } catch {}
        do { try await store.save(f.batch, to: f.manifest); XCTFail("Old schema overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: f.manifest), bytes)
        XCTAssertEqual(try Data(contentsOf: f.manifest.appendingPathExtension("previous")), previous)
    }

    func testCorruptManifestRecoversPreviousValidSaveAndDoesNotOverwriteBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("batch.json")
        let store = WorkflowBatchStore()
        let first = WorkflowBatch(sourceDirectory: directory.resolvingSymlinksInPath(), sourceDirectoryName: directory.lastPathComponent, outputDirectory: directory, specimens: [])
        try await store.save(first, to: url)
        var second = first; second.revision = 2
        try await store.save(second, to: url)
        try Data("broken JSON".utf8).write(to: url)
        let recovered = try await WorkflowBatchStore().load(from: url)
        XCTAssertEqual(recovered, first)
        try await store.save(recovered, to: url)
        try Data("broken again".utf8).write(to: url)
        let recoveredAgain = try await WorkflowBatchStore().load(from: url)
        XCTAssertEqual(recoveredAgain, first)
    }

    func testCancelThenReopenPreservesCompletedWorkAndPendingRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WorkflowSourceFile(url: directory.appendingPathComponent("source.jpg"), fingerprint: "source")
        let sources = WorkflowSources(first: file, second: file, third: file)
        var batch = WorkflowBatch(sourceDirectory: directory.resolvingSymlinksInPath(), sourceDirectoryName: directory.lastPathComponent, outputDirectory: directory, specimens: [WorkflowSpecimen(baseName: "one", front: WorkflowSideTask(side: .front, sources: sources), back: WorkflowSideTask(side: .back, sources: sources))])
        let id = batch.specimens[0].front.id
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageStarted(taskID: id, stage: .stack, expectedVersion: 0))
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: id, stage: .stack, expectedVersion: 1, outputVersion: "stack-v1"))
        let otherID = batch.specimens[0].back.id
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageStarted(taskID: otherID, stage: .stack, expectedVersion: 0))
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .cancelRunning(expectedRevision: batch.revision))
        let url = directory.appendingPathComponent("batch.json")
        try await WorkflowBatchStore().save(batch, to: url)
        let loaded = try await WorkflowBatchStore().load(from: url)
        XCTAssertEqual(loaded.task(id: id)?[.stack].outputVersion, "stack-v1")
        XCTAssertEqual(loaded.task(id: otherID)?[.stack].state, .pending)
        XCTAssertTrue(loaded.isPaused)
    }

    func testCrashRecoveryCancelsOnlyRunningAttemptAndPausesBeforeReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WorkflowSourceFile(url: directory.appendingPathComponent("source.jpg"), fingerprint: "source")
        let sources = WorkflowSources(first: file, second: file, third: file)
        var batch = WorkflowBatch(sourceDirectory: directory.resolvingSymlinksInPath(), sourceDirectoryName: directory.lastPathComponent, outputDirectory: directory,
            specimens: [WorkflowSpecimen(baseName: "one", front: WorkflowSideTask(side: .front, sources: sources), back: WorkflowSideTask(side: .back, sources: sources))])
        let id = batch.specimens[0].front.id
        let untouched = batch.specimens[0].back
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageStarted(taskID: id, stage: .stack, expectedVersion: 0))
        let lateVersion = batch.specimens[0].front[.stack].revision
        let url = directory.appendingPathComponent("batch.json")
        try await WorkflowBatchStore().save(batch, to: url)
        let recovered = try await WorkflowBatchStore().load(from: url)
        XCTAssertTrue(recovered.isPaused)
        XCTAssertEqual(recovered.specimens[0].front[.stack].state, .pending)
        XCTAssertGreaterThan(recovered.specimens[0].front[.stack].revision, lateVersion)
        XCTAssertEqual(recovered.specimens[0].back, untouched)
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: recovered, event: .stageCompleted(taskID: id,
            stage: .stack, expectedVersion: lateVersion, outputVersion: "late")))
    }

    func testBothCorruptCopiesThrowRatherThanInventingFreshBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("batch.json")
        try Data("broken".utf8).write(to: url)
        try Data("broken".utf8).write(to: url.appendingPathExtension("previous"))
        do { _ = try await WorkflowBatchStore().load(from: url); XCTFail("Corruption must be reported") }
        catch { XCTAssertTrue(error is WorkflowStateError) }
    }
}
