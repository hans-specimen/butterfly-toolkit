// 桥接 Photoshop 堆栈、蒙版回写、角色提取与几何操作，维护文档归属、不可变快照和中断恢复。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct WorkflowStackPreparation: Sendable {
    let snapshot: PSDSnapshot
    let input: StackPNG?
}

nonisolated enum PhotoshopInstallCheckpoint: Sendable { case prepared, published }

nonisolated struct PhotoshopWorkflowBridge: Sendable {
    typealias ScriptRunner = @Sendable (String) async throws -> String
    typealias StackProcessor = @Sendable (FocusStackJob, String?) async throws -> Void
    private struct OpenedWorkflowDocument: Sendable {
        let documentID: Int
        let url: URL
        let token: String
    }
    @TaskLocal private static var openedDocument: OpenedWorkflowDocument?
    private let reuseDocumentsWithinOperation: Bool
    private let stackProcessor: StackProcessor
    let workspace: URL
    private let coordinator: PhotoshopExecutionCoordinator
    private let scriptRunner: ScriptRunner
    private let installCheckpoint: @Sendable (PhotoshopInstallCheckpoint) async throws -> Void
    @TaskLocal private static var performanceTaskID: UUID?
    private let performanceObserver: WorkflowPerformanceObserver?
    init(workspace: URL, coordinator: PhotoshopExecutionCoordinator = .shared, scriptRunner: @escaping ScriptRunner = { try await Self.execute($0) }, installCheckpoint: @escaping @Sendable (PhotoshopInstallCheckpoint) async throws -> Void = { _ in }, performanceObserver: WorkflowPerformanceObserver? = nil, reuseDocumentsWithinOperation: Bool = false, stackProcessor: @escaping StackProcessor = { job, hook in
        guard let application = FocusStackProcessor.photoshopApplicationName() else { throw FocusStackError.photoshopNotFound }
        try await Task.detached(priority: .userInitiated) {
            try FocusStackProcessor.process(job, photoshopApplicationName: application, workflowPNGExportScript: hook)
        }.value
    }) {
        self.workspace = workspace; self.coordinator = coordinator; self.scriptRunner = scriptRunner; self.installCheckpoint = installCheckpoint; self.performanceObserver = performanceObserver; self.stackProcessor = stackProcessor; self.reuseDocumentsWithinOperation = reuseDocumentsWithinOperation
    }
    // MARK: - 持久归属与服务元数据
    private struct InstallTransaction: Codable, Sendable {
        var sourceVersion: String
        var result: PSDSnapshot
        var matte: MatteArtifact?
        var photoshopSelection: Bool?
    }
    private struct SubjectPublication: Codable, Sendable {
        var sourceVersion: String
        var resultVersion: String
    }
    private struct Ownership: Codable, Sendable {
        var owner: UUID
        var roles: PSDRoleIdentifiers?
        var sources: [WorkflowSourceFile]?
        var initialStackVersion: String?
        var pendingInstall: InstallTransaction?
        var subjectPublication: SubjectPublication?
    }
    private struct RoleCache: Codable {
        var snapshot: PSDSnapshot
        var images: RoleImages
        var fingerprints: [String]
    }
    private struct Metadata: Decodable, Sendable {
        var width: Double
        var height: Double
        var profile: String
        var roles: PSDRoleIdentifiers?
        var finalRoles: FinalPSDIdentifiers?
        var summary: String
        var originX: Double?
        var originY: Double?
        var extentWidth: Double?
        var extentHeight: Double?
        var documentID: Int?
        var wasOpen: Bool?
        var performance: [String: Double]?
        var documentPeak: Int?
    }
    // MARK: - 堆栈创建与保存输入
    func adoptStack(source: WorkflowSourceFile, owner: UUID) async throws -> PSDSnapshot {
        try await withLease("adoptStack", owner: owner, savedRead: false) {
            let document = source.url.resolvingSymlinksInPath(), record = ownershipURL(document)
            guard document.pathExtension.lowercased() == "psd", !source.fingerprint.isEmpty else { throw WorkflowBridgeError.invalidStructure }
            let canonical = WorkflowSourceFile(url: document,fingerprint: source.fingerprint)
            if FileManager.default.fileExists(atPath: record.path) {
                let ownership = try JSONDecoder().decode(Ownership.self,from: Data(contentsOf: record))
                guard ownership.owner == owner,ownership.sources == [canonical],ownership.initialStackVersion == source.fingerprint else {
                    throw WorkflowBridgeError.ownershipConflict
                }
            }
            guard try hash(document.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
            // 接管前先检查用户的未保存修改和既有角色；不保存、关闭或重建用户文档。
            let metadata = try await invoke(Self.inspectScript(document: document))
            guard metadata.roles == nil,metadata.width > 0,metadata.height > 0 else { throw WorkflowBridgeError.invalidStructure }
            guard try hash(document.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
            if !FileManager.default.fileExists(atPath: record.path) {
                let ownership = Ownership(owner: owner,sources: [canonical],initialStackVersion: source.fingerprint)
                try JSONEncoder().encode(ownership).write(to: record,options: .withoutOverwriting)
            }
            // 首次回写前保留不可变原始 PSD；中断重试复用同一 owner 和保存版本。
            let snapshot = try await capture(document: document,owner: owner)
            guard snapshot.contentVersion == source.fingerprint else { throw WorkflowBridgeError.staleSource }
            return snapshot
        }
    }
    func stackWithInput(job: FocusStackJob, owner: UUID) async throws -> WorkflowStackPreparation {
        try await prepareStack(job: job, owner: owner, prepareInput: true)
    }
    func stack(job: FocusStackJob, owner: UUID) async throws -> PSDSnapshot {
        try await prepareStack(job: job, owner: owner, prepareInput: false).snapshot
    }
    private func prepareStack(job: FocusStackJob, owner: UUID, prepareInput: Bool) async throws -> WorkflowStackPreparation {
        try await withLease("stack", owner: owner, savedRead: false) {
            guard !FileManager.default.fileExists(atPath: job.destinationURL.path),
                  !FileManager.default.fileExists(atPath: ownershipURL(job.destinationURL).path), job.sourceFiles.count == 3 else {
                throw WorkflowBridgeError.ownershipConflict
            }
            let folder = try outputDirectory("stack/\(UUID())", owner: owner)
            let hashes = try job.sourceFiles.map { try hash($0.path) }
            var copiedSources: [URL] = []
            for (index, source) in job.sourceFiles.enumerated() {
                let copy = folder.appendingPathComponent("sources/\(index)/\(source.lastPathComponent)")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try self.copy(at: source, to: copy)
                guard try hash(copy.path) == hashes[index] else { throw WorkflowBridgeError.staleSource }
                copiedSources.append(copy)
            }
            let candidate = folder.appendingPathComponent("input.png")
            defer { try? FileManager.default.removeItem(at: candidate) }
            let hook = prepareInput ? Self.stackInputExportScript(output: candidate) : nil
            let staged = folder.appendingPathComponent("stack.psd")
            let ownedJob = FocusStackJob(id: job.id, sourceFiles: copiedSources, destinationURL: staged, butterflyName: job.butterflyName, side: job.side)
            let stackStarted = observationStart()
            do {
                defer { report("ps.stack-including-open-save-close", since: stackStarted) }
                try await stackProcessor(ownedJob, hook)
            }
            guard try job.sourceFiles.map({ try hash($0.path) }) == hashes else { throw WorkflowBridgeError.staleSource }
            // 移动操作拒绝后出现的同名冲突，不能借旧处理器的跳过行为接管归属未知的 PSD。
            let record = ownershipURL(job.destinationURL)
            try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sources = zip(job.sourceFiles, hashes).map { WorkflowSourceFile(url: $0.0.resolvingSymlinksInPath(), fingerprint: $0.1) }
            let ownership = try Ownership(owner: owner, sources: sources, initialStackVersion: hash(staged.path))
            try JSONEncoder().encode(ownership).write(to: record, options: .withoutOverwriting)
            do { try FileManager.default.moveItem(at: staged, to: job.destinationURL) }
            catch { try? FileManager.default.removeItem(at: record); throw error }
            let snapshot = try await capture(document: job.destinationURL, owner: owner)
            // 可选输入准备失败不能使已发布且可恢复的 PSD 失效。
            var input: StackPNG?
            if prepareInput, snapshot.contentVersion == ownership.initialStackVersion {
                input = try? preparedInput(candidate, snapshot: snapshot)
            }
            return WorkflowStackPreparation(snapshot: snapshot, input: input)
        }
    }
    private func preparedInput(_ candidate: URL, snapshot: PSDSnapshot) throws -> StackPNG {
        let raster = try readRaster(candidate)
        guard raster.size == snapshot.pixelSize, raster.orientation == 1, raster.hasProfile else {
            throw WorkflowBridgeError.invalidImage("预备 PNG 尺寸、方向或 ICC 缺失")
        }
        // PSD 序列化可能改变 alpha 为零处的隐藏 RGB，因此透明输入仍需重新打开 PSD 后导出。
        guard stride(from: 3, to: raster.pixels.count, by: 4).allSatisfy({ raster.pixels[$0] == 255 }) else {
            throw WorkflowBridgeError.invalidImage("透明输入保留重新打开 PSD 导出路径")
        }
        let fingerprint = try hash(candidate.path)
        let output = try outputDirectory("data/processed", owner: snapshot.taskID)
            .appendingPathComponent("\(snapshot.contentVersion)-\(UUID()).png")
        try FileManager.default.moveItem(at: candidate, to: output)
        return StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: output, fingerprint: fingerprint,
            pixelSize: raster.size, orientation: 1, colorProfile: raster.profileName ?? "", validBackgroundAlphaURL: output)
    }
    func refreshSavedPSD(document: URL, owner: UUID, expectedSources: [WorkflowSourceFile]? = nil) async throws -> PSDSnapshot {
        try await withLease("refresh", owner: owner, savedRead: true) {
            if FileManager.default.fileExists(atPath: ownershipURL(document).path) {
                _ = try await recoverInstall(document: document, owner: owner, allowPublication: false)
            }
            if let expectedSources {
                let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(document)))
                let canonical = expectedSources.map { WorkflowSourceFile(url: $0.url.resolvingSymlinksInPath(), fingerprint: $0.fingerprint) }
                guard canonical.count == 3, ownership.owner == owner, ownership.sources == canonical, ownership.roles == nil,
                      try hash(document.path) == ownership.initialStackVersion else { throw WorkflowBridgeError.staleSource }
                for source in canonical {
                    guard try hash(source.url.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                }
            }
            let snapshot = try await capture(document: document, owner: owner)
            if snapshot.roles != nil { _ = try await extractUnlocked(snapshot) }
            return snapshot
        }
    }
    func validateStackInput(snapshot: PSDSnapshot, input: StackPNG) async throws -> Bool {
        try await withLease("validateStackInput", owner: snapshot.taskID, savedRead: true) {
            // 即使复用输入，也保留重新打开并导出时应执行的源版本校验。
            try await verify(snapshot)
            guard input.snapshotVersion == snapshot.contentVersion, input.pixelSize == snapshot.pixelSize,
                  input.orientation == 1, !input.colorProfile.isEmpty,
                  (try? hash(input.pngURL.path)) == input.fingerprint,
                  let raster = try? readRaster(input.pngURL) else { return false }
            return raster.size == input.pixelSize && raster.orientation == 1 && raster.hasProfile
        }
    }
    func exportStackPNG(snapshot: PSDSnapshot) async throws -> StackPNG {
        try await withLease("exportStack", owner: snapshot.taskID, savedRead: false) {
            try await verify(snapshot)
            let output = try outputDirectory("data/processed", owner: snapshot.taskID).appendingPathComponent("\(snapshot.contentVersion)-\(UUID()).png")
            let metadata = try await invoke(Self.exportScript(document: snapshot.snapshotURL, output: output, roles: snapshot.roles))
            let raster = try readRaster(output)
            guard raster.size == snapshot.pixelSize, raster.orientation == 1, raster.hasProfile else {
                throw WorkflowBridgeError.invalidImage("堆栈 PNG 尺寸、方向或 ICC 缺失")
            }
            return try StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: output, fingerprint: hash(output.path),
                pixelSize: raster.size, orientation: raster.orientation, colorProfile: raster.profileName ?? metadata.profile, validBackgroundAlphaURL: output)
        }
    }
    // MARK: - 蒙版事务与发布恢复
    func installMatte(snapshot: PSDSnapshot, matte: MatteArtifact, createFinishedLayer: Bool = false) async throws -> PSDSnapshot {
        try await install(snapshot: snapshot, matte: matte, createFinishedLayer: createFinishedLayer)
    }
    func selectSubject(snapshot: PSDSnapshot) async throws -> PSDSnapshot {
        try await install(snapshot: snapshot, matte: nil, createFinishedLayer: false)
    }
    private func install(snapshot: PSDSnapshot, matte: MatteArtifact?, createFinishedLayer: Bool) async throws -> PSDSnapshot {
        try await withLease("install", owner: snapshot.taskID, savedRead: false) {
            let record = ownershipURL(snapshot.workingURL)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            if let pending = ownership.pendingInstall {
                guard ownership.owner == snapshot.taskID, pending.sourceVersion == snapshot.contentVersion,
                      pending.matte == matte, matte != nil || pending.photoshopSelection == true else { throw WorkflowBridgeError.staleSource }
                guard let saved = try await recoverInstall(document: snapshot.workingURL, owner: snapshot.taskID, allowPublication: true, captureResult: true) else { throw WorkflowBridgeError.invalidStructure }
                return saved
            }
            // PSD 发布成功后清单仍可能保留旧快照；只能复用此次发布的确切结果。
            if matte == nil, let published = ownership.subjectPublication {
                guard ownership.owner == snapshot.taskID, published.sourceVersion == snapshot.contentVersion,
                      try hash(snapshot.snapshotURL.path) == published.sourceVersion,
                      try hash(snapshot.workingURL.path) == published.resultVersion else { throw WorkflowBridgeError.staleSource }
                let saved = try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
                guard saved.contentVersion == published.resultVersion else { throw WorkflowBridgeError.staleSource }
                try await validateSubjectMask(saved)
                return saved
            }
            try await verify(snapshot)
            guard snapshot.roles == nil else { throw WorkflowBridgeError.invalidStructure }
            if let matte {
                guard matte.pixelSize == snapshot.pixelSize, matte.orientation == 1,
                      try hash(matte.alphaURL.path) == matte.alphaFingerprint,
                      try hash(matte.cutoutURL.path) == matte.cutoutFingerprint else { throw WorkflowBridgeError.staleSource }
                let inputDirectory = workspace.appendingPathComponent("data/processed/\(snapshot.taskID.uuidString)")
                let inputs = (try? FileManager.default.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil)) ?? []
                guard let inputURL = inputs.first(where: { $0.lastPathComponent.hasPrefix(snapshot.contentVersion) && (try? hash($0.path)) == matte.inputPNGFingerprint }) else {
                    throw WorkflowBridgeError.staleSource
                }
                try measure("pixel.validateMatte-including-read") {
                    try WorkflowRaster.validateMatte(original: WorkflowRaster.readMatteInput(inputURL), alpha: readRaster(matte.alphaURL), cutout: readRaster(matte.cutoutURL))
                }
            }
            // 先在独立副本中准备并校验，失败时不会改变工作 PSD 及其归属。
            let staged = try outputDirectory("install/\(UUID())", owner: snapshot.taskID).appendingPathComponent("result.psd")
            try self.copy(at: snapshot.snapshotURL, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
            try JSONEncoder().encode(ownership).write(to: ownershipURL(staged), options: .withoutOverwriting)
            let originalOwnership = ownership
            let prepared = try await withOpenDocument(at: staged) {
                let metadata = try await invoke(Self.installScript(document: staged, alpha: matte?.alphaURL, createFinishedLayer: createFinishedLayer))
                guard let roles = metadata.roles, roles.isValid else { throw WorkflowBridgeError.invalidStructure }
                var stagedOwnership = originalOwnership; stagedOwnership.roles = roles
                try JSONEncoder().encode(stagedOwnership).write(to: ownershipURL(staged), options: .atomic)
                return try await capture(document: staged, owner: snapshot.taskID)
            }
            if let matte { try await validateInstalledMask(prepared, matte: matte) }
            else { try await validateSubjectMask(prepared) }
            try await verify(snapshot)
            ownership.pendingInstall = InstallTransaction(sourceVersion: snapshot.contentVersion, result: prepared, matte: matte, photoshopSelection: matte == nil ? true : nil)
            try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
            try await installCheckpoint(.prepared)
            guard let saved = try await recoverInstall(document: snapshot.workingURL, owner: snapshot.taskID, allowPublication: true, captureResult: true) else { throw WorkflowBridgeError.invalidStructure }
            return saved
        }
    }
    /// 只有已持久化且完整校验的结果，才能用于恢复 PSD 与归属记录之间的发布过程。
    private func recoverInstall(document: URL, owner: UUID, allowPublication: Bool, captureResult: Bool = false) async throws -> PSDSnapshot? {
        let record = ownershipURL(document)
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
        guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
        guard let pending = ownership.pendingInstall else { return nil }
        guard ownership.roles == nil, pending.result.taskID == owner, pending.result.roles?.isValid == true,
              try hash(pending.result.snapshotURL.path) == pending.result.contentVersion else { throw WorkflowBridgeError.staleSource }
        if let matte = pending.matte {
            guard pending.result.pixelSize == matte.pixelSize,
                  try hash(matte.alphaURL.path) == matte.alphaFingerprint,
                  try hash(matte.cutoutURL.path) == matte.cutoutFingerprint else { throw WorkflowBridgeError.staleSource }
        } else {
            guard pending.photoshopSelection == true else { throw WorkflowBridgeError.staleSource }
        }
        let current = try hash(document.path)
        if current == pending.sourceVersion {
            // 人工编辑期间读取保存结果，不得触发自动 PSD 写入发布。
            guard allowPublication else { return nil }
            let closed = try await invoke(Self.closeForPublicationScript(document: document))
            guard closed.roles == nil, try hash(document.path) == pending.sourceVersion else { throw WorkflowBridgeError.staleSource }
            do {
                try Data(contentsOf: pending.result.snapshotURL, options: .mappedIfSafe).write(to: document, options: .atomic)
            } catch {
                if closed.wasOpen == true { _ = try? await invoke(Self.reopenScript(document: document)) }
                throw error
            }
            if closed.wasOpen == true { _ = try await invoke(Self.reopenScript(document: document)) }
            try await installCheckpoint(.published)
        } else if current != pending.result.contentVersion { throw WorkflowBridgeError.staleSource }
        // 发布已关闭旧文档句柄，此时才能重新取得磁盘上的新版本。
        let previousOwnership = ownership
        return try await withOpenDocument(at: document) {
            let metadata = try await invoke(Self.inspectScript(document: document))
            guard metadata.roles == pending.result.roles, metadata.summary == pending.result.structureSummary,
                  metadata.width == pending.result.pixelSize.width, metadata.height == pending.result.pixelSize.height,
                  try hash(document.path) == pending.result.contentVersion else { throw WorkflowBridgeError.invalidStructure }
            var published = pending.result; published.workingURL = document
            if let matte = pending.matte { try await validateInstalledMask(published, matte: matte) }
            else { try await validateSubjectMask(published) }
            guard try hash(document.path) == pending.result.contentVersion else { throw WorkflowBridgeError.staleSource }
            var completedOwnership = previousOwnership
            completedOwnership.roles = pending.result.roles; completedOwnership.pendingInstall = nil
            if pending.photoshopSelection == true {
                completedOwnership.subjectPublication = SubjectPublication(sourceVersion: pending.sourceVersion, resultVersion: pending.result.contentVersion)
            }
            try JSONEncoder().encode(completedOwnership).write(to: record, options: .atomic)
            return captureResult ? try await capture(document: document, owner: owner) : nil
        }
    }

    /// 只验证原生蒙版及成像一致性，不清理或改写 Photoshop 选择的任何像素。
    private func validateSubjectMask(_ snapshot: PSDSnapshot) async throws {
        let roles = try await extractUnlocked(snapshot)
        let mask = try readRaster(roles.maskPNG)
        guard stride(from: 0, to: mask.pixels.count, by: 4).contains(where: { mask.pixels[$0] > 0 }) else {
            throw WorkflowBridgeError.invalidImage("Photoshop 未识别到主体，请检查合成底图")
        }
        try WorkflowRaster.validateMatte(original: readRaster(roles.basePNG), alpha: mask,
            cutout: readRaster(roles.cutoutPNG), respectSourceAlpha: true)
    }

    private func validateInstalledMask(_ snapshot: PSDSnapshot, matte: MatteArtifact) async throws {
        let extracted = try await extractUnlocked(snapshot)
        let actual = try readRaster(extracted.maskPNG), expected = try readRaster(matte.alphaURL)
        guard actual.size == expected.size else { throw WorkflowBridgeError.invalidImage("回写蒙版尺寸改变") }
        let started = observationStart(); defer { report("pixel.mask-compare", since: started) }
        for i in stride(from: 0, to: actual.pixels.count, by: 4) where abs(Int(actual.pixels[i]) - Int(expected.pixels[i])) > 1 {
            throw WorkflowBridgeError.invalidImage("PSD 保存后的蒙版与 AI Alpha 不一致")
        }
    }
    // MARK: - 角色提取与几何写回
    func extractRoles(snapshot: PSDSnapshot) async throws -> RoleImages {
        try await withLease("extract", owner: snapshot.taskID, savedRead: true) {
            try await verify(snapshot)
            return try await extractUnlocked(snapshot)
        }
    }
    func applyGeometry(snapshot: PSDSnapshot, solution: GeometrySolution, createFinishedLayer: Bool = false) async throws -> PSDSnapshot {
        try await withLease("geometry", owner: snapshot.taskID, savedRead: false) {
            try await withOpenDocument(at: snapshot.workingURL) {
                try await verify(snapshot)
                guard solution.sourceVersion == snapshot.contentVersion, solution.isApplicable,
                      solution.angleDegrees.isFinite, solution.sourceCropRect.width > 0, solution.sourceCropRect.height > 0,
                      solution.sourceCropRect.size == solution.outputSize, snapshot.roles != nil else { throw WorkflowBridgeError.staleSource }
                _ = try await invoke(Self.geometryScript(document: snapshot.workingURL, solution: solution, createFinishedLayer: createFinishedLayer))
                let saved = try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
                guard saved.pixelSize == solution.outputSize else { throw WorkflowBridgeError.invalidImage("裁切读回尺寸不一致") }
                _ = try await extractUnlocked(saved)
                return saved
            }
        }
    }
    private func extractUnlocked(_ snapshot: PSDSnapshot) async throws -> RoleImages {
        guard snapshot.roles?.isValid == true || snapshot.finalRoles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
        // 调用方已校验保存的 PSD，此处只复用身份与内容完全匹配的已校验像素。
        let receipt = workspace.appendingPathComponent("role-cache/\(snapshot.taskID)/\(snapshot.contentVersion).json")
        if let cache = try? JSONDecoder().decode(RoleCache.self, from: Data(contentsOf: receipt)),
           sameExtractionSource(cache.snapshot, snapshot), cache.images.snapshotVersion == snapshot.contentVersion,
           (try? roleFingerprints(cache.images)) == cache.fingerprints {
            return cache.images
        }
        let folder = try outputDirectory("roles/\(snapshot.contentVersion)/\(UUID())", owner: snapshot.taskID)
        let metadata = try await invoke(snapshot.finalRoles != nil ? Self.finalRolesScript(document: snapshot.snapshotURL,folder: folder) : Self.rolesScript(document: snapshot.snapshotURL, folder: folder))
        let base = folder.appendingPathComponent("base.png"), cutout = folder.appendingPathComponent("cutout.png"), mask = folder.appendingPathComponent("mask.png")
        if snapshot.finalRoles != nil {
            guard metadata.finalRoles == snapshot.finalRoles else { throw WorkflowBridgeError.invalidStructure }
            try Self.writeFinalAlpha(cutout: cutout,to: mask)
        }
        let size = CGSize(width: metadata.extentWidth ?? 0, height: metadata.extentHeight ?? 0)
        guard size.width > 0, size.height > 0 else { throw WorkflowBridgeError.invalidStructure }
        let origin = CGPoint(x: metadata.originX ?? 0, y: metadata.originY ?? 0)
        let images = RoleImages(snapshotVersion: snapshot.contentVersion, basePNG: base, cutoutPNG: cutout, maskPNG: mask,
            pixelSize: size, coordinateOrigin: origin, editableExtent: CGRect(origin: origin, size: size),
            cropViewport: CGRect(origin: .zero, size: snapshot.pixelSize),isFinalized: snapshot.finalRoles != nil)
        let fingerprints = try roleFingerprints(images)
        let baseRaster = try readRaster(base), cutoutRaster = try readRaster(cutout), maskRaster = try readRaster(mask)
        guard [baseRaster, cutoutRaster, maskRaster].allSatisfy({ $0.size == size }) else { throw WorkflowBridgeError.invalidImage("角色提取范围不一致") }
        do {
            if images.isFinalized == true { try WorkflowAssetRenderer.validateFinalPixels(base: baseRaster,cutout: cutoutRaster,mask: maskRaster) }
            else { try measure("pixel.validateMatte") { try WorkflowRaster.validateMatte(original: baseRaster, alpha: maskRaster, cutout: cutoutRaster, respectSourceAlpha: true) } }
        }
        catch { if images.isFinalized == true { throw error }; throw WorkflowBridgeError.invalidStructure }
        guard try roleFingerprints(images) == fingerprints else { throw WorkflowBridgeError.staleSource }
        // 缓存写入为可选优化；凭据缺失或损坏时重新提取即可。
        if let data = try? JSONEncoder().encode(RoleCache(snapshot: snapshot, images: images, fingerprints: fingerprints)) {
            try? FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: receipt, options: .atomic)
        }
        return images
    }
    private func sameExtractionSource(_ lhs: PSDSnapshot, _ rhs: PSDSnapshot) -> Bool {
        // 发布会改变工作路径，但不会改变已校验的不可变提取源。
        lhs.taskID == rhs.taskID && lhs.contentVersion == rhs.contentVersion &&
        lhs.snapshotURL == rhs.snapshotURL && lhs.pixelSize == rhs.pixelSize &&
        lhs.roles == rhs.roles && lhs.finalRoles == rhs.finalRoles && lhs.structureSummary == rhs.structureSummary
    }
    private func roleFingerprints(_ images: RoleImages) throws -> [String] {
        try [images.basePNG, images.cutoutPNG, images.maskPNG].map { try hash($0.path) }
    }
    // MARK: - 快照捕获与源版本验证
    func captureFinalPSD(document: URL, owner: UUID) async throws -> PSDSnapshot {
        try await withLease("finalize",owner: owner,savedRead: true) {
            try await capture(document: document,owner: owner,final: true)
        }
    }
    private func capture(document: URL, owner: UUID, final: Bool = false) async throws -> PSDSnapshot {
        let started = observationStart()
        defer { report("capture", since: started) }
        let metadata = try await invoke(Self.inspectScript(document: document,final: final))
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(document)))
        guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
        guard !final || ownership.pendingInstall == nil else { throw WorkflowBridgeError.invalidStructure }
        if final {
            guard metadata.finalRoles?.isValid == true,metadata.width > 0,metadata.height > 0 else { throw WorkflowBridgeError.invalidStructure }
        } else {
            guard ownership.roles == metadata.roles, metadata.roles == nil || metadata.roles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
        }
        let before = try hash(document.path)
        let folder = try outputDirectory("snapshots", owner: owner)
        let temporary = folder.appendingPathComponent("\(UUID()).psd")
        let immutable = folder.appendingPathComponent("\(before).psd")
        let existing = FileManager.default.fileExists(atPath: immutable.path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !existing { try self.copy(at: document, to: temporary) }
        guard try hash((existing ? immutable : temporary).path) == before,
              (try hash(document.path)) == before else { throw WorkflowBridgeError.staleSource }
        // 保留的工作文档句柄不能代表磁盘读回，因此独立检查经过哈希校验的副本。
        let held = Self.openedDocument?.url == document.resolvingSymlinksInPath()
        let readback = held ? (existing ? immutable : temporary) : document
        let second = try await invoke(Self.inspectScript(document: readback,final: final))
        guard metadata.summary == second.summary, metadata.width == second.width, metadata.height == second.height,metadata.roles == second.roles,metadata.finalRoles == second.finalRoles,
              try hash(document.path) == before else { throw WorkflowBridgeError.staleSource }
        if !existing {
            try FileManager.default.moveItem(at: temporary, to: immutable)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: immutable.path)
        }
        return PSDSnapshot(taskID: owner, workingURL: document, snapshotURL: immutable, contentVersion: before,
            pixelSize: CGSize(width: metadata.width, height: metadata.height), roles: metadata.roles, structureSummary: metadata.summary,finalRoles: metadata.finalRoles)
    }
    private func verify(_ snapshot: PSDSnapshot) async throws {
        let saved = try await invoke(Self.inspectScript(document: snapshot.workingURL,final: snapshot.finalRoles != nil))
        guard saved.roles == snapshot.roles,saved.finalRoles == snapshot.finalRoles, saved.width == snapshot.pixelSize.width,
              saved.height == snapshot.pixelSize.height, saved.summary == snapshot.structureSummary else {
            throw snapshot.finalRoles != nil ? WorkflowBridgeError.staleSource : WorkflowBridgeError.invalidStructure
        }
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(snapshot.workingURL)))
        guard ownership.owner == snapshot.taskID, ownership.pendingInstall == nil,
              (snapshot.finalRoles?.isValid == true || ownership.roles == snapshot.roles),
              try hash(snapshot.workingURL.path) == snapshot.contentVersion,
              (try hash(snapshot.snapshotURL.path)) == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
    }
    private func outputDirectory(_ component: String, owner: UUID) throws -> URL {
        let directory = workspace.appendingPathComponent(component).appendingPathComponent(owner.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    private func ownershipURL(_ document: URL) -> URL { document.appendingPathExtension("workflow-owner.json") }
    // 观察回调按需同步执行，不在发布前的校验边界增加挂起点。
    private func observationStart() -> Double? { performanceObserver == nil ? nil : ProcessInfo.processInfo.systemUptime }
    private func report(_ operation: String, since start: Double?) {
        guard let start, let observer = performanceObserver else { return }
        observer(WorkflowPerformanceSample(taskID: Self.performanceTaskID, operation: operation,
            seconds: ProcessInfo.processInfo.systemUptime - start))
    }
    private func measure<T>(_ operation: String, _ body: () throws -> T) rethrows -> T {
        let start = observationStart(); defer { report(operation, since: start) }
        return try body()
    }
    private func hash(_ path: String) throws -> String { try measure("hash") { try AIFileValidation.hash(path) } }
    private func copy(at source: URL, to destination: URL) throws {
        try measure("copy") { try FileManager.default.copyItem(at: source, to: destination) }
    }
    private func readRaster(_ url: URL) throws -> WorkflowRaster { try measure("raster.read") { try WorkflowRaster.read(url) } }
    // MARK: - 协调器租约与脚本执行
    private func withLease<T: Sendable>(_ name: String, owner: UUID, savedRead: Bool,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let queued = observationStart()
        let body: @Sendable () async throws -> T = {
            guard performanceObserver != nil else { return try await operation() }
            return try await Self.$performanceTaskID.withValue(owner) {
                report("lease.wait." + name, since: queued)
                let started = observationStart(); defer { report("service." + name, since: started) }
                return try await operation()
            }
        }
        if savedRead { return try await coordinator.readSaved(owner: owner, operation: body) }
        return try await coordinator.run(owner: owner, operation: body)
    }
    /// 仅在已持有协调器租约时调用，文档句柄不得超出本次服务作用域。
    private func withOpenDocument<T: Sendable>(at url: URL, operation: @Sendable () async throws -> T) async throws -> T {
        guard reuseDocumentsWithinOperation else { return try await operation() }
        let path = url.resolvingSymlinksInPath(), token = "workflowDocument_" + UUID().uuidString
        let performanceTaskID = Self.performanceTaskID
        let opened: Metadata
        do {
            opened = try await invoke(Self.acquireDocumentScript(path, token: token))
            guard opened.documentID != nil, opened.wasOpen != nil else { throw WorkflowBridgeError.invalidStructure }
        } catch {
            // 响应丢失或无效时文档仍可能已打开，使用随机令牌证明本次操作的归属。
            _ = try? await Task.detached {
                try await Self.$performanceTaskID.withValue(performanceTaskID) {
                    try await invoke(Self.releaseDocumentScript(path, token: token, documentID: nil))
                }
            }.value
            throw error
        }
        let handle = OpenedWorkflowDocument(documentID: opened.documentID!, url: path, token: token)
        let result: Result<T, Error>
        do { result = .success(try await Self.$openedDocument.withValue(handle) { try await operation() }) }
        catch { result = .failure(error) }
        // 即使任务取消，也必须等 Photoshop 清理完成后再释放协调器租约。
        _ = try await Task.detached {
            try await Self.$performanceTaskID.withValue(performanceTaskID) {
                try await invoke(Self.releaseDocumentScript(path, token: token, documentID: handle.documentID))
            }
        }.value
        return try result.get()
    }
    private func invoke(_ body: String) async throws -> Metadata {
        let started = observationStart()
        defer { report("ps.invoke", since: started) }
        let scope = Self.openedDocument.map { Self.documentScopeScript($0) } ?? ""
        let script: String
        if performanceObserver == nil {
            script = Self.commonScript + scope + "\n(function(){" + body + "}());"
        } else {
            // 等内部 finally 关闭临时文档后，再附加性能指标。
            script = Self.commonScript + Self.performanceScript + scope + "\nvar wfResult=(function(){" + body + "}());" +
                "var wfDecoded=eval('('+wfResult+')');wfDecoded.performance=wfPerformance;wfDecoded.documentPeak=wfPeak;wfJSON(wfDecoded);"
        }
        let result = try await scriptRunner(script)
        guard let data = result.data(using: .utf8) else { throw WorkflowBridgeError.photoshop("无法读取脚本结果") }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        if let observer = performanceObserver {
            for (key, seconds) in (metadata.performance ?? [:]).sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                let pieces = key.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2, Int(pieces[0]) != nil, seconds.isFinite, seconds >= 0 else { continue }
                let operation = String(pieces[1])
                observer(WorkflowPerformanceSample(taskID: Self.performanceTaskID, operation: "ps." + operation, seconds: seconds))
            }
            if let peak = metadata.documentPeak {
                observer(WorkflowPerformanceSample(taskID: Self.performanceTaskID, operation: "ps.documents.peak.\(peak)", seconds: 0))
            }
        }
        return metadata
    }
    static func execute(_ script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let application = FocusStackProcessor.photoshopApplicationName() else { throw FocusStackError.photoshopNotFound }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID()).jsx")
            defer { try? FileManager.default.removeItem(at: url) }
            // 添加 BOM，避免中文位于长脚本后部时 ExtendScript 误判为旧编码。
            try ("\u{FEFF}" + script).write(to: url, atomically: true, encoding: .utf8)
            let process = Process(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \(quote(application)) to do javascript file (POSIX file \(quote(url.path)))"]
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: diagnostic, as: UTF8.self)
                if message.contains("WORKFLOW_UNSAVED") { throw WorkflowBridgeError.unsavedDocument }
                if message.contains("WORKFLOW_STALE_DOCUMENT") { throw WorkflowBridgeError.staleSource }
                if message.contains("WORKFLOW_STRUCTURE") { throw WorkflowBridgeError.invalidStructure }
                throw WorkflowBridgeError.photoshop(message)
            }
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    private static func quote(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
}

// MARK: - Photoshop 脚本生成
extension PhotoshopWorkflowBridge {
    private static func acquireDocumentScript(_ url: URL, token: String) -> String {
        """
        var o=wfOpen(\(quote(url.path)));
        try {
            var state=new ActionDescriptor();
            state.putInteger(stringIDToTypeID('documentID'),o.doc.id);
            state.putString(stringIDToTypeID('path'),\(quote(url.path)));
            state.putString(stringIDToTypeID('nativePath'),o.doc.fullName.fsName);
            state.putBoolean(stringIDToTypeID('owned'),o.owned);
            app.putCustomOptions(\(quote(token)),state,false);
        } catch(e) {if(o.owned && o.doc.saved)wfCloseDocument(o.doc);throw e;}
        return wfJSON({width:0,height:0,profile:'',summary:'',documentID:o.doc.id,wasOpen:!o.owned});
        """
    }
    private static func heldDocumentScript(_ url: URL, token: String, documentID: Int?) -> String {
        """
        function wfHeldState(){
            try {var state=app.getCustomOptions(\(quote(token)));
                return {id:state.getInteger(stringIDToTypeID('documentID')),path:state.getString(stringIDToTypeID('path')),nativePath:state.getString(stringIDToTypeID('nativePath')),owned:state.getBoolean(stringIDToTypeID('owned'))};
            } catch(e) {throw new Error('WORKFLOW_STALE_DOCUMENT');}
        }
        function wfHeldDocument(){
            var h=wfHeldState(),doc=null;
            if(h.path!==\(quote(url.path)) \(documentID.map { "|| h.id!==" + String($0) } ?? ""))throw new Error('WORKFLOW_STALE_DOCUMENT');
            for(var i=0;i<app.documents.length;i++)if(app.documents[i].id===h.id)doc=app.documents[i];
            try{if(!doc || doc.fullName.fsName!==h.nativePath)throw new Error('WORKFLOW_STALE_DOCUMENT');}
            catch(e){throw new Error('WORKFLOW_STALE_DOCUMENT');}
            if(!doc.saved)throw new Error('WORKFLOW_UNSAVED');
            return doc;
        }
        """
    }
    private static func documentScopeScript(_ handle: OpenedWorkflowDocument) -> String {
        heldDocumentScript(handle.url, token: handle.token, documentID: handle.documentID) + """
        wfHeldDocument();
        var wfUnboundOpen=wfOpen;
        wfOpen=function(path){
            if(new File(path).fsName===new File(\(quote(handle.url.path))).fsName){var doc=wfHeldDocument();app.activeDocument=doc;return {doc:doc,owned:false};}
            return wfUnboundOpen(path);
        };
        """
    }
    private static func releaseDocumentScript(_ url: URL, token: String, documentID: Int?) -> String {
        heldDocumentScript(url, token: token, documentID: documentID) + """
        var state=wfHeldState();
        try {var doc=wfHeldDocument();if(state.owned)wfCloseDocument(doc);}
        finally{app.eraseCustomOptions(\(quote(token)));}
        return wfJSON({width:0,height:0,profile:'',summary:''});
        """
    }
    private static let performanceScript = #"""
    var wfPerformance={},wfSequence=0,wfPeak=app.documents.length;
    function wfWrap(name,body) { return function() {
        var started=new Date().getTime();
        try { return body.apply(this,arguments); }
        finally { wfPerformance[String(wfSequence++)+':'+name]=(new Date().getTime()-started)/1000;wfPeak=Math.max(wfPeak,app.documents.length); }
    }; }
    wfOpenFile=wfWrap('open',wfOpenFile);
    wfDuplicate=wfWrap('duplicate',wfDuplicate);
    wfMaskDocument=wfWrap('new-mask-document',wfMaskDocument);
    wfCloseDocument=wfWrap('close',wfCloseDocument);
    wfSave=wfWrap('save',wfSave);
    wfMetadata=wfWrap('inspect',wfMetadata);
    wfRolePNG=wfWrap('role-encode',wfRolePNG);
    wfStackPNG=wfWrap('stack-encode',wfStackPNG);
    """#
    // 公共脚本负责保存状态、角色结构与图层身份校验，后续脚本共享同一组约束。
    private static let commonScript = #"""
    #target photoshop
    function wfJSON(v) {
        if (v === null || v === undefined) return "null";
        if (typeof v === "string") return '"' + v.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n') + '"';
        if (typeof v === "number" || typeof v === "boolean") return String(v);
        var parts = [], k;
        for (k in v) if (v.hasOwnProperty(k)) parts.push(wfJSON(k)+':'+wfJSON(v[k]));
        return '{'+parts.join(',')+'}';
    }
    function wfOpenFile(file) { return app.open(file); }
    function wfDuplicate(doc) { return doc.duplicate(); }
    function wfCloseDocument(doc) { doc.close(SaveOptions.DONOTSAVECHANGES); }
    function wfMaskDocument(copy) { return app.documents.add(copy.width,copy.height,copy.resolution,'Workflow mask',NewDocumentMode.RGB,DocumentFill.WHITE); }
    function wfOpen(path) {
        var file = new File(path), existingIDs=[];
        for (var i=0;i<app.documents.length;i++) {
            var d=app.documents[i];existingIDs.push(d.id);
            try { if (d.fullName.fsName === file.fsName) {
                if (!d.saved) throw new Error('WORKFLOW_UNSAVED');
                app.activeDocument=d; return {doc:d,owned:false};
            }} catch(e) { if (String(e).indexOf('WORKFLOW_UNSAVED')>=0) throw e; }
        }
        var opened=wfOpenFile(file),owned=true;
        for(var j=0;j<existingIDs.length;j++)if(existingIDs[j]===opened.id)owned=false;
        if(!opened.saved)throw new Error('WORKFLOW_UNSAVED');
        return {doc:opened,owned:owned};
    }
    function wfClose(opened) { if(opened.owned) wfCloseDocument(opened.doc); }
    function wfDescriptor(layer) {
        var r=new ActionReference(); r.putIdentifier(charIDToTypeID('Lyr '),layer.id); return executeActionGet(r);
    }
    function wfHasMask(layer) { var d=wfDescriptor(layer); return d.hasKey(stringIDToTypeID('hasUserMask')) && d.getBoolean(stringIDToTypeID('hasUserMask')); }
    function wfBounds(layer) {
        var d=wfDescriptor(layer),key=stringIDToTypeID('boundsNoMask');
        if (!d.hasKey(key)) key=stringIDToTypeID('bounds');
        var b=d.getObjectValue(key);return [b.getUnitDoubleValue(stringIDToTypeID('left')),b.getUnitDoubleValue(stringIDToTypeID('top')),b.getUnitDoubleValue(stringIDToTypeID('right')),b.getUnitDoubleValue(stringIDToTypeID('bottom'))];
    }
    function wfIsPreviewBackground(layer) {
        return layer.typename==='ArtLayer' && (layer.name==='Background #74BFFF' || (layer.name==='BG' && layer.kind===LayerKind.SOLIDFILL));
    }
    function wfRoles(doc) {
        var original=null,adjust=null,base=null,cutout=null,finished=null,count=0;
        for(var i=0;i<doc.layers.length;i++) {
            var l=doc.layers[i];
            if(l.name==='原始堆栈' && l.typename==='LayerSet') { original=l;count++; }
            if(l.name==='共同调整' && l.typename==='LayerSet') { adjust=l;count++; }
        }
        if(count===0) return null;
        var background=doc.layers.length===3 ? doc.layers[2] : null;
        var validRoot=doc.layers.length===2 || (background && background.name==='BG' && wfIsPreviewBackground(background));
        if(count!==2 || !original || !adjust || !validRoot || (adjust.layers.length!==2 && adjust.layers.length!==3)) throw new Error('WORKFLOW_STRUCTURE');
        for(var j=0;j<adjust.layers.length;j++) {
            var a=adjust.layers[j]; if(a.name==='底图' && a.typename==='ArtLayer') base=a;
            if(a.name==='抠图' && a.typename==='ArtLayer') cutout=a;
            if(a.name==='透明成品' && a.typename==='ArtLayer') finished=a;
        }
        if((adjust.layers.length===3 && !finished) || (finished && (wfHasMask(finished) || finished.kind!==LayerKind.NORMAL || finished.grouped)))throw new Error('WORKFLOW_STRUCTURE');
        if(!base || !cutout || wfHasMask(base) || !wfHasMask(cutout)) throw new Error('WORKFLOW_STRUCTURE');
        var b=wfBounds(base),c=wfBounds(cutout);
        for(var k=0;k<4;k++) if(Math.abs(b[k]-c[k])>0.1) throw new Error('WORKFLOW_STRUCTURE');
        return {original:original,adjust:adjust,base:base,cutout:cutout,finished:finished,ids:{originalStackGroup:String(original.id),adjustmentGroup:String(adjust.id),baseLayer:String(base.id),cutoutLayer:String(cutout.id),mask:String(cutout.id)+':userMask'}};
    }
    // 自动阶段生成紧边界成品；保留原蒙版和完整 RGB 供人工恢复，不在人工刷新时重建。
    function wfMakeFinished(doc,roles) {
        var finished=roles.cutout.duplicate();finished.name='透明成品';
        // PLACEBEFORE 明确保证成品在蒙版备份上方，最终导出读取首个可见像素层。
        finished.move(roles.cutout,ElementPlacement.PLACEBEFORE);doc.activeLayer=finished;
        var ref=new ActionReference();ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));
        var desc=new ActionDescriptor();desc.putReference(charIDToTypeID('null'),ref);desc.putBoolean(charIDToTypeID('Aply'),true);
        executeAction(charIDToTypeID('Dlt '),desc,DialogModes.NO);
        if(roles.finished)roles.finished.remove();
        roles.base.visible=false;roles.cutout.visible=false;finished.visible=true;doc.activeLayer=finished;
    }
    function wfFinalRoles(doc) {
        var group=null,base=null,cutout=null,n=0,b=0;
        for(var i=0;i<doc.layers.length;i++)if(doc.layers[i].name==='共同调整'){group=doc.layers[i];n++;}
        if(n!==1 || group.typename!=='LayerSet')throw new Error('需要唯一的“共同调整”图层组');
        for(var j=0;j<group.layers.length;j++) {
            var layer=group.layers[j];
            if(layer.name==='底图'){base=layer;b++;}
            else if(!cutout && layer.visible)cutout=layer;
        }
        if(b!==1 || base.typename!=='ArtLayer' || base.kind!==LayerKind.NORMAL)throw new Error('共同调整中需要唯一的像素图层“底图”');
        if(!cutout || cutout.typename!=='ArtLayer' || cutout.kind!==LayerKind.NORMAL)throw new Error('共同调整中最上方可见图层必须是最终透明像素图层');
        if(base.grouped || cutout.grouped)throw new Error('请先将剪贴蒙版落实到导出像素图层');
        if(wfHasMask(group))throw new Error('请将共同调整组的蒙版落实到导出图层后再刷新');
        return {adjust:group,base:base,cutout:cutout,ids:{adjustmentGroup:String(group.id),baseLayer:String(base.id),cutoutLayer:String(cutout.id)}};
    }
    function wfFinalMetadata(doc) {
        var r=wfFinalRoles(doc);
        return {width:doc.width.as('px'),height:doc.height.as('px'),profile:doc.colorProfileName,finalRoles:r.ids,summary:wfSummary(doc)};
    }
    function wfSummary(doc) {
        var summary='';
        function visit(parent) {for(var i=0;i<parent.layers.length;i++) {
            var l=parent.layers[i];summary+=l.id+':'+l.name+':'+l.typename+':'+wfHasMask(l)+':'+l.visible+';';if(l.typename==='LayerSet')visit(l);
        }}visit(doc);return summary;
    }
    function wfMetadata(doc) {
        var roles=wfRoles(doc),summary='';
        function visit(parent) { for(var i=0;i<parent.layers.length;i++) {
            var l=parent.layers[i];summary+=l.id+':'+l.name+':'+l.typename+':'+wfHasMask(l)+';';if(l.typename==='LayerSet')visit(l);
        }} visit(doc);
        return {width:doc.width.as('px'),height:doc.height.as('px'),profile:doc.colorProfileName,roles:roles?roles.ids:null,summary:summary};
    }
    function wfPNG(doc,path) { var p=new ExportOptionsSaveForWeb();p.format=SaveDocumentType.PNG;p.PNG8=false;p.transparency=true;p.interlaced=false;p.includeProfile=true;doc.exportDocument(new File(path),ExportType.SAVEFORWEB,p); }
    // 角色 PNG 需要快速无损编码并保留 ICC；PNGSaveOptions 会遗漏色彩配置。
    function wfRolePNG(doc,path) {
        if(doc.bitsPerChannel!==BitsPerChannelType.EIGHT || doc.mode!==DocumentMode.RGB){wfPNG(doc,path);return;}
        app.activeDocument=doc;var s=stringIDToTypeID,p=new ActionDescriptor(),d=new ActionDescriptor();
        p.putEnumerated(s('method'),s('PNGMethod'),s('quick'));p.putInteger(s('compression'),1);
        p.putEnumerated(s('PNGInterlaceType'),s('PNGInterlaceType'),s('PNGInterlaceNone'));
        p.putEnumerated(s('PNGFilter'),s('PNGFilter'),s('PNGFilterAdaptive'));
        p.putEnumerated(s('embedIccProfileLastState'),s('embedOff'),s('embedOn'));
        d.putObject(s('as'),s('PNGFormat'),p);d.putPath(s('in'),new File(path));
        d.putBoolean(s('copy'),true);d.putBoolean(s('lowerCase'),true);d.putBoolean(s('embedProfiles'),true);
        executeAction(s('save'),d,DialogModes.NO);
    }
    function wfStackPNG(doc,path) {
        if(doc.mode!==DocumentMode.RGB || doc.bitsPerChannel!==BitsPerChannelType.EIGHT || doc.colorProfileName!=='sRGB IEC61966-2.1'){wfPNG(doc,path);return;}
        // 匹配 Save for Web 使用的标准 sRGB ICC，不再变换已经处于 sRGB 的像素。
        app.activeDocument=doc;var profile=new ActionDescriptor();
        var target=new ActionReference();target.putEnumerated(charIDToTypeID('Dcmn'),charIDToTypeID('Ordn'),charIDToTypeID('Trgt'));
        profile.putReference(charIDToTypeID('null'),target);
        profile.putString(stringIDToTypeID('profile'),'sRGB IEC61966-2.1');
        executeAction(stringIDToTypeID('assignProfile'),profile,DialogModes.NO);
        wfRolePNG(doc,path);
    }
    function wfSave(doc) { var p=new PhotoshopSaveOptions();p.layers=true;p.embedColorProfile=true;p.maximizeCompatibility=true;doc.saveAs(doc.fullName,p,false,Extension.LOWERCASE); }
    function wfSelectMask(layer) {
        app.activeDocument.activeLayer=layer;
        var d=new ActionDescriptor(),r=new ActionReference();r.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));d.putReference(charIDToTypeID('null'),r);d.putBoolean(charIDToTypeID('MkVs'),false);executeAction(charIDToTypeID('slct'),d,DialogModes.NO);
    }
    function wfSelectRGB() { var d=new ActionDescriptor(),r=new ActionReference();r.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('RGB '));d.putReference(charIDToTypeID('null'),r);executeAction(charIDToTypeID('slct'),d,DialogModes.NO); }
    function wfMaskToSelection(layer) {
        app.activeDocument.activeLayer=layer;var d=new ActionDescriptor(),to=new ActionReference(),from=new ActionReference();
        to.putProperty(charIDToTypeID('Chnl'),charIDToTypeID('fsel'));d.putReference(charIDToTypeID('null'),to);
        from.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));d.putReference(charIDToTypeID('T   '),from);executeAction(charIDToTypeID('setd'),d,DialogModes.NO);
    }
    function wfHideAll(doc) {for(var i=0;i<doc.layers.length;i++)doc.layers[i].visible=false;}
    """#
    private static func inspectScript(document: URL, final: Bool = false) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path)));try{return wfJSON(\(final ? "wfFinalMetadata" : "wfMetadata")(o.doc));}finally{wfClose(o);}
        """
    }
    private static func closeForPublicationScript(document: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),meta=wfMetadata(o.doc);
        meta.wasOpen=!o.owned;wfCloseDocument(o.doc);return wfJSON(meta);
        """
    }
    private static func reopenScript(document: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path)));return wfJSON(wfMetadata(o.doc));
        """
    }
    static func stackInputExportScript(output: URL) -> String {
        commonScript.replacingOccurrences(of: "#target photoshop", with: "") + "\n" +
        "try{(function(){" + stackPNGBody(document: "stackDocument", output: output) +
        "}());}catch(e){try{new File(" + quote(output.path) + ").remove();}catch(_){}throw e;}"
    }
    private static func stackPNGBody(document: String, output: URL) -> String {
        """
        var copy=null;
        try {copy=wfDuplicate(\(document));app.activeDocument=copy;var r=wfRoles(copy);
            if(r){wfHideAll(copy);r.adjust.visible=true;r.base.visible=true;r.cutout.visible=false;if(r.finished)r.finished.visible=false;}
            else {for(var i=0;i<copy.layers.length;i++) if(wfIsPreviewBackground(copy.layers[i]))copy.layers[i].visible=false;}
            wfStackPNG(copy,\(quote(output.path)));return wfJSON(wfMetadata(copy));
        }finally{if(copy)wfCloseDocument(copy);}
        """
    }
    private static func exportScript(document: URL, output: URL, roles: PSDRoleIdentifiers?) -> String {
        "var o=wfOpen(" + quote(document.resolvingSymlinksInPath().path) + ");try{" +
        stackPNGBody(document: "o.doc", output: output) + "}finally{wfClose(o);}"
    }
    // 在当前合成像素层上识别，空选区不能退化为全白蒙版。
    static let selectSubjectSelectionScript = """
        wfSelectRGB();doc.selection.deselect();
        var subject=new ActionDescriptor();subject.putBoolean(stringIDToTypeID('sampleAllLayers'),false);
        executeAction(stringIDToTypeID('autoCutout'),subject,DialogModes.NO);
        try { var subjectBounds=doc.selection.bounds; }
        catch(e) { throw new Error('Photoshop 未识别到主体，请检查合成底图'); }
        """
    private static func installScript(document: URL, alpha: URL?, createFinishedLayer: Bool) -> String {
        let selection: String
        if let alpha {
            selection = """
            maskDoc=wfOpenFile(new File(\(quote(alpha.path))));var imported=maskDoc.channels[0].duplicate(doc);
            wfCloseDocument(maskDoc);maskDoc=null;
            app.activeDocument=doc;doc.activeLayer=cutout;doc.selection.load(imported);
            """
        } else { selection = selectSubjectSelectionScript }
        return """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null,maskDoc=null,doc=o.doc;
        var dialogs=app.displayDialogs;app.displayDialogs=DialogModes.NO;
        try {
            if(wfRoles(doc))throw new Error('WORKFLOW_STRUCTURE');
            copy=wfDuplicate(doc);app.activeDocument=copy;
            for(var i=copy.layers.length-1;i>=0;i--)if(wfIsPreviewBackground(copy.layers[i])){copy.layers[i].allLocked=false;copy.layers[i].remove();}
            // 透明辅助层让单层或单个可见组也能无损合并；只存在于可丢弃副本。
            copy.artLayers.add();copy.mergeVisibleLayers();var merged=copy.activeLayer;
            app.activeDocument=doc;var old=[],background=null;
            for(var j=0;j<doc.layers.length;j++){
                if(wfIsPreviewBackground(doc.layers[j])){if(background)throw new Error('WORKFLOW_STRUCTURE');background=doc.layers[j];}
                else old.push(doc.layers[j]);
            }
            var original=doc.layerSets.add();original.name='原始堆栈';
            for(var k=old.length-1;k>=0;k--){if(old[k].typename==='ArtLayer'&&old[k].isBackgroundLayer)old[k].isBackgroundLayer=false;old[k].move(original,ElementPlacement.INSIDE);}
            original.visible=false;
            // 预览背景独立留在根目录底层，不随原始堆栈隐藏，也不进入合成底图或蒙版。
            if(background){background.allLocked=false;background.name='BG';background.move(original,ElementPlacement.PLACEAFTER);background.visible=true;background.allLocked=true;}
            var adjust=doc.layerSets.add();adjust.name='共同调整';
            app.activeDocument=copy;merged.duplicate(doc,ElementPlacement.PLACEATBEGINNING);
            app.activeDocument=doc;var base=doc.activeLayer;base.name='底图';base.move(adjust,ElementPlacement.INSIDE);
            var cutout=base.duplicate();cutout.name='抠图';base.visible=false;cutout.visible=true;doc.activeLayer=cutout;
            \(selection)
            var make=new ActionDescriptor(),ref=new ActionReference();make.putClass(charIDToTypeID('Nw  '),charIDToTypeID('Chnl'));
            ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));make.putReference(charIDToTypeID('At  '),ref);
            make.putEnumerated(charIDToTypeID('Usng'),charIDToTypeID('UsrM'),charIDToTypeID('RvlS'));executeAction(charIDToTypeID('Mk  '),make,DialogModes.NO);
            doc.selection.deselect();if(typeof imported!=='undefined')imported.remove();wfSelectRGB();
            if(\(createFinishedLayer ? "true" : "false"))wfMakeFinished(doc,wfRoles(doc));
            wfSave(doc);return wfJSON(wfMetadata(doc));
        }finally{if(maskDoc)wfCloseDocument(maskDoc);if(copy)wfCloseDocument(copy);app.displayDialogs=dialogs;wfClose(o);}
        """
    }
    // 在临时副本上展开隐藏像素，并回传相对当前 PSD 的像素原点和可编辑范围。
    // 人工定稿读取仅在副本切换可见性，保留当前画布与用户原文件。
    private static func finalRolesScript(document: URL, folder: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null;
        try {
            var meta=wfFinalMetadata(o.doc);
            copy=wfDuplicate(o.doc);app.activeDocument=copy;var r=wfFinalRoles(copy);
            wfHideAll(copy);r.adjust.visible=true;
            for(var i=0;i<r.adjust.layers.length;i++)r.adjust.layers[i].visible=false;
            r.base.visible=true;wfRolePNG(copy,\(quote(folder.appendingPathComponent("base.png").path)));
            r.base.visible=false;r.cutout.visible=true;wfRolePNG(copy,\(quote(folder.appendingPathComponent("cutout.png").path)));
            meta.originX=0;meta.originY=0;meta.extentWidth=meta.width;meta.extentHeight=meta.height;return wfJSON(meta);
        }finally{if(copy)wfCloseDocument(copy);wfClose(o);}
        """
    }
    private static func writeFinalAlpha(cutout: URL,to destination: URL) throws {
        let raster = try WorkflowRaster.read(cutout),w = Int(raster.size.width),h = Int(raster.size.height)
        var bytes = raster.pixels
        for i in stride(from: 0,to: bytes.count,by: 4) {
            let a = bytes[i+3]; bytes[i] = a; bytes[i+1] = a; bytes[i+2] = a; bytes[i+3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent),
              let out = CGImageDestinationCreateWithURL(destination as CFURL,UTType.png.identifier as CFString,1,nil) else { throw WorkflowBridgeError.invalidStructure }
        CGImageDestinationAddImage(out,image,nil)
        guard CGImageDestinationFinalize(out) else { throw WorkflowBridgeError.invalidStructure }
    }
    private static func rolesScript(document: URL, folder: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null,mask=null;
        try {
            var meta=wfMetadata(o.doc);if(!meta.roles)throw new Error('WORKFLOW_STRUCTURE');
            copy=wfDuplicate(o.doc);app.activeDocument=copy;var r=wfRoles(copy),b=wfBounds(r.base);
            var left=Math.min(0,Math.floor(b[0])),top=Math.min(0,Math.floor(b[1]));
            var right=Math.max(meta.width,Math.ceil(b[2])),bottom=Math.max(meta.height,Math.ceil(b[3]));
            // 仅在可丢弃的副本上展开隐藏像素，不裁切任务 PSD。
            copy.resizeCanvas(UnitValue(right-left,'px'),UnitValue(bottom-top,'px'),AnchorPosition.TOPLEFT);
            r.adjust.translate(UnitValue(-left,'px'),UnitValue(-top,'px'));
            wfHideAll(copy);r.adjust.visible=true;r.base.visible=true;r.cutout.visible=false;if(r.finished)r.finished.visible=false;
            wfRolePNG(copy,\(quote(folder.appendingPathComponent("base.png").path)));
            r.base.visible=false;(r.finished||r.cutout).visible=true;wfRolePNG(copy,\(quote(folder.appendingPathComponent("cutout.png").path)));
            wfMaskToSelection(r.cutout);
            mask=wfMaskDocument(copy);
            var black=new SolidColor();black.rgb.red=0;black.rgb.green=0;black.rgb.blue=0;mask.selection.selectAll();mask.selection.fill(black);mask.selection.deselect();
            app.activeDocument=copy;copy.selection.store(copy.channels.add());var channel=copy.channels[copy.channels.length-1];
            channel.duplicate(mask);app.activeDocument=mask;mask.selection.load(mask.channels[mask.channels.length-1]);
            var white=new SolidColor();white.rgb.red=255;white.rgb.green=255;white.rgb.blue=255;
            wfSelectRGB();mask.selection.fill(white,ColorBlendMode.NORMAL,100,false);mask.selection.deselect();
            wfRolePNG(mask,\(quote(folder.appendingPathComponent("mask.png").path)));
            meta.originX=left;meta.originY=top;meta.extentWidth=right-left;meta.extentHeight=bottom-top;return wfJSON(meta);
        }finally{if(mask)wfCloseDocument(mask);if(copy)wfCloseDocument(copy);wfClose(o);}
        """
    }
    // 共同调整组先绕自身中心旋转，再平移补偿为指定支点；裁切保留框外可编辑像素。
    private static func geometryScript(document: URL, solution: GeometrySolution, createFinishedLayer: Bool) -> String {
        let rect = solution.sourceCropRect
        return """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),doc=o.doc;
        try {
            var roles=wfRoles(doc);if(!roles)throw new Error('WORKFLOW_STRUCTURE');
            // 仍以完整底图与蒙版层计算旋转，避免成品的紧边界改变 Photoshop 组旋转中心。
            var makeFinished=\(createFinishedLayer ? "true" : "false") || !!roles.finished;
            if(roles.finished){roles.finished.remove();roles.finished=null;}
            if(makeFinished)roles.cutout.visible=true;
            var bounds=wfBounds(roles.base),cx=(bounds[0]+bounds[2])/2,cy=(bounds[1]+bounds[3])/2;
            var px=\(solution.rotationPivot.x),py=\(solution.rotationPivot.y),angle=\(solution.angleDegrees),radians=angle*Math.PI/180;
            if(angle!==0){
                roles.adjust.rotate(angle,AnchorPosition.MIDDLECENTER);
                var dx=px+(cx-px)*Math.cos(radians)-(cy-py)*Math.sin(radians)-cx;
                var dy=py+(cx-px)*Math.sin(radians)+(cy-py)*Math.cos(radians)-cy;
                roles.adjust.translate(UnitValue(dx,'px'),UnitValue(dy,'px'));
            }
            var d=new ActionDescriptor(),r=new ActionDescriptor();
            r.putUnitDouble(charIDToTypeID('Top '),charIDToTypeID('#Pxl'),\(rect.minY));r.putUnitDouble(charIDToTypeID('Left'),charIDToTypeID('#Pxl'),\(rect.minX));
            r.putUnitDouble(charIDToTypeID('Btom'),charIDToTypeID('#Pxl'),\(rect.maxY));r.putUnitDouble(charIDToTypeID('Rght'),charIDToTypeID('#Pxl'),\(rect.maxX));
            d.putObject(charIDToTypeID('T   '),charIDToTypeID('Rctn'),r);d.putUnitDouble(charIDToTypeID('Angl'),charIDToTypeID('#Ang'),0);
            d.putBoolean(charIDToTypeID('Dlt '),false);executeAction(charIDToTypeID('Crop'),d,DialogModes.NO);
            if(makeFinished)wfMakeFinished(doc,roles);
            wfSave(doc);return wfJSON(wfMetadata(doc));
        }finally{wfClose(o);}
        """
    }
}
