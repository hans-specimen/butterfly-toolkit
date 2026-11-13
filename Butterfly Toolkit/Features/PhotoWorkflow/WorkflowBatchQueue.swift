// 保存批次队列的顺序和继续标志；每批处理进度仍来自其原有清单。
import Foundation

nonisolated struct WorkflowQueuedBatch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let manifest: URL
    let title: String

    init(batch: WorkflowBatch, manifest: URL) {
        id = batch.id
        self.manifest = manifest
        title = batch.sourceDirectoryName
    }
}

nonisolated struct WorkflowBatchQueue: Codable, Equatable, Sendable {
    var entries: [WorkflowQueuedBatch] = []
    var interrupted = false

    static func load(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
