// 负责批次清单的校验、原子保存、上一版回退，以及中断后运行状态的恢复。

import Foundation

actor WorkflowBatchStore {
    private let performanceObserver: WorkflowPerformanceObserver?
    init(performanceObserver: WorkflowPerformanceObserver? = nil) { self.performanceObserver = performanceObserver }

    // MARK: - 清单读写
    // 当前清单不可用时尝试上一份已校验清单，避免将损坏内容作为恢复依据。
    func load(from url: URL) throws -> WorkflowBatch {
        if let data = try? Data(contentsOf: url),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = metadata["schemaVersion"] as? Int, version != 2 {
            throw WorkflowStateError.invalidManifest("此批次使用旧流程，请新建批次；旧文件未作修改")
        }
        if let batch = try? readValidBatch(from: url) { return try recoverInterruptedWork(batch) }
        if let batch = try? readValidBatch(from: url.appendingPathExtension("previous")) { return try recoverInterruptedWork(batch) }
        throw WorkflowStateError.invalidManifest("No valid batch manifest or previous manifest at \(url.path)")
    }

    func save(_ batch: WorkflowBatch, to url: URL) throws {
        let started = performanceObserver == nil ? nil : ProcessInfo.processInfo.systemUptime
        defer {
            if let started { performanceObserver?(WorkflowPerformanceSample(taskID: nil, operation: "manifest.save", seconds: ProcessInfo.processInfo.systemUptime - started)) }
        }
        try batch.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(batch)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 仅用有效的旧清单更新恢复副本；当前文件损坏且没有有效备份时拒绝覆盖。
        let previous = url.appendingPathExtension("previous")
        if manager.fileExists(atPath: url.path) {
            if let existing = try? Data(contentsOf: url), (try? decodeValid(existing)) != nil {
                try existing.write(to: previous, options: .atomic)
            } else if (try? readValidBatch(from: previous)) == nil {
                throw WorkflowStateError.invalidManifest("Refusing to replace a corrupt manifest without a valid recovery copy")
            }
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 中断恢复与有效性检查
    // 磁盘上的 running 不能证明进程仍在运行，恢复时退回待处理并递增修订号。
    private func recoverInterruptedWork(_ batch: WorkflowBatch) throws -> WorkflowBatch {
        guard batch.activeTasks.contains(where: { task in task.records.values.contains { $0.state == .running } }) else { return batch }
        return try WorkflowStateMachine.reduce(batch: batch, event: .cancelRunning(expectedRevision: batch.revision))
    }

    private func readValidBatch(from url: URL) throws -> WorkflowBatch {
        try decodeValid(Data(contentsOf: url))
    }

    private func decodeValid(_ data: Data) throws -> WorkflowBatch {
        let batch = try JSONDecoder().decode(WorkflowBatch.self, from: data)
        try batch.validate()
        return batch
    }
}
