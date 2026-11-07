import Foundation

nonisolated struct WorkflowPerformanceSample: Codable, Sendable {
    let taskID: UUID?
    let operation: String
    let seconds: Double
}

typealias WorkflowPerformanceObserver = @Sendable (WorkflowPerformanceSample) -> Void
