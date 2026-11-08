// Photoshop 任务协调器：串行调度自动处理，管理人工编辑期间的占用及同一任务的已保存文件读取。
// 等待队列支持取消，避免不同工具同时操作 Photoshop 文档。

import Foundation

// MARK: - 任务占用与等待队列

/// 占用必须跨越异步挂起持续保留；仅依靠 actor 隔离无法阻止重入任务同时操作 Photoshop。
actor PhotoshopExecutionCoordinator {
    static let shared = PhotoshopExecutionCoordinator()
    private struct Waiter {
        let id: UUID
        let owner: UUID
        let savedRead: Bool
        let manualRequest: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var busy = false
    private var manualOwner: UUID?
    private var waiters: [Waiter] = []

    // MARK: - 自动处理与人工编辑占用

    func run<T: Sendable>(owner: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner, savedRead: false)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    func beginManualEditing(owner: UUID) async throws {
        try Task.checkCancellation()
        if manualOwner == owner { return }
        try await acquire(owner: owner, savedRead: false, manualRequest: true)
        defer { release() }
        try Task.checkCancellation()
        manualOwner = owner
    }
    func endManualEditing(owner: UUID) async {
        guard manualOwner == owner else { return }
        manualOwner = nil
        drain()
    }
    /// 人工编辑仍占用 Photoshop 时，允许同一任务刷新检查已经保存的文件。
    func readSaved<T: Sendable>(owner: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner, savedRead: true)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    // MARK: - 等待、取消与唤醒

    private func acquire(owner: UUID, savedRead: Bool, manualRequest: Bool = false) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, owner: owner, savedRead: savedRead, manualRequest: manualRequest, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
    private func release() { busy = false; drain() }
    private func drain() {
        guard !busy else { return }
        let index: Int?
        // 人工编辑期间只放行占用者的读取或再次申请；空闲时优先响应人工编辑请求。
        if let owner = manualOwner {
            index = waiters.firstIndex { ($0.savedRead || $0.manualRequest) && $0.owner == owner }
        } else { index = waiters.firstIndex(where: \.manualRequest) ?? waiters.indices.first }
        guard let index else { return }
        busy = true
        waiters.remove(at: index).continuation.resume()
    }
}
