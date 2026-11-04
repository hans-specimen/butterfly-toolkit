import Foundation

/// A lease remains held across suspension; actor reentrancy alone cannot serialize Photoshop.
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
    /// Refresh can inspect the saved file while its owner retains the manual reservation.
    func readSaved<T: Sendable>(owner: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner, savedRead: true)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
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
        if let owner = manualOwner {
            index = waiters.firstIndex { ($0.savedRead || $0.manualRequest) && $0.owner == owner }
        } else { index = waiters.firstIndex(where: \.manualRequest) ?? waiters.indices.first }
        guard let index else { return }
        busy = true
        waiters.remove(at: index).continuation.resume()
    }
}
