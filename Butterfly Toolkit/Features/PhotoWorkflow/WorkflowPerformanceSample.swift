// 定义工作流耗时样本与可跨并发边界传递的观察回调，供各处理服务按需记录性能。

import Foundation

// MARK: - 性能采样数据
// taskID 为空时表示批次级操作；耗时以秒记录，观察者自行决定采集与保存方式。
nonisolated struct WorkflowPerformanceSample: Codable, Sendable {
    let taskID: UUID?
    let operation: String
    let seconds: Double
}

typealias WorkflowPerformanceObserver = @Sendable (WorkflowPerformanceSample) -> Void
