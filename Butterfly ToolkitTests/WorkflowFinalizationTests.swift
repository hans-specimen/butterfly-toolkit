// 验证人工定稿屏障、最终图层读取、保存版本隔离与双输出恢复。
import XCTest
@testable import Butterfly_Toolkit

final class WorkflowFinalizationTests: XCTestCase {
    func testAutomaticGeometryStopsForMandatoryReviewEvenWhenOldChecksAreOff() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true; batch.checkGeometry = false; batch.check4K = false
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
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
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
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        var result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .completed && $0[.png4k].state == .waitingReview && $0.artifacts.isEmpty })
        try await e.confirm4K(batchID: batch.id,layouts: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id,$0.squareLayout) }))
        result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertTrue(result.activeTasks.allSatisfy { Set($0.artifacts.filter { $0.state == .completed }.map(\.kind)) == [.hd,.png4k] })
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,2)
        let reopened = WorkflowExecutor(services: finalServices(f))
        _ = try await reopened.register(manifestURL: f.manifest)
        let restored = try await reopened.batch(batchID: batch.id)
        XCTAssertTrue(restored.allSucceeded)
    }

    func testMigrationBacksUpManifestAndDoesNotApplyGeometryToEditedPSD() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: f.batch,manifestURL: f.manifest); try await e.runPending(batchID: f.batch.id)
        let before = try Data(contentsOf: f.manifest)
        try await e.migrateToFinalization(batchID: f.batch.id)
        let result = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(result.manualFinalization,true)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        let backups = try FileManager.default.contentsOfDirectory(at: f.batch.outputDirectory,includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("batch-before-finalization-") }
        XCTAssertEqual(backups.count,1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)),before)
        try await e.runPending(batchID: f.batch.id)
        let calls = await f.probe.values(); XCTAssertFalse(calls.contains("apply-save"))
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

    func testImpossibleGeometryStillReachesManualReviewWithoutApplying() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        var services = finalServices(f)
        services.analyze = { roles,_ in var solution = ExecutorFixture.solution(roles.snapshotVersion); solution.isApplicable = false; solution.reason = "背景不足"; return solution }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        let result = try await e.batch(batchID: batch.id),calls = await f.probe.values()
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview && $0.geometrySolution?.isApplicable == false })
        XCTAssertFalse(calls.contains("apply-save"))
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        let final = try await e.batch(batchID: batch.id)
        XCTAssertEqual(final.currentStage,.png4k)
    }

    func testCombinedExportRetriesHDFailureFromVisibleExportStage() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        await f.probe.fail([.hd])
        try await e.confirm4K(batchID: batch.id,layouts: Dictionary(uniqueKeysWithValues: batch.activeTasks.map { ($0.id,$0.squareLayout) }))
        let failed = try await e.batch(batchID: batch.id)
        XCTAssertEqual(failed.currentStage,.png4k); XCTAssertFalse(failed.allSucceeded)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.hd].state == .failed && $0[.png4k].state == .pending })
        await f.probe.fail([])
        try await e.retry(batchID: batch.id,specimenIDs: [batch.specimens[0].id],stage: .png4k)
        let retried = try await e.batch(batchID: batch.id),calls = await f.probe.values()
        XCTAssertTrue(retried.allSucceeded)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "ai" }.count,2)
    }

    func testSwitchingFacesRequiresSavedPreviousFaceAndDoesNotLoseManualLease() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
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
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.snapshot?.finalRoles?.isValid == true })
    }

    func testFinalExportRejectsChangedSourceAfterRenderBeforePublication() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
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
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        try await e.confirm4K(batchID: batch.id,layouts: Dictionary(uniqueKeysWithValues: batch.activeTasks.map { ($0.id,$0.squareLayout) }))
        let result = try await e.batch(batchID: batch.id)
        XCTAssertFalse(result.allSucceeded)
        XCTAssertTrue(result.activeTasks.flatMap(\.artifacts).allSatisfy { $0.state != .completed && !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testCannotEnterManualFinalizationBeforeMatteIsComplete() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        batch.specimens[0].front.snapshot = ExecutorFixture.snapshot(batch.specimens[0].front.id,batch.sourceDirectory.appendingPathComponent("sample0_D.psd"),"stack",roles: false)
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest)
        do { _ = try await e.beginManualEditing(batchID: batch.id,taskID: batch.specimens[0].front.id); XCTFail("Manual lease entered before matte") }
        catch { XCTAssertEqual(error as? WorkflowStateError,.invalidTransition) }
        try await e.runPending(batchID: batch.id)
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
    }

    func testPNGFailureKeepsSuccessfulJPEGWhenRetryingCombinedExport() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        await f.probe.fail([.png4k])
        try await e.confirm4K(batchID: batch.id,layouts: Dictionary(uniqueKeysWithValues: batch.activeTasks.map { ($0.id,$0.squareLayout) }))
        let failed = try await e.batch(batchID: batch.id)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.hd].state == .completed && $0[.png4k].state == .failed })
        await f.probe.fail([])
        try await e.retry(batchID: batch.id,specimenIDs: [batch.specimens[0].id],stage: .png4k)
        let retried = try await e.batch(batchID: batch.id),calls = await f.probe.values()
        XCTAssertTrue(retried.allSucceeded); XCTAssertEqual(calls.filter { $0 == "render-hd" }.count,2)
    }

    @MainActor func testNewDraftUsesFixedDirectoriesAndMandatoryReview() throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "标本",output: f.batch.outputDirectory.appendingPathComponent("batch"),checkStack: true,checkMatte: true,checkGeometry: false,check4K: false,manualFinalization: true)
        XCTAssertEqual(batch.manualFinalization,true); XCTAssertFalse(batch.checkAfterStack); XCTAssertFalse(batch.checkAfterMatte)
        XCTAssertEqual(batch.checkGeometry,true); XCTAssertEqual(batch.check4K,true)
        let store = PhotoWorkflowStore(); store.scan(f.batch.sourceDirectory)
        XCTAssertTrue(store.canStart); XCTAssertFalse(store.needsExportDirectories)
        XCTAssertEqual(store.exportDirectory(for: .png4k),batch.exportDirectory(for: .png4k))
        XCTAssertEqual(store.exportDirectory(for: .hd),batch.exportDirectory(for: .hd))
    }

    @MainActor func testPausedExportHasResumeEntryAndDoesNotBypassConfirmation() async throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: batch,manifestURL: f.manifest); try await e.runPending(batchID: batch.id)
        try await e.confirmFinalPSD(batchID: batch.id,specimenIDs: [batch.specimens[0].id])
        await e.pause(batchID: batch.id)
        let store = PhotoWorkflowStore(); store.batch = try await e.batch(batchID: batch.id); store.stage = .png4k
        XCTAssertTrue(store.canResumeAutomatic)
        try await e.continueAutomatic(batchID: batch.id)
        let resumed = try await e.batch(batchID: batch.id)
        XCTAssertTrue(resumed.activeTasks.allSatisfy { $0[.png4k].state == .waitingReview && $0.artifacts.isEmpty })
        store.batch = resumed; XCTAssertFalse(store.canResumeAutomatic)
    }

    func testFixedOutputDirectoryRejectsSymlinkOutsideInput() throws {
        let f = try ExecutorFixture(checks: false); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.manualFinalization = true
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("final-foreign-\(UUID())")
        try FileManager.default.createDirectory(at: external,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let root = try XCTUnwrap(batch.exportDirectory(for: .png4k))
        try FileManager.default.createSymbolicLink(at: root,withDestinationURL: external)
        XCTAssertThrowsError(try batch.validateArtifactURL(root.appendingPathComponent("sample0_D.png"),kind: .png4k))
        XCTAssertThrowsError(try batch.validateOutputURL(root.appendingPathComponent("sample0_D.png")))
    }

    func testMigrationBeforeCompletedMatteLeavesLegacyBatchUntouched() async throws {
        let f = try ExecutorFixture(checks: true); defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = WorkflowExecutor(services: finalServices(f))
        try await e.register(batch: f.batch,manifestURL: f.manifest)
        let before = try Data(contentsOf: f.manifest)
        do { try await e.migrateToFinalization(batchID: f.batch.id); XCTFail("Incomplete legacy batch migrated") }
        catch { XCTAssertTrue(error.localizedDescription.contains("AI")) }
        let unchanged = try await e.batch(batchID: f.batch.id)
        XCTAssertNil(unchanged.manualFinalization); XCTAssertEqual(try Data(contentsOf: f.manifest),before)
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
