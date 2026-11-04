import Foundation
import Darwin
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

nonisolated enum WorkflowArtifactError: Error, Equatable {
    case ownershipConflict, invalidImage, fingerprintMismatch, invalidArtifact
}

/// The receipt is written before the image, independently of batch.json. Never infer ownership from a name.
/// Sync operations belong on the workflow's background worker. A process-wide lock serializes publishers.
nonisolated struct WorkflowArtifactStore: Sendable {
    private static let lock = NSLock()
    private struct Receipt: Codable {
        var committed: WorkflowArtifact?
        var pending: WorkflowArtifact?
    }

    func publish(temp: URL, artifact: WorkflowArtifact) throws -> WorkflowArtifact {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try validateMetadata(artifact)
        guard temp.standardizedFileURL != artifact.url.standardizedFileURL else { throw WorkflowArtifactError.invalidArtifact }
        var receipt = try readReceipt(artifact.url)
        let original = try existingArtifact(at: artifact.url,receipt: receipt)
        if let existing = original {
            guard existing.ownerTaskID == artifact.ownerTaskID, existing.kind == artifact.kind else { throw WorkflowArtifactError.ownershipConflict }
        }
        try validateImage(temp,kind: artifact.kind)
        let hash = try AIFileValidation.hash(temp.path)
        guard artifact.fileFingerprint.isEmpty || artifact.fileFingerprint == hash else { throw WorkflowArtifactError.fingerprintMismatch }
        var result = artifact; result.fileFingerprint = hash; result.state = .completed
        let fm = FileManager.default
        try fm.createDirectory(at: artifact.url.deletingLastPathComponent(),withIntermediateDirectories: true)
        // Stage and fully verify on the destination filesystem before touching an older valid output.
        let sibling = artifact.url.deletingLastPathComponent().appendingPathComponent(".publish-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: sibling) }
        try fm.copyItem(at: temp,to: sibling)
        try validateImage(sibling,kind: result.kind)
        guard try AIFileValidation.hash(sibling.path) == hash else { throw WorkflowArtifactError.fingerprintMismatch }
        let current = try existingArtifact(at: artifact.url,receipt: receipt)
        guard current?.fileFingerprint == original?.fileFingerprint,current?.ownerTaskID == original?.ownerTaskID,
              current?.kind == original?.kind else { throw WorkflowArtifactError.ownershipConflict }
        if let previous = original {
            // Legacy pending receipts may describe the same bytes under a newer recipe.
            try preserveCommittedRecipe(receipt,matching: previous)
            try archive(previous)
        }
        // Preserve all prior recipes BEFORE exposing pending: equal hashes cannot identify the recipe.
        receipt.committed = original
        receipt.pending = result
        try save(receipt,at: artifact.url)
        if original != nil {
            // Atomic replacement after a verified, retained copy. The current file never disappears.
            guard rename(sibling.path,artifact.url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else {
            // A first publication refuses any collision rather than replacing it.
            try fm.moveItem(at: sibling,to: result.url)
        }
        receipt.committed = result; receipt.pending = nil
        try save(receipt,at: artifact.url)
        // Caller owns temporary files and may retain them for retry; do not remove them here.
        return result
    }

    /// nil means this recipe has no published file yet. A mismatched owner or changed bytes is an error.
    /// This also finalizes the pending receipt when a crash happened between image move and receipt/manifest save.
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

    private func preserveCommittedRecipe(_ receipt: Receipt,matching current: WorkflowArtifact) throws {
        guard let committed = receipt.committed else { return }
        guard committed.ownerTaskID == current.ownerTaskID,committed.kind == current.kind,
              committed.url.standardizedFileURL == current.url.standardizedFileURL else { throw WorkflowArtifactError.ownershipConflict }
        // Same bytes can represent two legitimate source/preset versions. Keep the old provenance, too.
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
    private func validateImage(_ url: URL,kind: WorkflowAssetKind) throws {
        try rejectSymlink(url)
        let raster = try WorkflowRaster.read(url)
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
