// 验证人工定稿屏障、最终图层读取、保存版本隔离与双输出恢复。
import XCTest
import CryptoKit
@testable import Butterfly_Toolkit

final class WorkflowFinalizationTests: XCTestCase {

    func testLegacyPNGReceiptIsNotRecoveredAfterTopLayerRuleChange() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let executor = WorkflowExecutor(services: finalServices(f))
        try await executor.register(batch: batch,manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        try await executor.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        let id = batch.specimens[0].front.id
        try await executor.requestExports(batchID: batch.id,taskIDs: [id],kinds: [.png4k],policy: .overwrite,layouts: [:])
        var saved = try await executor.batch(batchID: batch.id)
        let index = try XCTUnwrap(saved.specimens[0].front.artifacts.firstIndex { $0.kind == .png4k })
        var legacy = saved.specimens[0].front.artifacts[index]
        // 旧配方仅含 PSD 哈希和空构图，不含实际输出层及选层规则。
        legacy.sourceFingerprint = SHA256.hash(data: Data("geometry\u{0}null".utf8)).map { String(format: "%02x",$0) }.joined()
        saved.specimens[0].front.artifacts[index] = legacy
        try JSONEncoder().encode(legacy).write(to: legacy.url.appendingPathExtension("test-receipt"))
        let reopened = WorkflowExecutor(services: finalServices(f))
        try await reopened.register(batch: saved,manifestURL: f.manifest)
        try await reopened.requestExports(batchID: saved.id,taskIDs: [id],kinds: [.png4k],policy: .skipExisting,layouts: [:])
        let result = try await reopened.batch(batchID: saved.id)
        XCTAssertEqual(result.task(id: id)?.exportNotes?[.png4k],"待更新，已跳过")
        XCTAssertEqual(result.task(id: id)?[.png4k].state,.pending)
    }

    func testAppliedGeometryMovesWingTipsIntoSavedCanvasCoordinates() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = f.services
        services.analyze = { roles,_ in
            var result = ExecutorFixture.solution(roles.snapshotVersion)
            result.angleDegrees = 90; result.rotationPivot = CGPoint(x: 50,y: 40)
            result.leftWingTip = CGPoint(x: 50,y: 30); result.rightWingTip = CGPoint(x: 50,y: 50)
            result.sourceCropRect.origin = CGPoint(x: -10,y: -20)
            return result
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch,manifestURL: f.manifest); try await executor.runPending(batchID: batch.id)
        let actual = try await executor.batch(batchID: batch.id)
        let fit = try XCTUnwrap(actual.activeTasks.first?.geometrySolution)
        XCTAssertEqual(fit.leftWingTip,CGPoint(x: 70,y: 60)); XCTAssertEqual(fit.rightWingTip,CGPoint(x: 50,y: 60))
        XCTAssertEqual(fit.angleDegrees,0)
    }
    func testAutomaticGeometryStopsForMandatorySavedReview() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch,manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        let result = try await e.batch(batchID: batch.id), calls = await f.probe.values()
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview && $0.snapshot?.contentVersion == "geometry" })
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,2)
        XCTAssertFalse(calls.contains("render-hd")); XCTAssertTrue(result.activeTasks.allSatisfy { $0.artifacts.isEmpty })
        XCTAssertEqual(result.exportDirectory(for: .hd),batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent+"_堆栈原图",isDirectory: true))
        XCTAssertEqual(result.exportDirectory(for: .png4k),batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent+"_4K_PNG",isDirectory: true))
        try await e.runPending(batchID: batch.id)
        let after = await f.probe.values(); XCTAssertEqual(after.filter { $0 == "apply-save" }.count,2)
    }

    func testManualRefreshReopenAndConfirmDoNotReprocessAndExportBothAssets() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        let id = batch.specimens[0].front.id
        let url = try await e.beginManualEditing(batchID: batch.id,taskID: id)
        let reopenedURL = try await e.beginManualEditing(batchID: batch.id,taskID: id)
        XCTAssertEqual(reopenedURL,url)
        try await e.refreshFinalPSD(batchID: batch.id,taskID: id)
        let refreshed = try await e.batch(batchID: batch.id)
        XCTAssertTrue(refreshed.isPaused)
        XCTAssertEqual(refreshed.task(id: id)?.snapshot?.finalRoles?.cutoutLayer,"final-c")
        try await e.endManualEditing(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        var result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .completed && $0[.png4k].state == .pending && $0.artifacts.isEmpty })
        try await e.requestExports(batchID: batch.id, taskIDs: Set(result.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        try await e.continueAutomatic(batchID: batch.id)
        result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertTrue(result.activeTasks.allSatisfy { Set($0.artifacts.filter { $0.state == .completed }.map(\.kind)) == [.hd,.png4k] })
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,2)
        let reopened = WorkflowExecutor(services: finalServices(f))
        _ = try await reopened.register(manifestURL: f.manifest)
        let restored = try await reopened.batch(batchID: batch.id)
        XCTAssertTrue(restored.allSucceeded)
    }

    func testExplicitSavedConfirmationDoesNotExtractRoles() async throws {
        let (f, executor, _) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let id = f.batch.specimens[0].front.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [id])
        let result = try await executor.batch(batchID: f.batch.id)
        let calls = await f.probe.values()
        XCTAssertEqual(result.task(id: id)?[.geometry].state, .completed)
        XCTAssertNotNil(result.task(id: id)?.pendingFinalPSD)
        XCTAssertFalse(calls.contains("prepare-final"))
    }

    @MainActor
    func testStoreConfirmsWithoutPreparationAndOnlyPreparesTheRequestedFace() async throws {
        let (f, executor, _) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let store = PhotoWorkflowStore(makeExecutor: { _ in executor })
        store.openBatch(f.manifest)
        try await waitForStore { !store.busy && store.currentTask?.id == front }

        let oldSnapshot = try await executor.batch(batchID: f.batch.id)
        store.confirmCurrent()
        try await waitForStore { !store.isUpdatingReview && store.currentTask?.pendingFinalPSD != nil }
        XCTAssertEqual(store.stage, .hd)
        XCTAssertEqual(store.exportTaskIDs(scope: "此图"), [front])
        await store.sync { _, _ in oldSnapshot }
        XCTAssertNotNil(store.currentTask?.pendingFinalPSD, "A delayed earlier manifest cannot undo the saved confirmation")
        store.face = .back
        store.confirmCurrent()
        try await waitForStore { !store.isUpdatingReview && store.currentTask?.pendingFinalPSD != nil }
        let before = await f.probe.values()
        XCTAssertFalse(before.contains("prepare-final"))

        store.stage = .png4k
        store.face = .front
        store.prepareSelected()
        XCTAssertTrue(store.canLoadCurrentExportPreview)
        store.loadCurrentExportPreview()
        try await waitForStore { !store.isUpdatingReview && store.batch?.task(id: front)?.pendingFinalPSD == nil }
        XCTAssertNotNil(store.batch?.task(id: back)?.pendingFinalPSD)
        XCTAssertTrue(store.hasRequestedExportPreview(try XCTUnwrap(store.currentTask)))
        let after = await f.probe.values()
        XCTAssertEqual(after.filter { $0 == "prepare-final" }.count, 1)
    }

    @MainActor
    func testStoreTracksEachOpenedFaceAndResumesQueuedExportAfterTrackingEnds() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let value = try await executor.batch(batchID: f.batch.id)
        let frontURL = try XCTUnwrap(value.task(id: front)?.snapshot?.workingURL)
        let backURL = try XCTUnwrap(value.task(id: back)?.snapshot?.workingURL)
        var failBackOpen = true
        let store = PhotoWorkflowStore(makeExecutor: { _ in executor }, openPhotoshopDocument: { url in
            if url == backURL && failBackOpen { throw WorkflowBridgeError.photoshop("injected open failure") }
            let id = url == frontURL ? 1 : 2
            var documents = try await photoshop.list()
            documents.append(WorkflowOpenPhotoshopDocument(url: url, documentID: id, saved: true))
            await photoshop.setDocuments(documents)
        })
        store.openBatch(f.manifest)
        try await waitForStore { !store.busy && store.currentTask?.id == front }
        XCTAssertTrue(store.selectedReviewTaskIDs.isEmpty)
        store.selectedTaskIDs = [front, back]
        store.openSelectedPSDs()
        try await waitForStore { !store.isUpdatingReview && store.trackedReviewCount == 2 }
        XCTAssertNotNil(store.photoshopOpenErrors[back])
        XCTAssertFalse(store.canSwitchBatch)
        store.closeBatch()
        XCTAssertEqual(store.batch?.id, f.batch.id)

        let session = try XCTUnwrap(store.batch?.manualReviewSessionID)
        let observation = Task { await store.observeManualEdits(sessionID: session) }
        defer { observation.cancel() }
        try await waitForStore { store.batch?.task(id: front)?.manualEdit?.observedDocumentID == 1 }
        store.face = .back
        XCTAssertEqual(store.stage, .hd)
        XCTAssertTrue(store.canOpenPSD)
        XCTAssertTrue(store.canStopTrackingCurrentPSD)

        failBackOpen = false
        store.openPSD()
        try await waitForStore { store.batch?.task(id: back)?.manualEdit?.observedDocumentID == 2 }
        XCTAssertNil(store.photoshopOpenErrors[back])
        let version = try saveReviewPSD(frontURL, marker: "front saved")
        await photoshop.setDocuments([openDocument(backURL, 2)])
        try await waitForStore { store.batch?.task(id: front)?[.geometry].confirmedVersion == version }
        store.face = .front
        XCTAssertEqual(store.stage, .hd)
        store.stage = .png4k
        store.exportPNGSelected = false
        store.exportImages(scope: "此图")
        try await waitForStore { !store.isUpdatingReview && store.hasQueuedExports }
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.batch?.task(id: front)?.requestedExports?[.hd]?.snapshotVersion, version)

        await photoshop.setDocuments([])
        try await waitForStore { !store.busy && store.batch?.task(id: front)?[.hd].state == .completed }
        XCTAssertNil(store.batch?.manualReviewSessionID)
        XCTAssertEqual(store.batch?.task(id: back)?[.geometry].state, .waitingReview)
        XCTAssertTrue(store.canSwitchBatch)
    }

    @MainActor
    func testStoreCanStopTrackingAClosedFailedOpenWhileAnotherFaceIsStillEditing() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let value = try await executor.batch(batchID: f.batch.id)
        let frontURL = try XCTUnwrap(value.task(id: front)?.snapshot?.workingURL)
        let store = PhotoWorkflowStore(makeExecutor: { _ in executor }, openPhotoshopDocument: { url in
            guard url == frontURL else { throw WorkflowBridgeError.photoshop("injected open failure") }
            await photoshop.setDocuments([WorkflowOpenPhotoshopDocument(url: url, documentID: 1, saved: true)])
        })
        store.openBatch(f.manifest)
        try await waitForStore { !store.busy && store.currentTask?.id == front }
        store.selectedTaskIDs = [front, back]
        store.openSelectedPSDs()
        try await waitForStore { !store.isUpdatingReview && store.photoshopOpenErrors[back] != nil }
        store.face = .back
        store.stopTrackingCurrentPSD()
        try await waitForStore { !store.isUpdatingReview && store.trackedReviewCount == 1 }
        XCTAssertNotNil(store.batch?.task(id: front)?.manualEdit)
        XCTAssertNil(store.batch?.task(id: back)?.manualEdit)
        XCTAssertNil(store.photoshopOpenErrors[back])
        XCTAssertEqual(store.currentTask?[.geometry].state, .waitingReview)
        XCTAssertFalse(store.canSwitchBatch)
    }

    @MainActor
    func testStoreRetriesLastCloseManifestSaveBeforeReleasingAndRunningExports() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let value = try await executor.batch(batchID: f.batch.id)
        let frontURL = try XCTUnwrap(value.task(id: front)?.snapshot?.workingURL)
        let backURL = try XCTUnwrap(value.task(id: back)?.snapshot?.workingURL)
        let store = PhotoWorkflowStore(makeExecutor: { _ in executor }, openPhotoshopDocument: { _ in })
        store.openBatch(f.manifest)
        try await waitForStore { !store.busy && store.currentTask?.id == front }
        store.selectedTaskIDs = [front, back]
        store.openSelectedPSDs()
        try await waitForStore { !store.isUpdatingReview && store.trackedReviewCount == 2 }
        await photoshop.setDocuments([openDocument(frontURL, 1), openDocument(backURL, 2)])
        let session = try XCTUnwrap(store.batch?.manualReviewSessionID)
        let observation = Task { await store.observeManualEdits(sessionID: session) }
        defer { observation.cancel() }
        try await waitForStore { store.batch?.task(id: back)?.manualEdit?.observedDocumentID == 2 }
        _ = try saveReviewPSD(frontURL, marker: "front saved")
        await photoshop.setDocuments([openDocument(backURL, 2)])
        try await waitForStore { store.batch?.task(id: front)?[.geometry].state == .completed }
        store.exportPNGSelected = false
        store.exportImages(scope: "此图")
        try await waitForStore { !store.isUpdatingReview && store.hasQueuedExports }

        // Block only the recovery-copy write. Both the working PSD and the last good manifest remain readable.
        let previous = f.manifest.appendingPathExtension("previous")
        let backup = previous.appendingPathExtension("fixture")
        try FileManager.default.moveItem(at: previous, to: backup)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        await photoshop.setDocuments([])
        try await waitForStore { store.manualObservationError != nil && !store.busy }
        let diskBefore = try await WorkflowBatchStore().load(from: f.manifest)
        XCTAssertNotNil(diskBefore.manualReviewSessionID)
        XCTAssertFalse(store.canSwitchBatch)
        XCTAssertTrue(store.hasQueuedExports)

        try FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: backup, to: previous)
        try await waitForStore { !store.busy && store.batch?.task(id: front)?[.hd].state == .completed }
        XCTAssertNil(store.manualObservationError)
        XCTAssertTrue(store.canSwitchBatch)
        let diskAfter = try await WorkflowBatchStore().load(from: f.manifest)
        XCTAssertNil(diskAfter.manualReviewSessionID)
        XCTAssertEqual(diskAfter.task(id: front)?[.hd].state, .completed)
    }

    @MainActor
    func testStoreKeepsExportDirectoryUnchangedDuringReviewCommandAndLease() async throws {
        let (f, executor, _) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        let store = PhotoWorkflowStore(makeExecutor: { _ in executor }, openPhotoshopDocument: { _ in })
        store.openBatch(f.manifest)
        try await waitForStore { !store.busy && store.currentTask?.id == front }
        let original = try XCTUnwrap(store.exportDirectory(for: .hd))
        let replacement = f.batch.outputDirectory.appendingPathComponent("replacement-export")
        store.openPSD()
        XCTAssertTrue(store.isUpdatingReview)
        store.selectExportDirectory(replacement, kind: .hd)
        XCTAssertFalse(store.busy, "The change must not dispatch while the review command is active")
        try await waitForStore { !store.isUpdatingReview && !store.busy && store.trackedReviewCount == 1 }

        store.selectExportDirectory(replacement, kind: .hd)
        XCTAssertFalse(store.busy, "The change must not dispatch while Photoshop is reserved for editing")
        try await waitForStore { !store.busy }
        XCTAssertNil(store.error)
        XCTAssertEqual(store.exportDirectory(for: .hd), original)
    }

    @MainActor
    private func waitForStore(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the batch review store")
        throw WorkflowStateError.invalidTransition
    }

    func testBatchReviewAcceptsEachSavedCloseAndKeepsOtherOpenFaceLeased() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let initial = try await executor.batch(batchID: f.batch.id)
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front, back])
        let frontURL = try XCTUnwrap(urls.first), backURL = try XCTUnwrap(urls.last)
        XCTAssertEqual(urls.count, 2)
        await photoshop.setDocuments([openDocument(frontURL, 1, saved: false), openDocument(backURL, 2)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let frontVersion = try saveReviewPSD(frontURL, marker: "front-save-v1")
        // Photoshop can have discarded later, unsaved edits by the time the document disappears.
        await photoshop.setDocuments([openDocument(backURL, 2, saved: false)])
        try await executor.pollManualEdits(batchID: f.batch.id)

        let first = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(first.task(id: front)?[.geometry].confirmedVersion, frontVersion)
        let receipt = try XCTUnwrap(first.task(id: front)?.pendingFinalPSD)
        XCTAssertEqual(try AIFileValidation.hash(receipt.snapshotURL.path), frontVersion)
        XCTAssertEqual(first.task(id: front)?.snapshot, initial.task(id: front)?.snapshot)
        XCTAssertNil(first.task(id: front)?.roleImages)
        XCTAssertNotNil(first.manualReviewSessionID)
        XCTAssertEqual(first.task(id: back)?[.geometry].state, .waitingReview)
        let editing = try XCTUnwrap(first.task(id: back))
        do {
            try await executor.update(batchID: f.batch.id,
                event: .sourceChanged(taskID: back, sources: editing.sources, expectedVersion: editing.sourceRevision))
            XCTFail("Invalidated the source of a face that is still open")
        } catch { XCTAssertEqual(error as? WorkflowBridgeError, .manualReviewActive) }
        do {
            try await executor.prepareFinalPSD(batchID: f.batch.id, taskID: front)
            XCTFail("Prepared a final PSD while another face was still open")
        } catch { XCTAssertEqual(error as? WorkflowBridgeError, .manualReviewActive) }
        do {
            try await executor.prepareToCloseBatch(batchID: f.batch.id)
            XCTFail("Closed the batch while another face was still open")
        } catch { XCTAssertEqual(error as? WorkflowBridgeError, .manualReviewActive) }

        let backVersion = try saveReviewPSD(backURL, marker: "back-save")
        await photoshop.setDocuments([])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(result.manualReviewSessionID)
        XCTAssertEqual(result.task(id: back)?[.geometry].confirmedVersion, backVersion)
        XCTAssertEqual(result.task(id: front)?.pendingFinalPSD, receipt)
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("prepare-final"))
    }

    func testClosingAnUnchangedPSDLeavesReviewPending() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front])
        await photoshop.setDocuments([openDocument(try XCTUnwrap(urls.first), 1)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        await photoshop.setDocuments([])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(result.manualReviewSessionID)
        XCTAssertNil(result.task(id: front)?.acceptedFinalPSD)
        XCTAssertEqual(result.task(id: front)?[.geometry].state, .waitingReview)
    }

    func testFailedDocumentObservationCannotAcceptAnApparentlyClosedSave() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front])
        let url = try XCTUnwrap(urls.first)
        await photoshop.setDocuments([openDocument(url, 1)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let version = try saveReviewPSD(url, marker: "saved")
        await photoshop.setDocuments([])
        await photoshop.failNextObservation()
        do {
            try await executor.pollManualEdits(batchID: f.batch.id)
            XCTFail("A failed observation was treated as an empty document list")
        } catch { XCTAssertEqual(error as? WorkflowBridgeError, .photoshop("busy")) }
        let failed = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(failed.task(id: front)?.manualEdit?.observedDocumentID, 1)
        XCTAssertNil(failed.task(id: front)?.acceptedFinalPSD)
        try await executor.pollManualEdits(batchID: f.batch.id)
        let retried = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(retried.task(id: front)?[.geometry].confirmedVersion, version)
    }

    func testRestartRestoresObservedOpenEvidenceWithoutConfirmingAnUnobservedOpen() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front, back])
        let frontURL = try XCTUnwrap(urls.first), backURL = try XCTUnwrap(urls.last)
        await photoshop.setDocuments([openDocument(frontURL, 10)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let accepted = try saveReviewPSD(frontURL, marker: "closed")
        _ = try saveReviewPSD(backURL, marker: "changed but never observed open")
        await photoshop.setDocuments([])

        let reopened = WorkflowExecutor(services: batchReviewServices(f, photoshop), coordinator: PhotoshopExecutionCoordinator())
        _ = try await reopened.register(manifestURL: f.manifest)
        let restored = try await reopened.batch(batchID: f.batch.id)
        XCTAssertNotNil(restored.manualReviewSessionID)
        do {
            try await reopened.continueAutomatic(batchID: f.batch.id)
            XCTFail("Resumed automation before restored manual editing finished")
        } catch { XCTAssertEqual(error as? WorkflowStateError, .invalidTransition) }
        try await reopened.pollManualEdits(batchID: f.batch.id)
        let observed = try await reopened.batch(batchID: f.batch.id)
        XCTAssertEqual(observed.task(id: front)?[.geometry].confirmedVersion, accepted)
        XCTAssertNil(observed.task(id: back)?.acceptedFinalPSD)
        XCTAssertNotNil(observed.task(id: back)?.manualEdit)
        try await reopened.cancelClosedBatchEdits(batchID: f.batch.id, taskIDs: [back])
        let released = try await reopened.batch(batchID: f.batch.id)
        XCTAssertNil(released.manualReviewSessionID)
        XCTAssertEqual(released.task(id: back)?[.geometry].state, .waitingReview)
    }

    func testReopenDuringAcceptancePreservesLeaseAndDoesNotAcceptUntilClosed() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front])
        let url = try XCTUnwrap(urls.first)
        await photoshop.setDocuments([openDocument(url, 1)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let version = try saveReviewPSD(url, marker: "v1")
        await photoshop.setDocuments([openDocument(url, 2, saved: false)])
        await photoshop.setNextObservation { [] }
        try await executor.pollManualEdits(batchID: f.batch.id)
        let reopened = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(reopened.task(id: front)?.acceptedFinalPSD)
        XCTAssertNotNil(reopened.task(id: front)?.manualEditError)
        XCTAssertNotNil(reopened.manualReviewSessionID)

        await photoshop.setDocuments([])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let closed = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(closed.task(id: front)?[.geometry].confirmedVersion, version)
        XCTAssertNil(closed.manualReviewSessionID)
    }

    func testNewDiskVersionDuringAcceptanceCannotBeConfirmedByOlderObservation() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front])
        let url = try XCTUnwrap(urls.first)
        await photoshop.setDocuments([openDocument(url, 1)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        _ = try saveReviewPSD(url, marker: "v1")
        await photoshop.setDocuments([])
        await photoshop.setNextObservation { [] }
        await photoshop.setNextObservation {
            _ = try Self.saveReviewFile(url, marker: "changed during validation")
            return []
        }
        try await executor.pollManualEdits(batchID: f.batch.id)
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(result.task(id: front)?.acceptedFinalPSD)
        XCTAssertNotNil(result.task(id: front)?.manualEditError)
        XCTAssertNil(result.manualReviewSessionID)
    }

    func testAcceptedVersionMaterializesAtPreviewOrExportAndRejectsLaterSave() async throws {
        let (f, executor, _) = try await readyBatchReview(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id, third = f.batch.specimens[1].front.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [front, back, third])
        let accepted = try await executor.batch(batchID: f.batch.id)
        let pending = try XCTUnwrap(accepted.task(id: front)?.pendingFinalPSD)
        let stale = try XCTUnwrap(accepted.task(id: third)?.pendingFinalPSD)
        XCTAssertNotNil(accepted.task(id: back)?.pendingFinalPSD)
        let callsBeforePreparation = await f.probe.values()
        XCTAssertFalse(callsBeforePreparation.contains("prepare-final"))
        try await executor.prepareFinalPSD(batchID: f.batch.id, taskID: back)
        let preview = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(preview.task(id: back)?.pendingFinalPSD)
        XCTAssertTrue(preview.task(id: back)?.roleImages?.isFinalized == true)
        XCTAssertEqual(preview.task(id: front)?.pendingFinalPSD, pending)

        _ = try saveReviewPSD(stale.workingURL, marker: "changed after confirmation")
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [front, third], kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(result.task(id: front)?.pendingFinalPSD)
        XCTAssertEqual(result.task(id: front)?.snapshot?.contentVersion, pending.contentVersion)
        XCTAssertEqual(result.task(id: front)?[.png4k].state, .completed)
        XCTAssertEqual(result.task(id: third)?[.geometry].confirmedVersion, stale.contentVersion)
        XCTAssertEqual(result.task(id: third)?[.png4k].state, .failed)
        XCTAssertNotNil(result.task(id: third)?.finalPreparationError)
        XCTAssertTrue(result.task(id: third)?.artifacts.isEmpty == true)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "prepare-final" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "render-png4k" }.count, 1)
    }

    func testForeignOwnershipBlocksAcceptanceOfOnlyThatFace() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front, back])
        let frontURL = try XCTUnwrap(urls.first), backURL = try XCTUnwrap(urls.last)
        await photoshop.setDocuments([openDocument(frontURL, 1), openDocument(backURL, 2)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        try JSONEncoder().encode(ExecutorFixture.snapshot(UUID(), frontURL, "foreign", roles: true)).write(to: frontURL)
        let version = try saveReviewPSD(backURL, marker: "known owner")
        await photoshop.setDocuments([])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(result.task(id: front)?.acceptedFinalPSD)
        XCTAssertNotNil(result.task(id: front)?.manualEditError)
        XCTAssertEqual(result.task(id: back)?[.geometry].confirmedVersion, version)
        XCTAssertNil(result.manualReviewSessionID)
    }

    func testAutomaticObservationReportsPhotoshopAbsentButExplicitCancelCanRecover() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id
        _ = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front])
        await photoshop.setNextObservation { throw WorkflowBridgeError.photoshopNotRunning }
        do {
            try await executor.pollManualEdits(batchID: f.batch.id)
            XCTFail("A stopped application became a successful empty observation")
        } catch { XCTAssertEqual(error as? WorkflowBridgeError, .photoshopNotRunning) }
        let retained = try await executor.batch(batchID: f.batch.id)
        XCTAssertNotNil(retained.manualReviewSessionID)
        await photoshop.setNextObservation { throw WorkflowBridgeError.photoshopNotRunning }
        try await executor.cancelClosedBatchEdits(batchID: f.batch.id, taskIDs: [front])
        let canceled = try await executor.batch(batchID: f.batch.id)
        XCTAssertNil(canceled.manualReviewSessionID)
        XCTAssertEqual(canceled.task(id: front)?[.geometry].state, .waitingReview)
    }

    func testExportFreezesAcceptedVersionButWaitsForRemainingManualDocument() async throws {
        let (f, executor, photoshop) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        let urls = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front, back])
        let frontURL = try XCTUnwrap(urls.first), backURL = try XCTUnwrap(urls.last)
        await photoshop.setDocuments([openDocument(frontURL, 1), openDocument(backURL, 2)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        let version = try saveReviewPSD(frontURL, marker: "accepted")
        await photoshop.setDocuments([openDocument(backURL, 2)])
        try await executor.pollManualEdits(batchID: f.batch.id)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [front], kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        try await executor.runPending(batchID: f.batch.id)
        let queued = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(queued.task(id: front)?.requestedExports?[.png4k]?.snapshotVersion, version)
        XCTAssertEqual(queued.task(id: front)?[.png4k].state, .pending)
        let queuedCalls = await f.probe.values()
        XCTAssertFalse(queuedCalls.contains("prepare-final"))

        await photoshop.setDocuments([])
        try await executor.pollManualEdits(batchID: f.batch.id)
        try await executor.runPending(batchID: f.batch.id)
        let exported = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(exported.task(id: front)?[.png4k].state, .completed)
        XCTAssertEqual(exported.task(id: back)?[.geometry].state, .waitingReview)
    }

    func testAcceptedVersionManifestRejectsSnapshotOutsideOwningTask() async throws {
        let (f, executor, _) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [front])
        var batch = try await executor.batch(batchID: f.batch.id)
        let receipt = try XCTUnwrap(batch.task(id: front)?.acceptedFinalPSD)
        batch.specimens[0].front.acceptedFinalPSD = WorkflowAcceptedFinalPSD(taskID: front, sourceRevision: receipt.sourceRevision,
            workingURL: receipt.workingURL, snapshotURL: batch.acceptedFinalURL(taskID: back, contentVersion: receipt.contentVersion),
            contentVersion: receipt.contentVersion)
        XCTAssertThrowsError(try batch.validate())
    }

    func testReprocessingAcceptedPSDFromStackPreservesItsConfirmedFiles() async throws {
        try await checkReprocessingAcceptedPSD(from: .stack, expectedStackRuns: 3, expectedCheckpoint: nil)
    }

    func testReprocessingAcceptedPSDFromGeometryUsesMatteCheckpoint() async throws {
        try await checkReprocessingAcceptedPSD(from: .geometry, expectedStackRuns: 2, expectedCheckpoint: "restore-matte")
    }

    private func checkReprocessingAcceptedPSD(from stage: WorkflowStage, expectedStackRuns: Int, expectedCheckpoint: String?) async throws {
        let (f, executor, _) = try await readyBatchReview()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let front = f.batch.specimens[0].front.id, back = f.batch.specimens[0].back.id
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [front, back])
        if stage == .geometry { try await executor.prepareFinalPSD(batchID: f.batch.id, taskID: front) }
        let before = try await executor.batch(batchID: f.batch.id)
        let receipt = try XCTUnwrap(before.task(id: front)?.acceptedFinalPSD)

        try await executor.reprocessTask(batchID: f.batch.id, taskID: front, from: stage, expectedVersion: receipt.contentVersion)

        let result = try await executor.batch(batchID: f.batch.id)
        let replacement = try XCTUnwrap(result.task(id: front)?.snapshot?.workingURL)
        XCTAssertNotEqual(replacement, receipt.workingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertEqual(try AIFileValidation.hash(receipt.workingURL.path), receipt.contentVersion)
        XCTAssertEqual(try AIFileValidation.hash(receipt.snapshotURL.path), receipt.contentVersion)
        XCTAssertNil(result.task(id: front)?.acceptedFinalPSD)
        XCTAssertNil(result.task(id: front)?[.geometry].confirmedVersion)
        XCTAssertEqual(result.task(id: front)?[.geometry].state, .waitingReview)
        XCTAssertEqual(result.task(id: back)?.acceptedFinalPSD, before.task(id: back)?.acceptedFinalPSD)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "stack" }.count, expectedStackRuns)
        XCTAssertEqual(calls.first { $0.hasPrefix("restore-") }, expectedCheckpoint)
    }

    private func openDocument(_ url: URL, _ id: Int, saved: Bool = true) -> WorkflowOpenPhotoshopDocument {
        WorkflowOpenPhotoshopDocument(url: url, documentID: id, saved: saved)
    }

    private func saveReviewPSD(_ url: URL, marker: String) throws -> String {
        try Self.saveReviewFile(url, marker: marker)
        return try AIFileValidation.hash(url.path)
    }

    private nonisolated static func saveReviewFile(_ url: URL, marker: String) throws {
        var snapshot = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: url))
        snapshot.structureSummary = marker
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func readyBatchReview(count: Int = 1) async throws -> (ExecutorFixture, WorkflowExecutor, ReviewPhotoshop) {
        let f = try ExecutorFixture(count: count)
        var batch = f.batch
        let photoshop = ReviewPhotoshop()
        let executor = WorkflowExecutor(services: batchReviewServices(f, photoshop), coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        return (f, executor, photoshop)
    }

    private func batchReviewServices(_ f: ExecutorFixture, _ photoshop: ReviewPhotoshop) -> WorkflowExecutor.Services {
        var services = finalServices(f)
        services.openDocuments = { try await photoshop.list() }
        services.verifyManualSaveOwnership = { url, owner in
            let snapshot = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.taskID == owner else { throw WorkflowBridgeError.ownershipConflict }
        }
        services.restoreCheckpoint = { checkpoint, destination in
            await f.probe.record("restore-\(checkpoint.contentVersion)")
            var restored = checkpoint; restored.workingURL = destination
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(restored).write(to: destination)
            return restored
        }
        services.prepareAcceptedFinalPSD = { accepted in
            await f.probe.record("prepare-final")
            var snapshot = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: accepted.snapshotURL))
            snapshot.snapshotURL = accepted.snapshotURL; snapshot.contentVersion = accepted.contentVersion
            snapshot.roles = nil
            snapshot.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "final-a", baseLayer: "final-b", cutoutLayer: "final-c")
            var roles = ExecutorFixture.roles(snapshot)
            roles.isFinalized = true
            return (snapshot, roles)
        }
        return services
    }

    func testFinalSnapshotAcceptsChangedLayerIdentitiesButRejectsForeignOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("final-bridge-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.psd"); try Data("original".utf8).write(to: url)
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("work"),scriptRunner: { script in
            if script.contains("wfFinalMetadata(o.doc)") {
                return "{\"width\":100,\"height\":80,\"profile\":\"sRGB\",\"summary\":\"edited\",\"finalRoles\":{\"adjustmentGroup\":\"new-group\",\"baseLayer\":\"new-base\",\"cutoutLayer\":\"new-cutout\"}}"
            }
            return "{\"width\":100,\"height\":80,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        let owner = UUID(), source = try WorkflowSourceFile(url: url,fingerprint: AIFileValidation.hash(url.path))
        let original = try await bridge.adoptStack(source: source,owner: owner)
        try Data("edited".utf8).write(to: url)
        let final = try await bridge.captureFinalPSD(document: url,owner: owner)
        XCTAssertNil(final.roles); XCTAssertEqual(final.finalRoles?.cutoutLayer,"new-cutout")
        XCTAssertEqual(try AIFileValidation.hash(final.snapshotURL.path),final.contentVersion)
        XCTAssertEqual(try AIFileValidation.hash(original.snapshotURL.path),source.fingerprint)
        do { _ = try await bridge.captureFinalPSD(document: url,owner: UUID()); XCTFail("Foreign PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.ownershipConflict) }
    }

    func testImpossibleGeometryRequiresExplicitManualAdoptionBeforeConfirmation() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = finalServices(f)
        services.analyze = { roles,_ in
            var solution = ExecutorFixture.solution(roles.snapshotVersion)
            solution.isApplicable = false; solution.reason = "背景不足"; return solution
        }
        services.acknowledgeManualResult = { _ in await f.probe.record("adopt-manual-geometry") }
        let executor = WorkflowExecutor(services: services,coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: batch,manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let failed = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.geometry].state == .failed && $0.geometrySolution?.isApplicable == false })
        let face = try XCTUnwrap(failed.activeTasks.first), version = try XCTUnwrap(face.snapshot?.contentVersion)
        do {
            try await executor.confirmSavedTasks(batchID: batch.id, taskIDs: [face.id])
            XCTFail("Failed geometry accepted without manual adoption")
        } catch WorkflowStateError.invalidTransition {}
        _ = try await executor.beginManualEditing(batchID: batch.id,taskID: face.id)
        try await executor.adoptCurrentPSD(batchID: batch.id,taskID: face.id)
        try await executor.endManualEditing(batchID: batch.id)
        try await executor.confirmSavedTasks(batchID: batch.id, taskIDs: [face.id])

        let result = try await executor.batch(batchID: batch.id), calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "adopt-manual-geometry" }.count,1)
        XCTAssertFalse(calls.contains("apply-save"))
        XCTAssertEqual(result.task(id: face.id)?[.geometry].confirmedVersion, try AIFileValidation.hash(face.snapshot!.workingURL.path))
        XCTAssertEqual(result.activeTasks.last?[.geometry].state,.failed)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.artifacts.isEmpty })
    }

    func testCombinedExportRetriesHDFailureFromVisibleExportStage() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        await f.probe.fail([.hd])
        try await e.requestExports(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let failed = try await e.batch(batchID: batch.id)
        XCTAssertEqual(failed.currentStage,.png4k); XCTAssertFalse(failed.allSucceeded)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.hd].state == .failed && $0[.png4k].state == .completed })
        await f.probe.fail([])
        try await e.retryTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), stage: .hd)
        let retried = try await e.batch(batchID: batch.id),calls = await f.probe.values()
        XCTAssertTrue(retried.allSucceeded)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count,2)
    }

    func testSwitchingFacesRequiresSavedPreviousFaceAndDoesNotLoseManualLease() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let gate = FinalizationSaveGate()
        var services = finalServices(f); let finalize = services.finalize!
        services.finalize = { url,id in if await gate.dirty { throw WorkflowBridgeError.unsavedDocument }; return try await finalize(url,id) }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        let front = batch.specimens[0].front.id,back = batch.specimens[0].back.id
        _ = try await e.beginManualEditing(batchID: batch.id,taskID: front)
        await gate.setDirty(true)
        do { _ = try await e.beginManualEditing(batchID: batch.id,taskID: back); XCTFail("Dirty previous face switched") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.unsavedDocument) }
        _ = try await e.beginManualEditing(batchID: batch.id,taskID: front)
        await gate.setDirty(false)
        _ = try await e.beginManualEditing(batchID: batch.id,taskID: back)
        try await e.endManualEditing(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.acceptedFinalPSD != nil })
    }

    func testFinalExportRejectsChangedSourceAfterRenderBeforePublication() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let gate = FinalizationSaveGate()
        var services = finalServices(f); let extract = services.extract,render = services.render
        services.extract = { snapshot in
            if snapshot.finalRoles != nil,await gate.dirty { throw WorkflowBridgeError.staleSource }
            return try await extract(snapshot)
        }
        services.render = { kind,roles,source,layout,presets,url in
            try await render(kind,roles,source,layout,presets,url); await gate.setDirty(true)
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        try await e.requestExports(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let result = try await e.batch(batchID: batch.id)
        XCTAssertFalse(result.allSucceeded)
        XCTAssertTrue(result.activeTasks.flatMap(\.artifacts).allSatisfy { $0.state != .completed && !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testFailedMatteCanBeOpenedForManualRepairButCannotBeConfirmed() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let id = batch.specimens[0].front.id
        var services = finalServices(f); let select = try XCTUnwrap(services.selectSubject)
        services.selectSubject = { snapshot in
            if snapshot.taskID == id { throw WorkflowBridgeError.invalidImage("没有识别到主体") }
            return try await select(snapshot)
        }
        let executor = WorkflowExecutor(services: services,coordinator: PhotoshopExecutionCoordinator())
        try await executor.register(batch: batch,manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let before = try await executor.batch(batchID: batch.id)
        let failed = try XCTUnwrap(before.task(id: id))
        let snapshot = try XCTUnwrap(failed.snapshot)
        XCTAssertEqual(failed[.matte].state,.failed)
        let document = try await executor.beginManualEditing(batchID: batch.id,taskID: id)
        XCTAssertEqual(document,snapshot.workingURL)
        try await executor.endManualEditing(batchID: batch.id)
        do {
            try await executor.confirmSavedTasks(batchID: batch.id, taskIDs: [id])
            XCTFail("Unrepaired matte accepted as final")
        } catch WorkflowStateError.invalidTransition {}
        let after = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(after.isPaused)
        XCTAssertEqual(after.task(id: id)?[.matte].state,.failed)
        XCTAssertEqual(after.task(id: id)?[.geometry].state,.pending)
        XCTAssertEqual(after.task(id: id)?.snapshot,snapshot)
    }

    func testPNGFailureKeepsSuccessfulJPEGWhenRetryingCombinedExport() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        await f.probe.fail([.png4k])
        try await e.requestExports(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let failed = try await e.batch(batchID: batch.id)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.hd].state == .completed && $0[.png4k].state == .failed })
        await f.probe.fail([])
        try await e.retryTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), stage: .png4k)
        let retried = try await e.batch(batchID: batch.id),calls = await f.probe.values()
        XCTAssertTrue(retried.allSucceeded); XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,2)
    }

    @MainActor func testNewDraftUsesFixedDirectoriesAndMandatoryReview() throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "标本",output: f.batch.outputDirectory.appendingPathComponent("batch"))
        XCTAssertEqual(batch.schemaVersion, WorkflowBatch.currentSchemaVersion)
        let store = PhotoWorkflowStore(); store.scan(f.batch.sourceDirectory)
        XCTAssertTrue(store.canStart)
        XCTAssertEqual(store.exportDirectory(for: .png4k),batch.exportDirectory(for: .png4k))
        XCTAssertEqual(store.exportDirectory(for: .hd),batch.exportDirectory(for: .hd))
    }

    @MainActor func testPausedExportHasResumeEntryAndDoesNotBypassConfirmation() async throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        await e.pause(batchID: batch.id)
        let store = PhotoWorkflowStore(); store.batch = try await e.batch(batchID: batch.id); store.stage = .png4k
        XCTAssertTrue(store.canResumeAutomatic)
        try await e.continueAutomatic(batchID: batch.id)
        let resumed = try await e.batch(batchID: batch.id)
        XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.png4k].state == .pending && $0.artifacts.isEmpty })
        store.batch = resumed; XCTAssertFalse(store.canResumeAutomatic)
    }

    func testFixedOutputDirectoryRejectsSymlinkOutsideInput() throws {
        let f = try ExecutorFixture(); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("final-foreign-\(UUID())")
        try FileManager.default.createDirectory(at: external,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let root = try XCTUnwrap(batch.exportDirectory(for: .png4k))
        try FileManager.default.createSymbolicLink(at: root,withDestinationURL: external)
        XCTAssertThrowsError(try batch.validateArtifactURL(root.appendingPathComponent("sample0_D.png"),kind: .png4k))
        XCTAssertThrowsError(try batch.validateOutputURL(root.appendingPathComponent("sample0_D.png")))
    }

    private func finalServices(_ f: ExecutorFixture) -> WorkflowExecutor.Services {
        var services = f.services
        services.finalize = { url,id in
            var snapshot = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: url))
            snapshot.roles = nil
            snapshot.finalRoles = FinalPSDIdentifiers(adjustmentGroup: "final-a",baseLayer: "final-b",cutoutLayer: "final-c")
            return snapshot
        }
        services.extract = { snapshot in
            var roles = ExecutorFixture.roles(snapshot); roles.isFinalized = snapshot.finalRoles != nil; return roles
        }
        return services
    }
}

private actor FinalizationSaveGate {
    var dirty = false
    func setDirty(_ value: Bool) { dirty = value }
}

private actor ReviewPhotoshop {
    private var documents: [WorkflowOpenPhotoshopDocument] = []
    private var responses: [@Sendable () throws -> [WorkflowOpenPhotoshopDocument]] = []

    func setDocuments(_ documents: [WorkflowOpenPhotoshopDocument]) { self.documents = documents }
    func setNextObservation(_ response: @escaping @Sendable () throws -> [WorkflowOpenPhotoshopDocument]) {
        responses.append(response)
    }
    func failNextObservation() { setNextObservation { throw WorkflowBridgeError.photoshop("busy") } }
    func list() throws -> [WorkflowOpenPhotoshopDocument] {
        if !responses.isEmpty { return try responses.removeFirst()() }
        return documents
    }
}
