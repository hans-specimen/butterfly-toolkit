// 使用独立归属凭据发布和恢复导出图片，在校验内容后保留旧版本并原子替换产物。

import Foundation
import Darwin
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

nonisolated enum WorkflowArtifactError: Error, Equatable {
    case ownershipConflict, invalidImage, fingerprintMismatch, invalidArtifact
}

/// 归属凭据独立于 batch.json，先于图片写入；不能仅凭文件名推断归属。
/// 同步操作由工作流后台执行，进程级锁串行化发布者。
nonisolated struct WorkflowArtifactStore: Sendable {
    typealias Read = @Sendable (URL) throws -> WorkflowRaster
    typealias Copy = @Sendable (URL,URL) throws -> Void
    private let read: Read
    private let copy: Copy
    init(read: @escaping Read = WorkflowRaster.read,
         copy: @escaping Copy = { try FileManager.default.copyItem(at: $0,to: $1) }) {
        self.read = read; self.copy = copy
    }
    private static let lock = NSLock()
    private struct Receipt: Codable {
        var committed: WorkflowArtifact?
        var pending: WorkflowArtifact?
    }

    /// 校验证据仅属于本次发布调用及这些确切的候选字节。
    private struct ValidatedCandidate {
        let fingerprint: String
    }
    private func validateCandidate(_ url: URL,kind: WorkflowAssetKind) throws -> ValidatedCandidate {
        try rejectSymlink(url)
        let before = try AIFileValidation.hash(url.path)
        try validateImage(url,kind: kind)
        guard try AIFileValidation.hash(url.path) == before else { throw WorkflowArtifactError.fingerprintMismatch }
        return ValidatedCandidate(fingerprint: before)
    }

    // MARK: - 发布与崩溃恢复
    func publish(temp: URL, artifact: WorkflowArtifact) throws -> WorkflowArtifact {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try validateMetadata(artifact)
        guard temp.standardizedFileURL != artifact.url.standardizedFileURL else { throw WorkflowArtifactError.invalidArtifact }
        var receipt = try readReceipt(artifact.url)
        let original = try existingArtifact(at: artifact.url,receipt: receipt)
        if let existing = original {
            guard existing.ownerTaskID == artifact.ownerTaskID, existing.kind == artifact.kind else { throw WorkflowArtifactError.ownershipConflict }
        }
        let validated = try validateCandidate(temp,kind: artifact.kind)
        let hash = validated.fingerprint
        guard artifact.fileFingerprint.isEmpty || artifact.fileFingerprint == hash else { throw WorkflowArtifactError.fingerprintMismatch }
        var result = artifact; result.fileFingerprint = hash; result.state = .completed
        let fm = FileManager.default
        try fm.createDirectory(at: artifact.url.deletingLastPathComponent(),withIntermediateDirectories: true)
        // 先将相同的已校验字节暂存到目标文件系统，再处理旧输出。
        let sibling = artifact.url.deletingLastPathComponent().appendingPathComponent(".publish-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sibling) }
        try copy(temp,sibling)
        try rejectSymlink(sibling)
        guard try AIFileValidation.hash(sibling.path) == hash else { throw WorkflowArtifactError.fingerprintMismatch }
        let current = try existingArtifact(at: artifact.url,receipt: receipt)
        guard current?.fileFingerprint == original?.fileFingerprint,current?.ownerTaskID == original?.ownerTaskID,
              current?.kind == original?.kind else { throw WorkflowArtifactError.ownershipConflict }
        if let previous = original {
            // 旧版待提交凭据可能以较新的配方描述相同字节。
            try preserveCommittedRecipe(receipt,matching: previous)
            try archive(previous)
        }
        // 暴露待提交记录前先保留全部旧配方，因为相同哈希无法区分配方。
        receipt.committed = original
        receipt.pending = result
        try save(receipt,at: artifact.url)
        if original != nil {
            // 旧文件校验并留存副本后再原子替换，避免当前文件短暂消失。
            guard rename(sibling.path,artifact.url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            // 首次发布拒绝任何同名冲突，避免替换已有文件。
            try fm.moveItem(at: sibling,to: result.url)
        }
        receipt.committed = result; receipt.pending = nil
        try save(receipt,at: artifact.url)
        // 临时文件由调用方管理，可能保留用于重试，因此这里不删除。
        return result
    }

    /// nil 表示该配方尚无已发布文件；归属不匹配或内容变化则报错。
    /// 若图片已移动，但凭据或清单尚未保存时崩溃，此处也会完成待提交凭据。
    func recover(artifact: WorkflowArtifact) throws -> WorkflowArtifact? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try validateMetadata(artifact)
        var receipt = try readReceipt(artifact.url)
        guard let existing = try existingArtifact(at: artifact.url,receipt: receipt) else { return nil }
        guard existing.ownerTaskID == artifact.ownerTaskID,existing.kind == artifact.kind else { throw WorkflowArtifactError.ownershipConflict }
        guard sameRecipe(existing,artifact) else { return nil }
        guard artifact.fileFingerprint.isEmpty || artifact.fileFingerprint == existing.fileFingerprint else { throw WorkflowArtifactError.fingerprintMismatch }
        try preserveCommittedRecipe(receipt,matching: existing)
        receipt.committed = existing; receipt.pending = nil
        try save(receipt,at: artifact.url)
        return existing
    }

    // MARK: - 归属凭据与历史保留
    private func preserveCommittedRecipe(_ receipt: Receipt,matching current: WorkflowArtifact) throws {
        guard let committed = receipt.committed else { return }
        guard committed.ownerTaskID == current.ownerTaskID,committed.kind == current.kind,
              committed.url.standardizedFileURL == current.url.standardizedFileURL else { throw WorkflowArtifactError.ownershipConflict }
        // 相同字节可能对应两个有效的源或预设版本，因此也要保留旧的来源记录。
        if committed != current,committed.fileFingerprint == current.fileFingerprint { try archive(committed) }
    }
    private func archive(_ previous: WorkflowArtifact) throws {
        try validateMetadata(previous)
        guard try AIFileValidation.hash(previous.url.path) == previous.fileFingerprint else { throw WorkflowArtifactError.fingerprintMismatch }
        let history = previous.url.deletingLastPathComponent().appendingPathComponent(".workflow-history",isDirectory: true)
            .appendingPathComponent(UUID().uuidString,isDirectory: true)
        try rejectSymlink(history.deletingLastPathComponent())
        let fm = FileManager.default
        try fm.createDirectory(at: history,withIntermediateDirectories: true)
        let retained = history.appendingPathComponent(previous.url.lastPathComponent)
        try fm.copyItem(at: previous.url,to: retained)
        guard try AIFileValidation.hash(retained.path) == previous.fileFingerprint else { throw WorkflowArtifactError.fingerprintMismatch }
        try JSONEncoder().encode(previous).write(to: history.appendingPathComponent("artifact.json"),options: .atomic)
    }
    private func existingArtifact(at url: URL,receipt: Receipt) throws -> WorkflowArtifact? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try rejectSymlink(url)
        let hash = try AIFileValidation.hash(url.path)
        guard let match = [receipt.pending,receipt.committed].compactMap({ $0 }).first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL && $0.fileFingerprint == hash && !$0.fileFingerprint.isEmpty
        }) else { throw WorkflowArtifactError.ownershipConflict }
        try validateImage(url,kind: match.kind)
        return match
    }
    private func sameRecipe(_ a: WorkflowArtifact,_ b: WorkflowArtifact) -> Bool {
        a.ownerTaskID == b.ownerTaskID && a.kind == b.kind && a.url.standardizedFileURL == b.url.standardizedFileURL &&
            a.sourceFingerprint == b.sourceFingerprint && a.presetFingerprint == b.presetFingerprint
    }
    private func validateMetadata(_ a: WorkflowArtifact) throws {
        guard a.url.isFileURL,!a.sourceFingerprint.isEmpty,!a.presetFingerprint.isEmpty else { throw WorkflowArtifactError.invalidArtifact }
        let expected = a.kind == .hd ? ["jpg","jpeg"] : ["png"]
        guard expected.contains(a.url.pathExtension.lowercased()) else { throw WorkflowArtifactError.invalidArtifact }
    }
    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw WorkflowArtifactError.ownershipConflict }
    }
    private func receiptURL(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).workflow.json") }
    private func readReceipt(_ url: URL) throws -> Receipt {
        let path = receiptURL(url); try rejectSymlink(path)
        guard FileManager.default.fileExists(atPath: path.path) else { return Receipt() }
        guard let decoded = try? JSONDecoder().decode(Receipt.self,from: Data(contentsOf: path)) else { throw WorkflowArtifactError.ownershipConflict }
        return decoded
    }
    private func save(_ receipt: Receipt,at url: URL) throws {
        try rejectSymlink(receiptURL(url))
        try JSONEncoder().encode(receipt).write(to: receiptURL(url),options: .atomic)
    }
    // MARK: - 文件格式与像素检查
    private func validateImage(_ url: URL,kind: WorkflowAssetKind) throws {
        try rejectSymlink(url)
        let raster = try read(url)
        guard raster.orientation == 1,let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let type = CGImageSourceGetType(source),
              (type as String) == (kind == .hd ? UTType.jpeg.identifier : UTType.png.identifier) else { throw WorkflowArtifactError.invalidImage }
        let side: Int?
        switch kind { case .png4k: side = 4096; case .white1k: side = 1000; case .xianyu: side = 2000; case .hd,.footage: side = nil }
        if let side, raster.size != CGSize(width: side,height: side) { throw WorkflowArtifactError.invalidImage }
        if kind == .png4k || kind == .footage {
            let alpha = stride(from: 3,to: raster.pixels.count,by: 4)
            guard alpha.contains(where: { raster.pixels[$0] > 0 }) else { throw WorkflowArtifactError.invalidImage }
        }
    }
}
