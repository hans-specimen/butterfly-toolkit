// 只授权当前存储根内单批次的 .work 清理，拒绝链接与任何用户文件目录重叠。
import Foundation

nonisolated enum WorkflowIntermediateCleanup {
    static var storageRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butterfly Toolkit/PhotoWorkflow", isDirectory: true)
    }

    // MARK: - 删除边界
    static func directory(batch: WorkflowBatch, manifest: URL, storageRoot: URL) throws -> URL {
        let files = FileManager.default
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        let output = batch.outputDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard UUID(uuidString: output.lastPathComponent) != nil,
              output.deletingLastPathComponent().path == root.path,
              (try? files.destinationOfSymbolicLink(atPath: batch.outputDirectory.path)) == nil,
              manifest.standardizedFileURL == batch.outputDirectory.appendingPathComponent("batch.json").standardizedFileURL,
              manifest.resolvingSymlinksInPath().standardizedFileURL == output.appendingPathComponent("batch.json") else {
            throw WorkflowStateError.invalidManifest("中转清理路径不属于当前应用的批次存储目录，已保留文件")
        }
        let work = output.appendingPathComponent(".work", isDirectory: true)
        guard (try? files.destinationOfSymbolicLink(atPath: work.path)) == nil,
              work.resolvingSymlinksInPath().standardizedFileURL == work.standardizedFileURL else {
            throw WorkflowStateError.invalidManifest("中转目录包含链接，已保留文件")
        }
        if files.fileExists(atPath: work.path) {
            guard try files.attributesOfItem(atPath: work.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw WorkflowStateError.invalidManifest("中转路径不是目录，已保留文件")
            }
        }
        var protected = [batch.sourceDirectory, batch.generatedPSDDirectory, manifest, manifest.appendingPathExtension("previous")]
        // 导出根可以是安全祖先；只禁止落在中转目录内，实际成品和凭据另逐项保护。
        for export in [batch.exportDirectory(for: .hd), batch.exportDirectory(for: .png4k)].compactMap({ $0 }) {
            let path = export.resolvingSymlinksInPath().standardizedFileURL
            guard path != work, !WorkflowBatch.isContained(path, in: work) else {
                throw WorkflowStateError.invalidManifest("导出位置位于中转目录内，已保留文件")
            }
        }
        for task in batch.sideTasks {
            protected += task.sources.files.map(\.url)
            protected += [task.stackAttemptURL, task.snapshot?.workingURL, task.acceptedFinalPSD?.workingURL].compactMap { $0 }
            let working = [task.stackAttemptURL, task.snapshot?.workingURL, task.acceptedFinalPSD?.workingURL].compactMap { $0 }
            protected += working.map { $0.appendingPathExtension("workflow-owner.json") }
            protected += task.artifacts.map(\.url)
            protected += task.artifacts.map { $0.url.deletingLastPathComponent().appendingPathComponent(".\($0.url.lastPathComponent).workflow.json") }
        }
        for url in protected {
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            guard path != work, !WorkflowBatch.isContained(path, in: work), !WorkflowBatch.isContained(work, in: path) else {
                throw WorkflowStateError.invalidManifest("中转目录与原图、工作 PSD 或成品位置重叠，已保留文件")
            }
        }
        return work
    }
}
