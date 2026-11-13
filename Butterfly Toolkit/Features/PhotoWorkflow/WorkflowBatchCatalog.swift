// 只读发现已保存批次，并将删除限制在应用管理的单批次记录与缓存目录。
import Darwin
import Foundation

actor WorkflowBatchCatalog {
    struct Record: Identifiable, Sendable {
        let id: URL
        let batchID: UUID?
        let title: String
        let sourceDirectory: URL?
        let specimenCount: Int
        let updatedAt: Date?
        let progress: String
        let hasPendingWork: Bool
        let canOpen: Bool
    }

    /// 单独解码路径与名称，便于识别模型已经不兼容的历史清单。
    private struct Metadata: Decodable {
        struct Specimen: Decodable {}

        let id: UUID
        let schemaVersion: Int
        let sourceDirectory: URL
        let sourceDirectoryName: String?
        let outputDirectory: URL
        let outputLocations: WorkflowOutputLocations?
        let specimens: [Specimen]?
    }

    private let root: URL
    private let files = FileManager.default
    private static let primaryName = "batch.json"

    init(storageRoot: URL = WorkflowIntermediateCleanup.storageRoot) {
        root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - 已保存批次
    func list() throws -> [Record] {
        try directories().compactMap { directory -> Record? in
            let manifest = directory.appendingPathComponent(Self.primaryName)
            guard !isSymbolicLink(manifest) else { return nil }
            let candidates = [manifest, manifest.appendingPathExtension("previous")].filter { isRegularFile($0) }
            guard !candidates.isEmpty else { return nil }

            var draft: Record?
            for url in candidates {
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { continue }
                let current = metadata.schemaVersion == WorkflowBatch.currentSchemaVersion
                let batch = current ? try? validatedBatch(data, manifest: manifest) : nil
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let summary = batch.map(Self.progress)
                let record = Record(id: manifest, batchID: metadata.id,
                    title: metadata.sourceDirectoryName ?? metadata.sourceDirectory.lastPathComponent,
                    sourceDirectory: metadata.sourceDirectory, specimenCount: metadata.specimens?.count ?? 0,
                    updatedAt: modified, progress: summary?.label ?? (current ? "清单无法读取" : "旧版清单"),
                    hasPendingWork: summary?.pending ?? false, canOpen: batch != nil)
                if !current || batch != nil { return record }
                draft = record
            }
            return draft ?? Record(id: manifest, batchID: nil, title: "无法读取的批次",
                sourceDirectory: nil, specimenCount: 0,
                updatedAt: try? candidates[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                progress: "清单无法读取", hasPendingWork: false, canOpen: false)
        }.sorted {
            if $0.hasPendingWork != $1.hasPendingWork { return $0.hasPendingWork }
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id.path < $1.id.path
        }
    }

    private func validatedBatch(_ data: Data, manifest: URL) throws -> WorkflowBatch {
        let batch = try JSONDecoder().decode(WorkflowBatch.self, from: data)
        try batch.validate()
        try batch.validateOutputURL(manifest)
        return batch
    }

    private static func progress(_ batch: WorkflowBatch) -> (label: String, pending: Bool) {
        let tasks = batch.activeTasks.filter { $0[.geometry].state != .excluded }
        guard !tasks.isEmpty else { return ("已全部排除", false) }
        let exportStages: [WorkflowStage] = [.hd, .png4k]
        var preparing = 0, review = 0, waitingExport = 0, exported = 0, failed = 0
        for task in tasks {
            let stages = [WorkflowStage.stack, .matte, .geometry] + exportStages
            if stages.contains(where: { task[$0].state == .failed }) { failed += 1 }
            else if task[.geometry].state == .waitingReview { review += 1 }
            else if task[.geometry].state != .completed { preparing += 1 }
            else if !(task.requestedExports ?? [:]).isEmpty { waitingExport += 1 }
            else if exportStages.contains(where: { task[$0].state == .completed }) { exported += 1 }
            else { waitingExport += 1 }
        }
        let parts = [(review, "待检查"), (waitingExport, "待导出"), (preparing, "待准备"),
                     (failed, "待重试"), (exported, "已导出")]
        return (parts.compactMap { count, label in count > 0 ? "\(count) 面\(label)" : nil }.joined(separator: " · "),
                exported < tasks.count)
    }

    // MARK: - 批次删除
    func delete(_ record: Record, protecting otherOpenBatches: [WorkflowBatch] = []) throws {
        let directory = record.id.deletingLastPathComponent()
        guard let expectedID = record.batchID,
              record.id.lastPathComponent == Self.primaryName,
              isPlainDirectory(directory),
              directory.deletingLastPathComponent().path == root.path,
              UUID(uuidString: directory.lastPathComponent) != nil else { throw unsafeDirectory }

        let work = directory.appendingPathComponent(".work", isDirectory: true)
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let hasWork = entries.contains { $0.lastPathComponent == ".work" }
        guard !hasWork || isPlainDirectory(work) else { throw unsafeDirectory }
        let primaryNames = [Self.primaryName, Self.primaryName + ".previous"]
        var hasPrimary = false
        var removing = [URL]()

        for entry in entries where isManifestName(entry.lastPathComponent) {
            let primary = primaryNames.contains(entry.lastPathComponent)
            if primary && !isRegularFile(entry) { throw unsafeDirectory }
            guard isRegularFile(entry) else { continue }
            guard let data = try? Data(contentsOf: entry),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
                if primary { removing.append(entry) }
                continue
            }
            if metadata.id == expectedID, samePath(metadata.outputDirectory, directory) {
                try protect([metadata.sourceDirectory], from: [directory])
                hasPrimary = hasPrimary || primary
                removing.append(entry)
            } else if primary || samePath(metadata.outputDirectory, directory) {
                throw unsafeDirectory
            }
        }
        guard hasPrimary else { throw unsafeDirectory }
        let targets = [work] + removing

        // 导出位置可自选，目录也可能存有旧版工作 PSD。只移除已知清单和批次缓存。
        for sibling in try directories() {
            let manifests = try files.contentsOfDirectory(at: sibling, includingPropertiesForKeys: nil)
            for url in manifests where isManifestName(url.lastPathComponent) && isRegularFile(url) {
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { continue }
                if !removing.contains(url), samePath(metadata.outputDirectory, directory) { throw unsafeDirectory }
                try protect([metadata.sourceDirectory] + [metadata.outputLocations?.hd, metadata.outputLocations?.png4k].compactMap { $0 },
                            from: targets)
                if let batch = try? JSONDecoder().decode(WorkflowBatch.self, from: data) {
                    try protect(protectedFiles(in: batch), from: targets)
                }
            }
        }
        for batch in otherOpenBatches {
            try protect([batch.sourceDirectory] + [batch.exportDirectory(for: .hd), batch.exportDirectory(for: .png4k)].compactMap { $0 }
                        + protectedFiles(in: batch), from: targets)
        }

        // 先清缓存，失败时保留主清单供用户重试。历史目录中的 PSD 和成品继续保留。
        if hasWork { try files.removeItem(at: work) }
        for url in removing where !primaryNames.contains(url.lastPathComponent) { try files.removeItem(at: url) }
        if let previous = removing.first(where: { $0.lastPathComponent == Self.primaryName + ".previous" }) {
            try files.removeItem(at: previous)
        }
        if let primary = removing.first(where: { $0.lastPathComponent == Self.primaryName }) {
            try files.removeItem(at: primary)
        }
        // rmdir 只移除空目录，保留任何未纳入清理的文件。
        _ = rmdir(directory.path)
    }

    private func protectedFiles(in batch: WorkflowBatch) -> [URL] {
        var urls = [batch.generatedPSDDirectory]
        for task in batch.sideTasks {
            urls += task.sources.files.map(\.url)
            urls += [task.stackAttemptURL, task.snapshot?.workingURL, task.acceptedFinalPSD?.workingURL].compactMap { $0 }
            urls += task.artifacts.map(\.url)
            urls += task.requestedExports?.values.map(\.directory) ?? []
        }
        return urls
    }

    private func protect(_ paths: [URL], from targets: [URL]) throws {
        for url in paths {
            guard url.isFileURL else { throw unsafeDirectory }
            let original = url.standardizedFileURL.pathComponents
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            for target in targets {
                guard original != target.pathComponents, resolved.path != target.path,
                      !original.starts(with: target.pathComponents), !target.pathComponents.starts(with: original),
                      !WorkflowBatch.isContained(url, in: target), !WorkflowBatch.isContained(target, in: url) else {
                    throw unsafeDirectory
                }
            }
        }
    }

    // MARK: - 存储边界
    private var unsafeDirectory: WorkflowStateError {
        .invalidManifest("该批次包含无法确认归属的文件或路径，已保留文件")
    }

    private func directories() throws -> [URL] {
        do {
            return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .filter { UUID(uuidString: $0.lastPathComponent) != nil && isPlainDirectory($0) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink == false
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink == false
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.isFileURL && rhs.isFileURL && lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func isManifestName(_ name: String) -> Bool {
        let base = name.hasSuffix(".previous") ? String(name.dropLast(".previous".count)) : name
        return base == Self.primaryName || (base.hasPrefix("batch-") && base.hasSuffix(".json"))
    }
}
