// 验证批次队列顺序、独立查看、安全暂停和恢复，素材仅来自临时测试夹具。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowBatchQueueTests: XCTestCase {
    func testRunsInSavedOrderAndLeavesBothBatchesForReview() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.addBoth(to: store)
        store.moveQueuedBatch(fixture.second.id, by: -1)
        XCTAssertEqual(store.batchQueue.map(\.id), [fixture.second.id, fixture.first.id])
        let reopened = fixture.store()
        XCTAssertEqual(reopened.batchQueue.map(\.id), [fixture.second.id, fixture.first.id])
        XCTAssertFalse(reopened.isBatchQueueRunning)

        reopened.runBatchQueue()
        try await waitUntil { !reopened.isBatchQueueRunning }
        let order = await fixture.probe.order
        XCTAssertEqual(order, ["第二批", "第二批", "第一批", "第一批"])
        for entry in reopened.batchQueue {
            let value = try await WorkflowBatchStore().load(from: entry.manifest)
            XCTAssertTrue(value.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
            XCTAssertTrue(value.activeTasks.allSatisfy { $0[.png4k].state == .pending })
        }
    }

    func testSwitchingViewDuringQueueAndPausingDoesNotDispatchNextBatch() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.addBoth(to: store)
        await fixture.probe.arm()
        store.runBatchQueue()
        try await fixture.probe.waitForStack()
        store.openBatch(fixture.second.manifest)
        try await waitUntil { !store.busy && store.batch?.id == fixture.second.id }
        XCTAssertEqual(store.runningBatch?.id, fixture.first.id)
        store.beginNewBatch()
        try await waitUntil { !store.busy && store.batch == nil }
        store.scan(fixture.first.source)
        store.names = "新增标本"
        store.start()
        try await waitUntil { !store.busy && store.batchQueue.count == 3 }
        let added = try XCTUnwrap(store.batchQueue.last)
        XCTAssertEqual(store.runningBatch?.id, fixture.first.id)
        store.pauseBatchQueue()
        await fixture.probe.release()
        try await waitUntil { !store.isBatchQueueRunning }
        let paused = try await WorkflowBatchStore().load(from: fixture.first.manifest)
        let order = await fixture.probe.order
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(order, ["第一批"])
        let reopened = fixture.store()
        XCTAssertTrue(reopened.canContinueBatchQueue)
        reopened.removeQueuedBatch(added.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.manifest.path))
        reopened.runBatchQueue()
        try await waitUntil { !reopened.isBatchQueueRunning }
        let completed = await fixture.probe.order
        XCTAssertEqual(completed, ["第一批", "第一批", "第二批", "第二批"])
    }

    func testRunSingleBatchDoesNotStartOthersAndSavingDraftOnlyEnqueues() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.addBoth(to: store)

        store.beginNewBatch()
        store.scan(fixture.first.source)
        store.names = "新增标本"
        store.start()
        try await waitUntil { !store.busy && store.batchQueue.count == 3 }
        let before = await fixture.probe.order
        XCTAssertTrue(before.isEmpty)

        store.runQueuedBatch(fixture.second.id)
        try await waitUntil { !store.isBatchQueueRunning }
        let after = await fixture.probe.order
        XCTAssertEqual(after, ["第二批", "第二批"])
        let first = try await WorkflowBatchStore().load(from: fixture.first.manifest)
        XCTAssertTrue(first.activeTasks.allSatisfy { $0[.stack].state == .pending })
    }

    func testMissingManifestDoesNotPreventFollowingBatchFromRunning() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.addBoth(to: store)
        try FileManager.default.removeItem(at: fixture.first.manifest)
        store.runBatchQueue()
        try await waitUntil { !store.isBatchQueueRunning }
        let order = await fixture.probe.order
        XCTAssertEqual(order, ["第二批", "第二批"])
        XCTAssertEqual(store.batchQueueStatuses[fixture.first.id], "无法处理")
        XCTAssertTrue(store.batchQueueStatuses[fixture.second.id]?.contains("待检查") == true)
        XCTAssertEqual(store.batchQueue.count, 2)
    }

    func testAlreadyRequestedExportWaitsUntilAfterQueuePreparation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let original = WorkflowExecutor(services: fixture.services, coordinator: PhotoshopExecutionCoordinator())
        let id = try await original.register(manifestURL: fixture.first.manifest)
        try await original.runPending(batchID: id)
        let prepared = try await original.batch(batchID: id)
        let task = try XCTUnwrap(prepared.activeTasks.first)
        let second = try XCTUnwrap(prepared.activeTasks.last)
        let taskID = task.id
        try await original.confirmSavedTasks(batchID: id, taskIDs: [taskID])
        try await original.update(batchID: id,
            event: .sourceChanged(taskID: second.id, sources: second.sources, expectedVersion: second.sourceRevision))
        await original.pause(batchID: id)
        try await original.requestExports(batchID: id, taskIDs: [taskID], kinds: [.hd], policy: .skipExisting, layouts: [:])
        let store = fixture.store()
        try await fixture.addBoth(to: store)
        store.runBatchQueue()
        try await waitUntil { !store.isBatchQueueRunning }
        let saved = try await WorkflowBatchStore().load(from: fixture.first.manifest)
        let other = try await WorkflowBatchStore().load(from: fixture.second.manifest)
        XCTAssertNotNil(saved.task(id: taskID)?.requestedExports?[.hd])
        XCTAssertEqual(saved.task(id: taskID)?[.hd].state, .pending)
        XCTAssertEqual(saved.task(id: second.id)?[.geometry].state, .waitingReview)
        store.openBatch(fixture.first.manifest)
        try await waitUntil { !store.busy && store.batch?.id == fixture.first.id }
        XCTAssertTrue(store.canResumeAutomatic)
        XCTAssertTrue(other.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
    }

    func testRunningPrimaryDoesNotMutateAnAlternateManifestOfTheViewedBatch() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        try await fixture.addBoth(to: store)
        let alternate = fixture.first.manifest.deletingLastPathComponent().appendingPathComponent("batch-recovery.json")
        try FileManager.default.copyItem(at: fixture.first.manifest, to: alternate)
        store.openBatch(alternate)
        try await waitUntil { !store.busy && store.batch?.id == fixture.first.id }
        store.runBatchQueue()
        try await waitUntil { !store.isBatchQueueRunning }
        let order = await fixture.probe.order
        XCTAssertEqual(order, ["第二批", "第二批"])
        XCTAssertEqual(store.batchQueueStatuses[fixture.first.id], "无法处理")
    }

    func testQueueWriteFailureKeepsSavedBatchAvailableToEnqueueAgain() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let store = fixture.store()
        let queue = fixture.root.appendingPathComponent("queue.json", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        store.scan(fixture.first.source)
        store.names = "保存重试"
        store.start()
        try await waitUntil { !store.busy }
        let saved = try XCTUnwrap(store.batch)
        XCTAssertTrue(store.batchQueue.isEmpty)
        XCTAssertNil(store.draft)
        XCTAssertNotNil(store.error)
        try FileManager.default.removeItem(at: queue)
        store.addViewedBatchToQueue()
        XCTAssertEqual(store.batchQueue.map(\.id), [saved.id])
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private actor StackProbe {
        var order: [String] = []
        private var hold = false
        private var waiter: CheckedContinuation<Void, Never>?
        func arm() { hold = true }
        func record(_ title: String) async {
            order.append(title)
            if hold { await withCheckedContinuation { waiter = $0 } }
        }
        func waitForStack() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while waiter == nil {
                guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func release() { hold = false; waiter?.resume(); waiter = nil }
    }

    private struct Fixture {
        struct Saved {
            let id: UUID
            let manifest: URL
            let source: URL
        }

        let root: URL
        let first: Saved
        let second: Saved
        let services: WorkflowExecutor.Services
        let probe: StackProbe

        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-queue-\(UUID())", isDirectory: true)
            let first = try ExecutorFixture(storageRoot: root)
            let second = try ExecutorFixture(storageRoot: root)
            let probe = StackProbe()
            var services = first.services
            let stack = services.stack
            let firstSource = first.batch.sourceDirectory
            services.stack = { job, owner in
                let title = job.destinationURL.pathComponents.starts(with: firstSource.pathComponents) ? "第一批" : "第二批"
                await probe.record(title)
                return try await stack(job, owner)
            }

            func save(_ fixture: ExecutorFixture) async throws -> Saved {
                let batch = fixture.batch
                let source = batch.sourceDirectory
                try await WorkflowBatchStore().save(batch, to: fixture.manifest)
                return Saved(id: batch.id, manifest: fixture.manifest, source: source)
            }
            return try await Self(root: root, first: save(first), second: save(second), services: services, probe: probe)
        }

        @MainActor func store() -> PhotoWorkflowStore {
            PhotoWorkflowStore(makeExecutor: { _ in WorkflowExecutor(services: services, coordinator: PhotoshopExecutionCoordinator()) },
                batchCatalog: WorkflowBatchCatalog(storageRoot: root), batchQueueRoot: root)
        }
        func addBoth(to store: PhotoWorkflowStore) async throws {
            try await store.addBatchToQueue(first.manifest)
            try await store.addBatchToQueue(second.manifest)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
