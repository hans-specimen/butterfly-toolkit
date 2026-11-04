import Foundation

actor WorkflowBatchStore {
    func load(from url: URL) throws -> WorkflowBatch {
        if let batch = try? readValidBatch(from: url) { return try recoverInterruptedWork(batch) }
        if let batch = try? readValidBatch(from: url.appendingPathExtension("previous")) { return try recoverInterruptedWork(batch) }
        throw WorkflowStateError.invalidManifest("No valid batch manifest or previous manifest at \(url.path)")
    }

    func save(_ batch: WorkflowBatch, to url: URL) throws {
        try batch.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(batch)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
