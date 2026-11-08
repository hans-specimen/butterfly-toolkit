import XCTest
@testable import Butterfly_Toolkit

final class WorkflowStateTests: XCTestCase {
    // A per-side success must never bypass either batch barrier or either mandatory review.
    func testFourCheckpointCombinations() throws {
        for (stackCheck, matteCheck) in [(true, true), (true, false), (false, true), (false, false)] {
            var batch = fixture(stackCheck: stackCheck, matteCheck: matteCheck)
            let ids = batch.sideTasks.map(\.id)
            try complete(&batch, taskID: ids[0], stage: .stack)
            XCTAssertEqual(batch.currentStage, .stack)
            XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch,
                event: .continueBatch(stage: .stack, expectedRevision: batch.revision)))
            try complete(&batch, taskID: ids[1], stage: .stack)
            XCTAssertEqual(batch.currentStage, .stack)
            for id in ids.dropFirst(2) { try complete(&batch, taskID: id, stage: .stack) }
            XCTAssertEqual(batch.currentStage, stackCheck ? .stack : .matte)
            if stackCheck { try continueBatch(&batch, stage: .stack) }
            try completeAll(&batch, stage: .matte)
            XCTAssertEqual(batch.currentStage, matteCheck ? .matte : .geometry)
            if matteCheck { try continueBatch(&batch, stage: .matte) }
            try completeAll(&batch, stage: .geometry)
            XCTAssertEqual(batch.currentStage, .geometry)
            XCTAssertTrue(batch.sideTasks.allSatisfy { $0[.geometry].state == .waitingReview })
            XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch,
                event: .continueBatch(stage: .geometry, expectedRevision: batch.revision)))
            let first = batch.specimens[0]
            try confirm(&batch, specimens: [first.id], stage: .geometry)
            XCTAssertEqual(batch.currentStage, .geometry)
            XCTAssertEqual(batch.specimens[1].front[.geometry].state, .waitingReview)
            for task in [first.front, first.back] {
                try complete(&batch, taskID: task.id, stage: .hd)
                try complete(&batch, taskID: task.id, stage: .png4k)
            }
            XCTAssertEqual(batch.task(id: first.front.id)?[.png4k].state, .waitingReview)
            XCTAssertThrowsError(try start(batch, taskID: first.front.id, stage: .derivatives))
            try confirm(&batch, specimens: [first.id], stage: .png4k)
            XCTAssertEqual(batch.specimens[1].front[.png4k].state, .pending)
            XCTAssertEqual(batch.task(id: first.front.id)?[.png4k].state, .completed)
            XCTAssertFalse(batch.allSucceeded)
        }
    }

    func testInvalidationDuringEarlyReviewReturnsWholeBatchToReadyCheckpoint() throws {
        for stage in [WorkflowStage.stack, .matte] {
            var batch = fixture(stackCheck: stage == .stack, matteCheck: true)
            try completeAll(&batch, stage: .stack)
            if stage == .matte { try completeAll(&batch, stage: .matte) }
            XCTAssertTrue(batch.sideTasks.allSatisfy { $0[stage].state == .waitingReview })
            let task = batch.specimens[0].front
            batch = try WorkflowStateMachine.reduce(batch: batch, event: .sourceChanged(taskID: task.id,
                sources: sources(start: 41), expectedVersion: task.sourceRevision))
            if stage == .matte { try complete(&batch, taskID: task.id, stage: .stack) }
            XCTAssertThrowsError(try continueBatch(&batch, stage: stage), "Pending side must block the checkpoint")
            batch = try start(batch, taskID: task.id, stage: stage)
            XCTAssertThrowsError(try continueBatch(&batch, stage: stage), "Running side must block the checkpoint")
            batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageFailed(taskID: task.id, stage: stage,
                expectedVersion: batch.task(id: task.id)![stage].revision, reason: "Retry needed"))
            XCTAssertThrowsError(try continueBatch(&batch, stage: stage), "Failed side must block the checkpoint")
            try complete(&batch, taskID: task.id, stage: stage)
            let allWaiting = batch.sideTasks.allSatisfy { $0[stage].state == .waitingReview }
            XCTAssertTrue(allWaiting, "Reprocessed side must rejoin the \(stage.rawValue) batch review")
            guard allWaiting else { continue } // Exercise both checkpoint cases even when this assertion fails.
            try continueBatch(&batch, stage: stage)
            XCTAssertTrue(batch.sideTasks.allSatisfy { $0[stage].state == .completed })
            let next: WorkflowStage = stage == .stack ? .matte : .geometry
            XCTAssertEqual(batch.currentStage, next)
            batch = try start(batch, taskID: task.id, stage: next)
            XCTAssertEqual(batch.task(id: task.id)?[next].state, .running)
        }
    }

    // Dropping a failed task from the readiness predicate would silently advance the batch.
    func testFailureRequiresRetryOrExplicitExclusion() throws {
        var batch = fixture(stackCheck: false, matteCheck: false)
        let failedID = batch.specimens[0].front.id
        batch = try start(batch, taskID: failedID, stage: .stack)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageFailed(taskID: failedID,
            stage: .stack, expectedVersion: batch.task(id: failedID)![.stack].revision, reason: "Photoshop failed"))
        for task in batch.sideTasks where task.id != failedID { try complete(&batch, taskID: task.id, stage: .stack) }
        XCTAssertEqual(batch.currentStage, .stack)
        XCTAssertEqual(batch.task(id: failedID)?[.stack].error, "Photoshop failed")
        XCTAssertThrowsError(try continueBatch(&batch, stage: .stack))
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
        XCTAssertEqual(WorkflowSide.front.fileSuffix, "F")
        XCTAssertEqual(WorkflowSide.back.fileSuffix, "U")
    }

    // Output revisions, selected ownership and both sides are checked before any confirmation mutates state.
    func testStaleConfirmationRejected() throws {
        var batch = fixture(stackCheck: false, matteCheck: false)
        try completeAll(&batch, stage: .stack)
        try completeAll(&batch, stage: .matte)
        try completeAll(&batch, stage: .geometry)
        let specimen = batch.specimens[0]
        let versions = Dictionary(uniqueKeysWithValues: [specimen.front, specimen.back].map { ($0.id, batch.task(id: $0.id)![.geometry].outputVersion!) })
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .confirmSelected(
            specimenIDs: [specimen.id], stage: .geometry, outputVersions: [specimen.front.id: versions[specimen.front.id]!], expectedRevision: batch.revision)))
        let oldRevision = batch.revision
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .sourceChanged(taskID: specimen.front.id,
            sources: sources(start: 21), expectedVersion: specimen.front.sourceRevision))
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .confirmSelected(
            specimenIDs: [specimen.id], stage: .geometry, outputVersions: versions, expectedRevision: oldRevision)))
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .confirmSelected(
            specimenIDs: [specimen.id], stage: .geometry, outputVersions: versions, expectedRevision: batch.revision)))
        XCTAssertEqual(batch.specimens[1].front[.geometry].state, .waitingReview)
    }

    // Changing the square composition must not erase verified matte or HD results.
    func test4KChangeKeepsHDAndMatte() throws {
        var batch = try finishedFixture()
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

    func testDerivativePresetInvalidatesOnlyThatAsset() throws {
        var batch = try finishedFixture()
        let hd = batch.specimens[0].front[.hd]
        let png = batch.specimens[0].front[.png4k]
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .presetChanged(scope: .derivative(.white1k),
            preset: WorkflowPreset(version: 2, fingerprint: "white-v2"), expectedRevision: batch.revision))
        let task = batch.specimens[0].front
        XCTAssertEqual(task[.hd], hd)
        XCTAssertEqual(task[.png4k], png)
        XCTAssertEqual(task.artifacts.first { $0.kind == .white1k }?.state, .pending)
        XCTAssertEqual(task.artifacts.first { $0.kind == .xianyu }?.state, .completed)
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

    func testSourceChangeInvalidatesOnlyTheChangedSide() throws {
        var batch = try finishedFixture()
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
        var batch = fixture(stackCheck: false, matteCheck: false)
        let id = batch.specimens[0].front.id
        batch.specimens[0].front.snapshot = snapshot(taskID: id, roles: nil)
        try completeAll(&batch, stage: .stack)
        batch = try start(batch, taskID: id, stage: .matte)
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: id,
            stage: .matte, expectedVersion: batch.task(id: id)![.matte].revision, outputVersion: "matte")))
    }

    func testMaskOnlyPSDChangeRequiresGeometryAndHDValidationWithoutRerunningAI() throws {
        var batch = try finishedFixture()
        batch.specimens[0].front.geometryRequest.angleStrategy = .manual(degrees: 3.5)
        batch.specimens[0].front.geometrySolution = GeometrySolution(sourceVersion: "psd-v1", angleDegrees: 3.5, rotationPivot: CGPoint(x: 50, y: 50),
            leftWingTip: nil, rightWingTip: nil, subjectBounds: CGRect(x: 100, y: 100, width: 2400, height: 1800),
            sourceCropRect: CGRect(x: 0, y: 0, width: 3000, height: 2250), outputSize: CGSize(width: 3000, height: 2250),
            actualMargins: WorkflowMargins(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1), isApplicable: true, reason: nil)
        let before = batch.specimens[0].front
        let other = batch.specimens[0].back
        var saved = before.snapshot!
        saved.contentVersion = "psd-mask-v2"
        saved.snapshotURL = URL(fileURLWithPath: "/output/psd-mask-v2.psd")
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .savedPSDChanged(taskID: before.id,
            snapshot: saved, change: .maskOnly, expectedSourceVersion: before.sourceRevision,
            expectedSnapshotVersion: before.snapshot?.contentVersion))
        let after = batch.specimens[0].front
        XCTAssertEqual(after[.stack], before[.stack])
        XCTAssertEqual(after[.matte], before[.matte])
        XCTAssertEqual(after[.geometry].state, .pending)
        XCTAssertNil(after[.geometry].confirmedVersion)
        XCTAssertEqual(after.geometryRequest, before.geometryRequest)
        XCTAssertEqual(after.geometrySolution, before.geometrySolution)
        XCTAssertTrue(after.geometryRevalidationRequired)
        XCTAssertEqual(after.lastPSDChange, .maskOnly)
        let persisted = try JSONDecoder().decode(WorkflowBatch.self, from: JSONEncoder().encode(batch))
        XCTAssertTrue(persisted.specimens[0].front.geometryRevalidationRequired)
        XCTAssertEqual(persisted.specimens[0].front.lastPSDChange, .maskOnly)
        XCTAssertEqual(after[.hd].state, .pending)
        XCTAssertEqual(after[.png4k].state, .pending)
        let retainedHD = after.artifacts.first { $0.kind == .hd }
        XCTAssertEqual(retainedHD?.fileFingerprint, "file")
        XCTAssertEqual(retainedHD?.url, before.artifacts.first { $0.kind == .hd }?.url)
        XCTAssertEqual(retainedHD?.state, .pending)
        XCTAssertEqual(batch.specimens[0].back, other)
        XCTAssertEqual(batch.currentStage, .geometry)
        XCTAssertThrowsError(try start(batch, taskID: before.id, stage: .hd))
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: batch, event: .savedPSDChanged(taskID: before.id,
            snapshot: saved, change: .maskOnly, expectedSourceVersion: before.sourceRevision,
            expectedSnapshotVersion: before.snapshot?.contentVersion)))
    }

    func testSavedStackAndGeometryChangesInvalidateTheirOwnDownstreamOnly() throws {
        for change in [WorkflowPSDChange.stackContent, .geometry] {
            var batch = try finishedFixture()
            let before = batch.specimens[0].front
            let other = batch.specimens[1]
            var saved = before.snapshot!
            saved.contentVersion = "psd-v2"
            saved.snapshotURL = URL(fileURLWithPath: "/output/psd-v2.psd")
            batch = try WorkflowStateMachine.reduce(batch: batch, event: .savedPSDChanged(taskID: before.id,
                snapshot: saved, change: change, expectedSourceVersion: before.sourceRevision,
                expectedSnapshotVersion: before.snapshot?.contentVersion))
            let after = batch.specimens[0].front
            XCTAssertEqual(after[.stack].state, .completed)
            if change == .stackContent {
                XCTAssertEqual(after[.stack].outputVersion, "psd-v2")
                XCTAssertEqual(after[.matte].state, .pending)
                XCTAssertNil(after.matteArtifact)
                XCTAssertNil(after.stackPNG)
                XCTAssertEqual(batch.currentStage, .matte)
            } else {
                XCTAssertEqual(after[.stack], before[.stack])
                XCTAssertEqual(after[.matte], before[.matte])
                XCTAssertEqual(batch.currentStage, .geometry)
            }
            XCTAssertNil(after.roleImages)
            XCTAssertNil(after.geometrySolution)
            XCTAssertTrue([WorkflowStage.geometry, .hd, .png4k, .derivatives].allSatisfy { after[$0].state == .pending })
            XCTAssertEqual(batch.specimens[1], other)
        }
    }

    func testOnlyFullySuccessfulBatchIsAllSucceededEvenWhenExcludedQueueIsEmpty() throws {
        var batch = try finishedFixture()
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
        var batch = fixture(stackCheck: false, matteCheck: false)
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

    func testJSONRoundTripKeepsUncroppedCoordinateSpaceAndVersions() throws {
        var batch = try finishedFixture()
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

    func testMattePreparationStoredRemainsPending() throws {
        var batch = fixture(stackCheck: false,matteCheck: true)
        try completeAll(&batch,stage: .stack)
        let id = batch.specimens[0].front.id
        batch = try start(batch,taskID: id,stage: .matte)
        let snapshot = ExecutorFixture.snapshot(id,URL(fileURLWithPath: "/output/task.psd"),"stack",roles: false)
        batch.specimens[0].front.snapshot = snapshot
        let input = StackPNG(snapshotVersion: "stack",pngURL: URL(fileURLWithPath: "/output/input.png"),fingerprint: "input",pixelSize: snapshot.pixelSize,orientation: 1,colorProfile: "sRGB")
        batch.specimens[0].front.stackPNG = input
        let before = batch.specimens[0].front, event = WorkflowEvent.mattePreparationStored(taskID: id,expectedVersion: before[.matte].revision)
        let after = try WorkflowStateMachine.reduce(batch: batch,event: event)
        XCTAssertEqual(after.specimens[0].front[.matte].state,.pending)
        XCTAssertEqual(after.specimens[0].front[.matte].revision,before[.matte].revision+1)
        XCTAssertNil(after.specimens[0].front[.matte].outputVersion)
        XCTAssertNil(after.specimens[0].front[.matte].confirmedVersion)
        XCTAssertEqual(after.specimens[0].front.stackPNG,input)
        XCTAssertEqual(after.specimens[0].back,batch.specimens[0].back)
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: after,event: event))
        var invalid = batch; invalid.isPaused = true
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: invalid,event: event))
        invalid = batch; invalid.specimens[0].front.stackPNG = nil
        XCTAssertThrowsError(try WorkflowStateMachine.reduce(batch: invalid,event: event))
    }

    private func fixture(stackCheck: Bool = true, matteCheck: Bool = true) -> WorkflowBatch {
        WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/input"), outputDirectory: URL(fileURLWithPath: "/output"),
            checkAfterStack: stackCheck, checkAfterMatte: matteCheck, specimens: [
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
            if batch.specimens[index].front.id == taskID { batch.specimens[index].front.snapshot = snapshot(taskID: taskID, roles: .fixture) }
            else { batch.specimens[index].back.snapshot = snapshot(taskID: taskID, roles: .fixture) }
        }
        batch = try start(batch, taskID: taskID, stage: stage)
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .stageCompleted(taskID: taskID, stage: stage,
            expectedVersion: batch.task(id: taskID)![stage].revision, outputVersion: "\(stage.rawValue)-\(UUID())"))
    }

    private func completeAll(_ batch: inout WorkflowBatch, stage: WorkflowStage) throws {
        for id in batch.sideTasks.map(\.id) { try complete(&batch, taskID: id, stage: stage) }
    }

    private func continueBatch(_ batch: inout WorkflowBatch, stage: WorkflowStage) throws {
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .continueBatch(stage: stage, expectedRevision: batch.revision))
    }

    private func confirm(_ batch: inout WorkflowBatch, specimens: Set<UUID>, stage: WorkflowStage) throws {
        let tasks = batch.specimens.filter { specimens.contains($0.id) }.flatMap { [$0.front, $0.back] }
        let versions = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0[stage].outputVersion!) })
        batch = try WorkflowStateMachine.reduce(batch: batch, event: .confirmSelected(specimenIDs: specimens,
            stage: stage, outputVersions: versions, expectedRevision: batch.revision))
    }

    private func finishedFixture() throws -> WorkflowBatch {
        var batch = fixture(stackCheck: false, matteCheck: false)
        for stage in WorkflowStage.allCases {
            try completeAll(&batch, stage: stage)
            if stage == .geometry || stage == .png4k { try confirm(&batch, specimens: Set(batch.specimens.map(\.id)), stage: stage) }
        }
        for index in batch.specimens.indices {
            for side in WorkflowSide.allCases {
                var task = side == .front ? batch.specimens[index].front : batch.specimens[index].back
                task.artifacts = WorkflowAssetKind.allCases.map { WorkflowArtifact(ownerTaskID: task.id, kind: $0,
                    url: URL(fileURLWithPath: "/output/\(task.id)-\($0.rawValue).png"), sourceFingerprint: "source", presetFingerprint: "preset", fileFingerprint: "file", state: .completed) }
                if side == .front { batch.specimens[index].front = task } else { batch.specimens[index].back = task }
            }
        }
        return batch
    }

    private func snapshot(taskID: UUID, roles: PSDRoleIdentifiers?) -> PSDSnapshot {
        PSDSnapshot(taskID: taskID, workingURL: URL(fileURLWithPath: "/output/work.psd"), snapshotURL: URL(fileURLWithPath: "/output/snapshot.psd"),
            contentVersion: "psd-v1", pixelSize: CGSize(width: 8000, height: 6000), roles: roles, structureSummary: "stack and roles")
    }
}

private extension PSDRoleIdentifiers {
    static var fixture: Self { Self(originalStackGroup: "1", adjustmentGroup: "2", baseLayer: "3", cutoutLayer: "4", mask: "5") }
}

final class WorkflowBatchStoreTests: XCTestCase {
    func testCorruptManifestRecoversPreviousValidSaveAndDoesNotOverwriteBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("batch.json")
        let store = WorkflowBatchStore()
        let first = WorkflowBatch(sourceDirectory: directory, outputDirectory: directory, specimens: [])
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
        var batch = WorkflowBatch(sourceDirectory: directory, outputDirectory: directory, checkAfterStack: false, checkAfterMatte: false,
            specimens: [WorkflowSpecimen(baseName: "one", front: WorkflowSideTask(side: .front, sources: sources), back: WorkflowSideTask(side: .back, sources: sources))])
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
        var batch = WorkflowBatch(sourceDirectory: directory, outputDirectory: directory,
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
