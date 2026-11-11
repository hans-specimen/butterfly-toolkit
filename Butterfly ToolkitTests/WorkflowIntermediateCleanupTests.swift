// 验证整批所选格式成功后只清理本批次中转文件，并可从同一保存版本安全重建。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowIntermediateCleanupTests: XCTestCase {
    private func fixture() throws -> (URL, ExecutorFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try ExecutorFixture(storageRoot: root))
    }
    private func ready(_ f: ExecutorFixture, root: URL, services: WorkflowExecutor.Services? = nil) async throws -> WorkflowExecutor {
        let executor = WorkflowExecutor(services: services ?? f.services, coordinator: PhotoshopExecutionCoordinator(), intermediateStorageRoot: root)
        try await executor.register(batch: f.batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: f.batch.id)
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)))
        return executor
    }
    func testWholeBatchSuccessRemovesOnlyWorkAndBothManifestsRecordCleanup() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(".work")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sentinel = other.appendingPathComponent("keep"); try Data("other".utf8).write(to: sentinel)
        let executor = try await ready(f, root: root)
        let sources = try Dictionary(uniqueKeysWithValues: f.batch.sideTasks.flatMap(\.sources.files).map { ($0.url, try Data(contentsOf: $0.url)) })
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertNil(result.intermediateCleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        for task in result.activeTasks {
            XCTAssertTrue(task.intermediatesCleared); XCTAssertNil(task.roleImages); XCTAssertNil(task.checkpoints)
            XCTAssertNotNil(task.pendingFinalPSD)
            XCTAssertEqual(try AIFileValidation.hash(task.snapshot!.workingURL.path), task.acceptedFinalPSD?.contentVersion)
            for artifact in task.artifacts { XCTAssertEqual(try AIFileValidation.hash(artifact.url.path), artifact.fileFingerprint) }
        }
        for (url, bytes) in sources { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("other".utf8))
        for url in [f.manifest, f.manifest.appendingPathExtension("previous")] {
            let disk = try JSONDecoder().decode(WorkflowBatch.self, from: Data(contentsOf: url))
            XCTAssertTrue(disk.activeTasks.allSatisfy(\.intermediatesCleared))
        }
    }
    func testPartialFacesAndChangedSelectedFormatKeepWorkUntilWholeBatchCompletes() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = try await ready(f, root: root), ids = f.batch.activeTasks.map(\.id)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[0]], kinds: [.hd], policy: .overwrite, layouts: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[1]], kinds: [.hd], policy: .overwrite, layouts: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[0]], kinds: [.png4k], policy: .overwrite, layouts: [:])
        let partial = try await executor.batch(batchID: f.batch.id)
        XCTAssertFalse(partial.allSucceeded); XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[1]], kinds: [.png4k], policy: .overwrite, layouts: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }
    func testFailedExportsKeepWorkAndSelectingAnotherFormatCanCompleteBatch() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = try await ready(f, root: root)
        await f.probe.fail([.png4k])
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.png4k], policy: .overwrite, layouts: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        await f.probe.fail([])
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertTrue(result.allSucceeded); XCTAssertNil(result.intermediateCleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }
    func testCleanupRebuildIsPerFaceAndRejectsChangedWorkingPSD() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = try await ready(f, root: root), ids = f.batch.activeTasks.map(\.id)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(ids), kinds: [.hd], policy: .overwrite, layouts: [:])
        let reopened = WorkflowExecutor(services: f.services, coordinator: PhotoshopExecutionCoordinator(), intermediateStorageRoot: root)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.prepareFinalPSD(batchID: f.batch.id, taskID: ids[0])
        var result = try await reopened.batch(batchID: f.batch.id)
        XCTAssertFalse(result.task(id: ids[0])!.intermediatesCleared); XCTAssertTrue(result.task(id: ids[1])!.intermediatesCleared)
        XCTAssertNil(result.task(id: ids[0])!.pendingFinalPSD)
        let other = result.task(id: ids[1])!
        var changed = other.snapshot!; changed.contentVersion = "changed after cleanup"
        try JSONEncoder().encode(changed).write(to: changed.workingURL)
        do { try await reopened.prepareFinalPSD(batchID: f.batch.id, taskID: ids[1]); XCTFail("Changed PSD silently accepted") } catch {}
        result = try await reopened.batch(batchID: f.batch.id)
        XCTAssertTrue(result.task(id: ids[1])!.intermediatesCleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.acceptedFinalPSD!.snapshotURL.path))
    }
    func testDeletionFailurePreservesSuccessfulExportsAndCanRetry() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var services = f.services
        services.removeIntermediates = { _ in throw CocoaError(.fileWriteNoPermission) }
        let executor = try await ready(f, root: root, services: services)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd], policy: .overwrite, layouts: [:])
        let failed = try await executor.batch(batchID: f.batch.id)
        XCTAssertTrue(failed.allSucceeded); XCTAssertNotNil(failed.intermediateCleanupError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
        let reopened = WorkflowExecutor(services: f.services, coordinator: PhotoshopExecutionCoordinator(), intermediateStorageRoot: root)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd], policy: .skipExisting, layouts: [:])
        let retried = try await reopened.batch(batchID: f.batch.id)
        XCTAssertTrue(retried.allSucceeded); XCTAssertNil(retried.intermediateCleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }
    func testManifestSaveFailureNeverDeletesWorkOrFailsCompletedExports() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var services = f.services
        let verify = services.verifyPublishedArtifact, count = CleanupCounter()
        services.verifyPublishedArtifact = { artifact in
            try verify(artifact)
            if count.next() == 1 {
                try FileManager.default.moveItem(at: f.manifest, to: f.manifest.appendingPathExtension("retained"))
                try FileManager.default.createDirectory(at: f.manifest, withIntermediateDirectories: true)
            }
        }
        let executor = try await ready(f, root: root, services: services)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: Set(f.batch.activeTasks.map(\.id)), kinds: [.hd], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertTrue(result.allSucceeded); XCTAssertNotNil(result.intermediateCleanupError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }
    func testQueuedExportsOnOtherFacesSurviveChangingTheBatchSelection() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = try await ready(f, root: root), ids = f.batch.activeTasks.map(\.id)
        await executor.pause(batchID: f.batch.id)
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[0]], kinds: [.png4k], policy: .overwrite, layouts: [:])
        try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[1]], kinds: [.hd], policy: .overwrite, layouts: [:])
        let queued = try await executor.batch(batchID: f.batch.id)
        XCTAssertNotNil(queued.task(id: ids[0])?.requestedExports?[.png4k])
        try await executor.continueAutomatic(batchID: f.batch.id)
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: ids[0])?[.png4k].state, .completed)
        XCTAssertEqual(result.task(id: ids[1])?[.hd].state, .completed)
        XCTAssertFalse(result.allSucceeded)
    }
    func testConfirmedFaceCanQueueExportWhileAnotherFaceIsProcessing() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "Other face automatic work")
        let gate = CleanupOperationGate(entered)
        var services = f.services; let apply = services.apply
        services.apply = { saved, solution in await gate.waitIfArmed(); return try await apply(saved, solution) }
        let executor = try await ready(f, root: root, services: services), ids = f.batch.activeTasks.map(\.id)
        let before = try await executor.batch(batchID: f.batch.id).task(id: ids[1])!
        try await executor.update(batchID: f.batch.id, event: .sourceChanged(taskID: ids[1], sources: before.sources, expectedVersion: before.sourceRevision))
        await gate.arm()
        let automatic = Task { try await executor.runPending(batchID: f.batch.id) }
        await fulfillment(of: [entered], timeout: 3)
        do {
            try await executor.requestExports(batchID: f.batch.id, taskIDs: [ids[0]], kinds: [.hd], policy: .overwrite, layouts: [:])
        } catch { XCTFail("Ready face could not queue: \(error)") }
        await gate.release(); try await automatic.value
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertEqual(result.task(id: ids[0])?[.hd].state, .completed)
        XCTAssertEqual(result.task(id: ids[1])?[.geometry].state, .waitingReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }
    func testCleanupThenNewManualSaveCanExportAndCleanupAgain() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executor = try await ready(f, root: root), ids = Set(f.batch.activeTasks.map(\.id))
        try await executor.requestExports(batchID: f.batch.id, taskIDs: ids, kinds: [.hd], policy: .overwrite, layouts: [:])
        let before = try await executor.batch(batchID: f.batch.id)
        let front = before.activeTasks[0]
        _ = try await executor.beginBatchEditing(batchID: f.batch.id, taskIDs: [front.id])
        var edited = front.snapshot!; edited.contentVersion = "new manual save"
        try JSONEncoder().encode(edited).write(to: edited.workingURL)
        try await executor.confirmSavedTasks(batchID: f.batch.id, taskIDs: [front.id])
        try await executor.requestExports(batchID: f.batch.id, taskIDs: ids, kinds: [.hd], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: f.batch.id)
        XCTAssertTrue(result.allSucceeded); XCTAssertNil(result.intermediateCleanupError)
        XCTAssertNotEqual(result.task(id: front.id)?.acceptedFinalPSD?.contentVersion, front.acceptedFinalPSD?.contentVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.batch.outputDirectory.appendingPathComponent(".work").path))
    }

    func testSafeExportAncestorAllowsDirectArtifactsAndBatchCleanup() async throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var batch = f.batch
        // 用临时存储祖先模拟选择 Home：成品仍是根目录直接子文件，不落入 .work。
        batch.outputLocations = WorkflowOutputLocations(hd: root, png4k: root)
        XCTAssertNoThrow(try batch.validate())
        XCTAssertNoThrow(try batch.validateArtifactURL(root.appendingPathComponent("sample0_D.jpg"), kind: .hd))
        XCTAssertThrowsError(try batch.validateArtifactURL(batch.outputDirectory.appendingPathComponent(".work/forged.jpg"), kind: .hd))
        let executor = WorkflowExecutor(services: f.services, coordinator: PhotoshopExecutionCoordinator(), intermediateStorageRoot: root)
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        try await executor.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        try await executor.requestExports(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), kinds: [.hd, .png4k], policy: .overwrite, layouts: [:])
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.allSucceeded); XCTAssertNil(result.intermediateCleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.outputDirectory.appendingPathComponent(".work").path))
        for task in result.activeTasks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.snapshot!.workingURL.path))
            for artifact in task.artifacts {
                XCTAssertEqual(artifact.url.deletingLastPathComponent().path, root.path)
                XCTAssertEqual(try AIFileValidation.hash(artifact.url.path), artifact.fileFingerprint)
                XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.appendingPathExtension("test-receipt").path))
            }
        }
    }

    func testCleanupHelperRejectsForeignRootSymlinkAndProtectedOverlap() throws {
        let (root, f) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let work = f.batch.outputDirectory.appendingPathComponent(".work"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: outside)
        XCTAssertThrowsError(try WorkflowIntermediateCleanup.directory(batch: f.batch, manifest: f.manifest, storageRoot: root))
        try FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorkflowIntermediateCleanup.directory(batch: f.batch, manifest: f.manifest, storageRoot: outside))
        var overlapping = f.batch; overlapping.outputLocations = WorkflowOutputLocations(hd: work, png4k: nil)
        XCTAssertThrowsError(try WorkflowIntermediateCleanup.directory(batch: overlapping, manifest: f.manifest, storageRoot: root))
    }
}

private nonisolated final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private actor CleanupOperationGate {
    let entered: XCTestExpectation
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func arm() { armed = true }
    func waitIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}
