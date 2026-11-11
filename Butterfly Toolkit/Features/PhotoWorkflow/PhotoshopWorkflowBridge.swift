// 桥接 Photoshop 堆栈、蒙版回写、角色提取与几何操作，维护文档归属、不可变快照和中断恢复。

import Foundation
import AppKit
import ApplicationServices
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
    private struct TaskDocument: Sendable {
        let owner: UUID
        let url: URL
        let token: String
        let coordinator: PhotoshopExecutionCoordinator
    }
    @TaskLocal private static var taskDocument: TaskDocument?
    @TaskLocal private static var openedDocument: OpenedWorkflowDocument?
    private let reuseDocumentsWithinOperation: Bool
    private let stackProcessor: StackProcessor
    let workspace: URL
    private let coordinator: PhotoshopExecutionCoordinator
    private let scriptRunner: ScriptRunner
    private let documentListRunner: ScriptRunner
    private let installCheckpoint: @Sendable (PhotoshopInstallCheckpoint) async throws -> Void
    @TaskLocal private static var performanceTaskID: UUID?
    private let performanceObserver: WorkflowPerformanceObserver?
    init(workspace: URL, coordinator: PhotoshopExecutionCoordinator = .shared, scriptRunner: @escaping ScriptRunner = { try await Self.execute($0) }, documentListRunner: @escaping ScriptRunner = { try await Self.executeInRunningPhotoshop($0) }, installCheckpoint: @escaping @Sendable (PhotoshopInstallCheckpoint) async throws -> Void = { _ in }, performanceObserver: WorkflowPerformanceObserver? = nil, reuseDocumentsWithinOperation: Bool = false, stackProcessor: @escaping StackProcessor = { job, hook in
        guard let application = FocusStackProcessor.photoshopApplicationName() else { throw FocusStackError.photoshopNotFound }
        let handoff = Self.taskDocument.map { Self.stackDocumentHandoffScript($0) }
        try await Task.detached(priority: .userInitiated) {
            try FocusStackProcessor.process(job, photoshopApplicationName: application, workflowPNGExportScript: hook, workflowDocumentHandoff: handoff)
        }.value
    }) {
        self.documentListRunner = documentListRunner
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
    private struct PendingMutation: Codable, Sendable {
        var sourceVersion: String
        var operation: String
    }
    private struct GeometryPublication: Codable, Sendable {
        var sourceVersion: String
        var solution: GeometrySolution
        var result: PSDSnapshot
    }
    private struct Ownership: Codable, Sendable {
        var owner: UUID
        var roles: PSDRoleIdentifiers?
        var sources: [WorkflowSourceFile]?
        var initialStackVersion: String?
        var pendingInstall: InstallTransaction?
        var subjectPublication: SubjectPublication?
        var pendingMutation: PendingMutation?
        var geometryPublication: GeometryPublication?
        var restoredCheckpoint: PSDSnapshot?
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
        try await withLease("adoptStack", owner: owner, savedRead: false, document: source.url) {
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
    /// 从不可变检查点建立新的工作路径；原工作文档可能正被人工编辑，绝不打开或改写它。
    func restoreCheckpoint(snapshot: PSDSnapshot, destination: URL) async throws -> PSDSnapshot {
        try await withLease("restoreCheckpoint", owner: snapshot.taskID, savedRead: false, document: destination) {
            let path = destination.resolvingSymlinksInPath()
            guard path != snapshot.workingURL.resolvingSymlinksInPath(), path != snapshot.snapshotURL.resolvingSymlinksInPath(),
                  snapshot.finalRoles == nil, try hash(snapshot.snapshotURL.path) == snapshot.contentVersion else {
                throw WorkflowBridgeError.staleSource
            }
            let source = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(snapshot.workingURL)))
            guard source.owner == snapshot.taskID else { throw WorkflowBridgeError.ownershipConflict }
            let record = ownershipURL(destination)
            let exists = FileManager.default.fileExists(atPath: destination.path)
            let hasRecord = FileManager.default.fileExists(atPath: record.path)
            var restored = source
            restored.roles = snapshot.roles
            restored.pendingInstall = nil; restored.pendingMutation = nil
            restored.subjectPublication = nil; restored.geometryPublication = nil
            restored.restoredCheckpoint = snapshot
            if snapshot.roles == nil { restored.initialStackVersion = snapshot.contentVersion }
            if hasRecord {
                let previous = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
                guard previous.owner == snapshot.taskID, previous.restoredCheckpoint == snapshot,
                      previous.roles == snapshot.roles, previous.pendingMutation == nil, previous.pendingInstall == nil,
                      previous.subjectPublication == nil, previous.geometryPublication == nil else { throw WorkflowBridgeError.ownershipConflict }
            } else {
                guard !exists else { throw WorkflowBridgeError.ownershipConflict }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(restored).write(to: record, options: .withoutOverwriting)
            }
            if !exists {
                do {
                    try self.copy(at: snapshot.snapshotURL, to: destination)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
                } catch {
                    // 文件复制未成功时不留下可认领外来同名文件的归属记录。
                    if !hasRecord { try? FileManager.default.removeItem(at: record) }
                    throw error
                }
            }
            guard try hash(destination.path) == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
            let result = try await capture(document: destination, owner: snapshot.taskID)
            guard result.contentVersion == snapshot.contentVersion, result.roles == snapshot.roles,
                  result.pixelSize == snapshot.pixelSize, result.structureSummary == snapshot.structureSummary else { throw WorkflowBridgeError.staleSource }
            return result
        }
    }
    /// 人工补齐三层后，只接纳未改动底图像素、范围和 ICC 的保存结果；未决自动写入须另行明确接纳。
    func adoptManualMask(document: URL, owner: UUID) async throws -> PSDSnapshot {
        try await withLease("adoptManualMask", owner: owner, savedRead: true, document: document) {
            let record = ownershipURL(document)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
            try requireResolvedWrite(ownership)
            guard ownership.roles == nil, ownership.pendingInstall == nil, let initial = ownership.initialStackVersion else {
                throw WorkflowBridgeError.invalidStructure
            }
            let original = try outputDirectory("snapshots", owner: owner).appendingPathComponent("\(initial).psd")
            guard try hash(original.path) == initial else { throw WorkflowBridgeError.staleSource }
            let before = try hash(document.path)
            let current = try await invoke(Self.inspectScript(document: document))
            let baseMetadata = try await invoke(Self.inspectScript(document: original))
            guard let roles = current.roles, roles.isValid, baseMetadata.roles == nil,
                  current.width == baseMetadata.width, current.height == baseMetadata.height,
                  current.profile == baseMetadata.profile else { throw WorkflowBridgeError.invalidStructure }
            let folder = try outputDirectory("manual-mask/\(UUID())", owner: owner)
            let staged = folder.appendingPathComponent("verified.psd")
            try self.copy(at: document, to: staged)
            guard try hash(staged.path) == before, try hash(document.path) == before else { throw WorkflowBridgeError.staleSource }
            var candidate = ownership; candidate.roles = roles
            try JSONEncoder().encode(candidate).write(to: ownershipURL(staged), options: .withoutOverwriting)
            let saved = try await capture(document: staged, owner: owner)
            let images = try await extractUnlocked(saved)
            let base = folder.appendingPathComponent("initial-base.png")
            _ = try await invoke(Self.exportScript(document: original, output: base, final: false, preserveProfile: true))
            let expected = try readRaster(base), actual = try readRaster(images.basePNG)
            guard expected.hasProfile, actual.hasProfile, expected.profileData == actual.profileData,
                  expected.orientation == 1, actual.orientation == 1, expected.size == actual.size,
                  expected.pixels == actual.pixels, images.coordinateOrigin == .zero,
                  images.pixelSize == CGSize(width: baseMetadata.width, height: baseMetadata.height) else {
                throw WorkflowBridgeError.invalidImage("人工抠图改变了 Stack 像素、ICC 或坐标范围，请从合成检查点重新补蒙版。")
            }
            try await validateSubjectMask(saved)
            let checked = try await invoke(Self.inspectScript(document: document))
            guard checked.roles == roles, checked.summary == current.summary,
                  try hash(document.path) == before else { throw WorkflowBridgeError.staleSource }
            ownership.roles = roles
            try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
            var accepted = saved; accepted.workingURL = document
            return accepted
        }
    }
    func stackWithInput(job: FocusStackJob, owner: UUID) async throws -> WorkflowStackPreparation {
        try await prepareStack(job: job, owner: owner, prepareInput: true)
    }
    func stack(job: FocusStackJob, owner: UUID) async throws -> PSDSnapshot {
        try await prepareStack(job: job, owner: owner, prepareInput: false).snapshot
    }
    private func prepareStack(job: FocusStackJob, owner: UUID, prepareInput: Bool) async throws -> WorkflowStackPreparation {
        try await withLease("stack", owner: owner, savedRead: false, document: job.destinationURL) {
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
            defer { if FileManager.default.fileExists(atPath: candidate.path) { try? FileManager.default.removeItem(at: candidate) } }
            let hook = prepareInput ? Self.stackInputExportScript(output: candidate) : nil
            let inScope = Self.taskDocument != nil
            let staged = inScope ? job.destinationURL : folder.appendingPathComponent("stack.psd")
            let record = ownershipURL(job.destinationURL)
            let sources = zip(job.sourceFiles, hashes).map { WorkflowSourceFile(url: $0.0.resolvingSymlinksInPath(), fingerprint: $0.1) }
            try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if inScope {
                // 先保留归属意图；保存响应丢失时禁止通过“文件存在”认领或覆盖。
                try JSONEncoder().encode(Ownership(owner: owner, sources: sources))
                    .write(to: record, options: .withoutOverwriting)
            }
            let ownedJob = FocusStackJob(id: job.id, sourceFiles: copiedSources, destinationURL: staged, butterflyName: job.butterflyName, side: job.side)
            let stackStarted = observationStart()
            do {
                defer { report("ps.stack-including-open-save-close", since: stackStarted) }
                do { try await stackProcessor(ownedJob, hook) }
                catch {
                    if inScope, FileManager.default.fileExists(atPath: staged.path) {
                        throw WorkflowBridgeError.interruptedWrite("合成保存状态不明，已保留工作 PSD 与归属记录，请人工检查。")
                    }
                    if inScope { try? FileManager.default.removeItem(at: record) }
                    throw error
                }
            }
            guard try job.sourceFiles.map({ try hash($0.path) }) == hashes else { throw WorkflowBridgeError.staleSource }
            // 移动操作拒绝后出现的同名冲突，不能借旧处理器的跳过行为接管归属未知的 PSD。
            let ownership = try Ownership(owner: owner, sources: sources, initialStackVersion: hash(staged.path))
            try JSONEncoder().encode(ownership).write(to: record, options: inScope ? .atomic : .withoutOverwriting)
            if !inScope {
                do { try FileManager.default.moveItem(at: staged, to: job.destinationURL) }
                catch { try? FileManager.default.removeItem(at: record); throw error }
            }
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
        try await withLease("refresh", owner: owner, savedRead: true, document: document) {
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
        try await withLease("validateStackInput", owner: snapshot.taskID, savedRead: true, document: snapshot.workingURL) {
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
        try await withLease("exportStack", owner: snapshot.taskID, savedRead: false, document: snapshot.workingURL) {
            try await verify(snapshot)
            let output = try outputDirectory("data/processed", owner: snapshot.taskID).appendingPathComponent("\(snapshot.contentVersion)-\(UUID()).png")
            let metadata = try await invoke(Self.exportScript(document: snapshot.snapshotURL, output: output, final: snapshot.finalRoles != nil))
            let raster = try readRaster(output)
            guard raster.size == snapshot.pixelSize, raster.orientation == 1, raster.hasProfile else {
                throw WorkflowBridgeError.invalidImage("堆栈 PNG 尺寸、方向或 ICC 缺失")
            }
            return try StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: output, fingerprint: hash(output.path),
                pixelSize: raster.size, orientation: raster.orientation, colorProfile: raster.profileName ?? metadata.profile, validBackgroundAlphaURL: output)
        }
    }
    // MARK: - 蒙版事务与发布恢复
    func installMatte(snapshot: PSDSnapshot, matte: MatteArtifact, createFinishedLayer _: Bool = false) async throws -> PSDSnapshot {
        try await install(snapshot: snapshot, matte: matte)
    }
    func selectSubject(snapshot: PSDSnapshot) async throws -> PSDSnapshot {
        try await install(snapshot: snapshot, matte: nil)
    }
    private func install(snapshot: PSDSnapshot, matte: MatteArtifact?) async throws -> PSDSnapshot {
        try await withLease("install", owner: snapshot.taskID, savedRead: false, document: snapshot.workingURL) {
            let record = ownershipURL(snapshot.workingURL)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            guard ownership.owner == snapshot.taskID else { throw WorkflowBridgeError.ownershipConflict }
            try requireResolvedWrite(ownership)
            if let pending = ownership.pendingInstall {
                if Self.taskDocument != nil {
                    throw WorkflowBridgeError.interruptedWrite("尚有暂存抠图发布事务，请先检查保存结果，不能在连续文档中替换打开的 PSD。")
                }
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
            if matte == nil, Self.taskDocument != nil {
                return try await installSubjectInPlace(snapshot: snapshot, ownership: ownership)
            }
            // 先在独立副本中准备并校验，失败时不会改变工作 PSD 及其归属。
            let staged = try outputDirectory("install/\(UUID())", owner: snapshot.taskID).appendingPathComponent("result.psd")
            try self.copy(at: snapshot.snapshotURL, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
            try JSONEncoder().encode(ownership).write(to: ownershipURL(staged), options: .withoutOverwriting)
            let originalOwnership = ownership
            let prepared = try await withOpenDocument(at: staged) {
                let metadata = try await invoke(Self.installScript(document: staged, alpha: matte?.alphaURL))
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
    private func requireResolvedWrite(_ ownership: Ownership) throws {
        if let pending = ownership.pendingMutation {
            throw WorkflowBridgeError.interruptedWrite("\(pending.operation == "subject" ? "抠图" : "旋转裁切")保存结果尚未核验。已保留步骤前快照和工作 PSD，请在 Photoshop 检查后人工接纳，不能直接重复处理。")
        }
    }
    private func installSubjectInPlace(snapshot: PSDSnapshot, ownership: Ownership) async throws -> PSDSnapshot {
        let record = ownershipURL(snapshot.workingURL)
        var updating = ownership
        updating.pendingMutation = PendingMutation(sourceVersion: snapshot.contentVersion, operation: "subject")
        try JSONEncoder().encode(updating).write(to: record, options: .atomic)
        do {
            try await installCheckpoint(.prepared)
            let metadata = try await invoke(Self.installScript(document: snapshot.workingURL, alpha: nil))
            guard let roles = metadata.roles, roles.isValid else { throw WorkflowBridgeError.invalidStructure }
            updating.roles = roles
            try JSONEncoder().encode(updating).write(to: record, options: .atomic)
            let saved = try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
            try await validateSubjectMask(saved)
            guard try hash(snapshot.workingURL.path) == saved.contentVersion else { throw WorkflowBridgeError.staleSource }
            updating.pendingMutation = nil
            updating.subjectPublication = SubjectPublication(sourceVersion: snapshot.contentVersion, resultVersion: saved.contentVersion)
            try JSONEncoder().encode(updating).write(to: record, options: .atomic)
            try await installCheckpoint(.published)
            return saved
        } catch {
            // 凭据已完成时允许下一次精确接纳；其余情况保留现场，不回滚、不重复色阶。
            if updating.pendingMutation == nil { throw error }
            if (try? await verify(snapshot)) != nil {
                try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
                throw error
            }
            throw WorkflowBridgeError.interruptedWrite("抠图写入未完成核验：\(error.localizedDescription)")
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
        try await withLease("extract", owner: snapshot.taskID, savedRead: true, document: snapshot.workingURL) {
            try await verify(snapshot)
            return try await extractUnlocked(snapshot)
        }
    }
    func applyGeometry(snapshot: PSDSnapshot, solution: GeometrySolution, createFinishedLayer _: Bool = false) async throws -> PSDSnapshot {
        try await withLease("geometry", owner: snapshot.taskID, savedRead: false, document: snapshot.workingURL) {
            let record = ownershipURL(snapshot.workingURL)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            guard ownership.owner == snapshot.taskID else { throw WorkflowBridgeError.ownershipConflict }
            try requireResolvedWrite(ownership)
            if let completed = ownership.geometryPublication, completed.sourceVersion == snapshot.contentVersion {
                guard completed.solution == solution, completed.result.workingURL == snapshot.workingURL,
                      completed.result.taskID == snapshot.taskID,
                      try hash(snapshot.snapshotURL.path) == completed.sourceVersion else { throw WorkflowBridgeError.staleSource }
                try await verify(completed.result)
                _ = try await extractUnlocked(completed.result)
                return completed.result
            }
            return try await withOpenDocument(at: snapshot.workingURL) {
                try await verify(snapshot)
                guard solution.sourceVersion == snapshot.contentVersion, solution.isApplicable,
                      solution.angleDegrees.isFinite, solution.sourceCropRect.width > 0, solution.sourceCropRect.height > 0,
                      solution.sourceCropRect.size == solution.outputSize, snapshot.roles != nil else { throw WorkflowBridgeError.staleSource }
                ownership.pendingMutation = PendingMutation(sourceVersion: snapshot.contentVersion, operation: "geometry")
                try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
                do {
                    _ = try await invoke(Self.geometryScript(document: snapshot.workingURL, solution: solution))
                    let saved = try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
                    guard saved.pixelSize == solution.outputSize else { throw WorkflowBridgeError.invalidImage("裁切读回尺寸不一致") }
                    _ = try await extractUnlocked(saved)
                    guard try hash(snapshot.workingURL.path) == saved.contentVersion else { throw WorkflowBridgeError.staleSource }
                    ownership.pendingMutation = nil
                    ownership.geometryPublication = GeometryPublication(sourceVersion: snapshot.contentVersion, solution: solution, result: saved)
                    try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
                    return saved
                } catch {
                    throw WorkflowBridgeError.interruptedWrite("旋转裁切写入未完成核验：\(error.localizedDescription)")
                }
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
        try await withLease("finalize",owner: owner,savedRead: true, document: document) {
            try await capture(document: document,owner: owner,final: true)
        }
    }
    func verifyManualSaveOwnership(document: URL, owner: UUID) throws {
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(document)))
        guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
        guard ownership.pendingInstall == nil, ownership.pendingMutation == nil else {
            throw WorkflowBridgeError.interruptedWrite("请先处理原步骤的保存凭据")
        }
    }

    func prepareAcceptedFinalPSD(_ accepted: WorkflowAcceptedFinalPSD) async throws -> (PSDSnapshot, RoleImages) {
        try await withLease("prepareFinalPSD", owner: accepted.taskID, savedRead: false, document: accepted.workingURL) {
            func verifyFiles() throws {
                try verifyManualSaveOwnership(document: accepted.workingURL, owner: accepted.taskID)
                guard try hash(accepted.workingURL.path) == accepted.contentVersion,
                      try hash(accepted.snapshotURL.path) == accepted.contentVersion else { throw WorkflowBridgeError.staleSource }
            }
            try verifyFiles()
            let metadata = try await invoke(Self.inspectScript(document: accepted.snapshotURL, final: true))
            guard metadata.finalRoles?.isValid == true, metadata.width > 0, metadata.height > 0 else {
                throw WorkflowBridgeError.invalidStructure
            }
            let snapshot = PSDSnapshot(taskID: accepted.taskID, workingURL: accepted.workingURL,
                snapshotURL: accepted.snapshotURL, contentVersion: accepted.contentVersion,
                pixelSize: CGSize(width: metadata.width, height: metadata.height), roles: nil,
                structureSummary: metadata.summary, finalRoles: metadata.finalRoles)
            let roles = try await extractUnlocked(snapshot)
            try verifyFiles()
            return (snapshot, roles)
        }
    }

    // 观察请求只遍历文档，不触碰当前文档、打开文件或修改 Photoshop 设置。
    func openDocuments() async throws -> [WorkflowOpenPhotoshopDocument] {
        struct Entry: Decodable {
            let path: String?
            let documentID: Int
            let saved: Bool

            private enum CodingKeys: CodingKey { case path, documentID, saved }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                path = try values.decode(String?.self, forKey: .path)
                documentID = try values.decode(Int.self, forKey: .documentID)
                saved = try values.decode(Bool.self, forKey: .saved)
            }
        }
        let result = try await documentListRunner(Self.openDocumentsScript)
        let entries = try JSONDecoder().decode([Entry].self, from: Data(result.utf8))
        guard entries.allSatisfy({ $0.documentID > 0 && ($0.path?.hasPrefix("/") ?? true) }),
              Set(entries.map { $0.documentID }).count == entries.count else {
            throw WorkflowBridgeError.photoshop("打开文档列表不完整")
        }
        let documents = entries.compactMap { entry in
            entry.path.map { WorkflowOpenPhotoshopDocument(url: URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL,
                                                            documentID: entry.documentID, saved: entry.saved) }
        }
        guard Set(documents.map { $0.url }).count == documents.count else {
            throw WorkflowBridgeError.photoshop("多个 Photoshop 文档使用同一个工作路径")
        }
        return documents
    }

    private static let openDocumentsScript = #"""
    (function() {
        function quotePath(path) {
            return '"' + path.replace(/["\\\x00-\x1f]/g, function(c) {
                return '\\u' + ('0000' + c.charCodeAt(0).toString(16)).slice(-4);
            }) + '"';
        }
        var list = [];
        for (var i = 0; i < app.documents.length; i++) {
            var doc = app.documents[i], ref = new ActionReference(), fileKey = stringIDToTypeID('fileReference');
            ref.putIdentifier(charIDToTypeID('Dcmn'), doc.id);
            var meta = executeActionGet(ref);
            // 未命名文档没有文件路径；读取错误直接使整次观察失败。
            var path = meta.hasKey(fileKey) ? quotePath(meta.getPath(fileKey).fsName) : 'null';
            list.push('{"path":' + path + ',"documentID":' + doc.id + ',"saved":' + doc.saved + '}');
        }
        return '[' + list.join(',') + ']';
    }());
    """#

    private static func executeInRunningPhotoshop(_ script: String) async throws -> String {
        try await Task.detached {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.adobe.Photoshop")
                .filter { !$0.isTerminated }
            guard let application = instances.first else { throw WorkflowBridgeError.photoshopNotRunning }
            guard instances.count == 1 else { throw WorkflowBridgeError.photoshop("同时运行多个 Photoshop，无法确认打开的文档") }
            // 以已运行的进程为目标，避免按应用名称发送事件时自动启动 Photoshop。
            let target = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
            let event = NSAppleEventDescriptor(eventClass: 0x6D697363, eventID: 0x446A784D,
                                               targetDescriptor: target, returnID: -1, transactionID: 0) // misc/DjxM
            event.setParam(NSAppleEventDescriptor(string: script), forKeyword: keyDirectObject)
            let reply: NSAppleEventDescriptor
            do {
                reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 3)
            } catch {
                throw WorkflowBridgeError.photoshop(error.localizedDescription)
            }
            if let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, code != 0 {
                throw WorkflowBridgeError.photoshop(reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "Apple Event \(code)")
            }
            guard let result = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
                throw WorkflowBridgeError.photoshop("无法读取打开文档列表")
            }
            return result
        }.value
    }

    /// 仅由明确的人工“采用当前结果”动作调用；普通刷新不会删除自动写入意图。
    func acknowledgeManualResult(snapshot: PSDSnapshot) async throws {
        try await withLease("acknowledgeManual", owner: snapshot.taskID, savedRead: true, document: snapshot.workingURL) {
            try await verify(snapshot)
            let final = try await capture(document: snapshot.workingURL, owner: snapshot.taskID, final: true)
            guard final.contentVersion == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
            _ = try await extractUnlocked(final)
            let record = ownershipURL(snapshot.workingURL)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            guard ownership.owner == snapshot.taskID, try hash(snapshot.workingURL.path) == snapshot.contentVersion else {
                throw WorkflowBridgeError.staleSource
            }
            if ownership.pendingMutation != nil {
                // 保存人工接纳前的完整意图，供后续诊断；不移除任何 PSD 快照或旧版本。
                let receipt = try outputDirectory("manual-recovery", owner: snapshot.taskID).appendingPathComponent("\(UUID()).json")
                try JSONEncoder().encode(ownership).write(to: receipt, options: .withoutOverwriting)
                ownership.pendingMutation = nil
                ownership.subjectPublication = nil
                ownership.geometryPublication = nil
                try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
            }
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
        let held = Self.openedDocument?.url == document.resolvingSymlinksInPath() || Self.taskDocument?.url == document.resolvingSymlinksInPath()
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
    private func withLease<T: Sendable>(_ name: String, owner: UUID, savedRead: Bool, document: URL,
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
        if let scope = Self.taskDocument {
            guard scope.owner == owner, scope.url == document.resolvingSymlinksInPath(), scope.coordinator === coordinator else {
                throw WorkflowBridgeError.ownershipConflict
            }
            return try await body()
        }
        if savedRead { return try await coordinator.readSaved(owner: owner, operation: body) }
        return try await coordinator.run(owner: owner, operation: body)
    }
    /// 单面步骤连续持有租约。作用域只借用已保存的用户文档；自己打开/创建的文档才在结束时关闭。
    func withTaskDocument<T: Sendable>(owner: UUID, document: URL,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let path = document.resolvingSymlinksInPath()
        if let current = Self.taskDocument {
            guard current.owner == owner, current.url == path, current.coordinator === coordinator else {
                throw WorkflowBridgeError.ownershipConflict
            }
            return try await operation()
        }
        let scope = TaskDocument(owner: owner, url: path, token: "workflowTask_" + UUID().uuidString, coordinator: coordinator)
        return try await coordinator.run(owner: owner) {
            let result: Result<T, Error>
            do { result = .success(try await Self.$taskDocument.withValue(scope) { try await operation() }) }
            catch { result = .failure(error) }
            // 取消不能跳过释放检查；脏文档保留现场，并把错误交给队列暂停处理。
            _ = try await Task.detached {
                try await invoke(Self.releaseTaskDocumentScript(scope))
            }.value
            return try result.get()
        }
    }
    /// 仅在已持有协调器租约时调用，文档句柄不得超出本次服务作用域。
    private func withOpenDocument<T: Sendable>(at url: URL, operation: @Sendable () async throws -> T) async throws -> T {
        if let scope = Self.taskDocument, scope.url == url.resolvingSymlinksInPath() { return try await operation() }
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
        let scope = Self.taskDocument.map { Self.taskDocumentScopeScript($0) } ?? Self.openedDocument.map { Self.documentScopeScript($0) } ?? ""
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
    private static func registerTaskDocumentScript(_ scope: TaskDocument, document: String, owned: String) -> String {
        """
        var state=new ActionDescriptor();
        state.putInteger(stringIDToTypeID('documentID'),\(document).id);
        state.putString(stringIDToTypeID('path'),\(quote(scope.url.path)));
        state.putString(stringIDToTypeID('nativePath'),\(document).fullName.fsName);
        state.putBoolean(stringIDToTypeID('owned'),\(owned));
        app.putCustomOptions(\(quote(scope.token)),state,false);
        """
    }
    private static func stackDocumentHandoffScript(_ scope: TaskDocument) -> String {
        registerTaskDocumentScript(scope, document: "stackDocument", owned: "true")
    }
    private static func taskDocumentScopeScript(_ scope: TaskDocument) -> String {
        heldDocumentScript(scope.url, token: scope.token, documentID: nil) + """
        var wfTaskUnboundOpen=wfOpen;
        wfOpen=function(path){
            if(new File(path).fsName!==new File(\(quote(scope.url.path))).fsName)return wfTaskUnboundOpen(path);
            var exists=false;try{app.getCustomOptions(\(quote(scope.token)));exists=true;}catch(e){}
            if(exists){var held=wfHeldDocument();app.activeDocument=held;return {doc:held,owned:false};}
            var opened=wfTaskUnboundOpen(path);
            \(registerTaskDocumentScript(scope, document: "opened.doc", owned: "opened.owned"))
            return {doc:opened.doc,owned:false};
        };
        """
    }
    private static func releaseTaskDocumentScript(_ scope: TaskDocument) -> String {
        heldDocumentScript(scope.url, token: scope.token, documentID: nil) + """
        var exists=false;try{app.getCustomOptions(\(quote(scope.token)));exists=true;}catch(e){}
        if(exists){var state=wfHeldState(),doc=wfHeldDocument();if(state.owned)wfCloseDocument(doc);app.eraseCustomOptions(\(quote(scope.token)));}
        return wfJSON({width:0,height:0,profile:'',summary:''});
        """
    }
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
    function wfHasMask(layer,includeVector) {
        var d=wfDescriptor(layer),user=stringIDToTypeID('hasUserMask'),vector=stringIDToTypeID('hasVectorMask');
        return (d.hasKey(user) && d.getBoolean(user)) ||
            (includeVector===true && d.hasKey(vector) && d.getBoolean(vector));
    }
    function wfBounds(layer) {
        var d=wfDescriptor(layer),key=stringIDToTypeID('boundsNoMask');
        if (!d.hasKey(key)) key=stringIDToTypeID('bounds');
        var b=d.getObjectValue(key);return [b.getUnitDoubleValue(stringIDToTypeID('left')),b.getUnitDoubleValue(stringIDToTypeID('top')),b.getUnitDoubleValue(stringIDToTypeID('right')),b.getUnitDoubleValue(stringIDToTypeID('bottom'))];
    }
    function wfIsPreviewBackground(layer) {
        return layer.typename==='ArtLayer' && (layer.name==='Background #74BFFF' || (layer.name==='BG' && layer.kind===LayerKind.SOLIDFILL));
    }
    function wfRoleLayer(layer,name) {
        return layer && layer.name===name && layer.typename==='ArtLayer' && layer.kind===LayerKind.NORMAL && !layer.grouped;
    }
    function wfRoles(doc) {
        var original=null,adjust=null,count=0;
        for(var i=0;i<doc.layers.length;i++) {
            var l=doc.layers[i];
            if(l.name==='原始堆栈' && l.typename==='LayerSet') { original=l;count++; }
            if(l.name==='共同调整' && l.typename==='LayerSet') { adjust=l;count++; }
        }
        if(count===0) return null;
        var background=doc.layers.length===3 ? doc.layers[2] : null;
        var validRoot=doc.layers.length===2 || (background && background.name==='BG' && wfIsPreviewBackground(background));
        if(count!==2 || !original || !adjust || !validRoot || adjust.layers.length!==3 ||
           adjust.opacity!==100 || wfHasMask(adjust,true)) throw new Error('WORKFLOW_STRUCTURE');
        var cutout=adjust.layers[0],origin=adjust.layers[1],base=adjust.layers[2];
        if(!wfRoleLayer(base,'Stack') || !wfRoleLayer(origin,'Keying_Origin') || !wfRoleLayer(cutout,'Keying_Level') ||
           wfHasMask(base,true) || !wfHasMask(origin) || !wfHasMask(cutout)) throw new Error('WORKFLOW_STRUCTURE');
        var b=wfBounds(base),c=wfBounds(cutout),o=wfBounds(origin);
        for(var k=0;k<4;k++) if(Math.abs(b[k]-c[k])>0.1 || Math.abs(b[k]-o[k])>0.1) throw new Error('WORKFLOW_STRUCTURE');
        return {original:original,adjust:adjust,base:base,cutout:cutout,ids:{originalStackGroup:String(original.id),adjustmentGroup:String(adjust.id),baseLayer:String(base.id),cutoutLayer:String(cutout.id),mask:String(cutout.id)+':userMask'}};
    }
    function wfFinalRoles(doc) {
        var group=null,count=0;
        for(var i=0;i<doc.layers.length;i++)if(doc.layers[i].name==='共同调整'){group=doc.layers[i];count++;}
        if(count!==1 || group.typename!=='LayerSet')throw new Error('需要唯一的“共同调整”图层组');
        var roles={};
        for(var j=0;j<group.layers.length;j++) {
            var layer=group.layers[j],name=layer.name;
            if(name==='Stack' || name==='Keying_Origin') {
                if(roles[name] || !wfRoleLayer(layer,name))throw new Error('共同调整中需要唯一且未剪贴的像素图层 '+name);
                roles[name]=layer;
            }
        }
        var base=roles.Stack,cutout=group.layers[0],origin=roles.Keying_Origin;
        if(!base || wfHasMask(base,true))throw new Error('共同调整中需要未加蒙版的像素图层 Stack');
        if(!origin || !wfHasMask(origin))throw new Error('共同调整中需要保留原始蒙版的像素图层 Keying_Origin');
        if(!cutout || !wfRoleLayer(cutout,cutout.name) || cutout===base)throw new Error('共同调整的第一层需要是独立的透明成品像素图层');
        if(wfHasMask(group,true))throw new Error('请将共同调整组的蒙版落实到第一层后再刷新');
        if(group.opacity!==100)throw new Error('请将共同调整组的不透明度设为 100% 后再刷新');
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
    // 只在导出副本中隔离角色，避免原始蒙版和预览背景混入结果。
    function wfShowRole(doc,group,role) {
        wfHideAll(doc);group.visible=true;
        for(var i=0;i<group.layers.length;i++)group.layers[i].visible=group.layers[i].id===role.id;
    }
    function wfSetLayerColor(layer,color) {
        var id=charIDToTypeID,ref=new ActionReference(),desc=new ActionDescriptor(),value=new ActionDescriptor();
        ref.putIdentifier(id('Lyr '),layer.id);desc.putReference(id('null'),ref);
        value.putEnumerated(id('Clr '),id('Clr '),id(color));desc.putObject(id('T   '),id('Lyr '),value);
        executeAction(id('setd'),desc,DialogModes.NO);
    }
    function wfApplyMaskLevels(layer) {
        // 色阶只改变副本的用户蒙版，原始蒙版与像素通道保持原样。
        wfSelectMask(layer);
        try {
            var id=charIDToTypeID,s=stringIDToTypeID,desc=new ActionDescriptor(),adjustment=new ActionDescriptor();
            var channel=new ActionReference(),input=new ActionList(),output=new ActionList(),adjustments=new ActionList();
            channel.putEnumerated(id('Chnl'),id('Chnl'),id('Msk '));
            adjustment.putReference(id('Chnl'),channel);
            input.putInteger(15);input.putInteger(240);adjustment.putList(id('Inpt'),input);
            adjustment.putDouble(id('Gmm '),1.0);
            output.putInteger(0);output.putInteger(255);adjustment.putList(id('Otpt'),output);
            adjustments.putObject(id('LvlA'),adjustment);desc.putList(id('Adjs'),adjustments);
            desc.putEnumerated(s('presetKind'),s('presetKindType'),s('presetKindCustom'));
            executeAction(id('Lvls'),desc,DialogModes.NO);
        }
        finally { wfSelectRGB(); }
    }
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
    private static func stackPNGBody(document: String, output: URL, final: Bool = false, preserveProfile: Bool = false) -> String {
        """
        var copy=null;
        try {copy=wfDuplicate(\(document));app.activeDocument=copy;var r=\(final ? "wfFinalRoles" : "wfRoles")(copy);
            if(r)wfShowRole(copy,r.adjust,r.base);
            else {for(var i=0;i<copy.layers.length;i++) if(wfIsPreviewBackground(copy.layers[i]))copy.layers[i].visible=false;}
            \(preserveProfile ? "wfRolePNG" : "wfStackPNG")(copy,\(quote(output.path)));return wfJSON(\(final ? "wfFinalMetadata" : "wfMetadata")(copy));
        }finally{if(copy)wfCloseDocument(copy);}
        """
    }
    private static func exportScript(document: URL, output: URL, final: Bool, preserveProfile: Bool = false) -> String {
        "var o=wfOpen(" + quote(document.resolvingSymlinksInPath().path) + ");try{" +
        stackPNGBody(document: "o.doc", output: output, final: final, preserveProfile: preserveProfile) + "}finally{wfClose(o);}"
    }
    // 在当前合成像素层上识别，空选区不能退化为全白蒙版。
    static let selectSubjectSelectionScript = """
        wfSelectRGB();doc.selection.deselect();
        var subject=new ActionDescriptor();subject.putBoolean(stringIDToTypeID('sampleAllLayers'),false);
        executeAction(stringIDToTypeID('autoCutout'),subject,DialogModes.NO);
        try { var subjectBounds=doc.selection.bounds; }
        catch(e) { throw new Error('Photoshop 未识别到主体，请检查合成底图'); }
        """
    private static func installScript(document: URL, alpha: URL?) -> String {
        let selection: String
        if let alpha {
            selection = """
            maskDoc=wfOpenFile(new File(\(quote(alpha.path))));var imported=maskDoc.channels[0].duplicate(doc);
            wfCloseDocument(maskDoc);maskDoc=null;
            app.activeDocument=doc;doc.activeLayer=origin;doc.selection.load(imported);
            """
        } else {
            selection = """
            app.activeDocument=copy;var imported=subjectSelection.duplicate(doc);app.activeDocument=doc;doc.activeLayer=origin;doc.selection.load(imported);
            """
        }
        let prepareSelection = alpha == nil ? """
            // 在可丢弃的合成副本上完成识别；未识别到主体不会把工作文档留在半写入状态。
            var workingDocument=doc;doc=copy;doc.activeLayer=merged;
            \(selectSubjectSelectionScript)
            var subjectSelection=copy.channels.add();copy.selection.store(subjectSelection);copy.selection.deselect();doc=workingDocument;
            """ : ""
        return """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null,maskDoc=null,doc=o.doc;
        var dialogs=app.displayDialogs;app.displayDialogs=DialogModes.NO;
        try {
            if(wfRoles(doc))throw new Error('WORKFLOW_STRUCTURE');
            copy=wfDuplicate(doc);app.activeDocument=copy;
            for(var i=copy.layers.length-1;i>=0;i--)if(wfIsPreviewBackground(copy.layers[i])){copy.layers[i].allLocked=false;copy.layers[i].remove();}
            // 透明辅助层让单层或单个可见组也能无损合并；只存在于可丢弃副本。
            copy.artLayers.add();copy.mergeVisibleLayers();var merged=copy.activeLayer;
            \(prepareSelection)
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
            app.activeDocument=doc;var base=doc.activeLayer;base.name='Stack';base.move(adjust,ElementPlacement.INSIDE);
            var origin=base.duplicate();origin.name='Keying_Origin';base.visible=false;origin.visible=true;doc.activeLayer=origin;
            \(selection)
            var make=new ActionDescriptor(),ref=new ActionReference();make.putClass(charIDToTypeID('Nw  '),charIDToTypeID('Chnl'));
            ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));make.putReference(charIDToTypeID('At  '),ref);
            make.putEnumerated(charIDToTypeID('Usng'),charIDToTypeID('UsrM'),charIDToTypeID('RvlS'));executeAction(charIDToTypeID('Mk  '),make,DialogModes.NO);
            doc.selection.deselect();if(typeof imported!=='undefined')imported.remove();wfSelectRGB();
            var cutout=origin.duplicate();cutout.name='Keying_Level';
            cutout.move(origin,ElementPlacement.PLACEBEFORE);
            if(\(alpha == nil ? "true" : "false"))wfApplyMaskLevels(cutout);
            wfSetLayerColor(cutout,'Rd  ');wfSetLayerColor(origin,'Grn ');wfSetLayerColor(base,'Bl  ');
            origin.visible=false;cutout.visible=true;doc.activeLayer=cutout;
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
            wfShowRole(copy,r.adjust,r.base);wfRolePNG(copy,\(quote(folder.appendingPathComponent("base.png").path)));
            wfShowRole(copy,r.adjust,r.cutout);wfRolePNG(copy,\(quote(folder.appendingPathComponent("cutout.png").path)));
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
            wfShowRole(copy,r.adjust,r.base);wfRolePNG(copy,\(quote(folder.appendingPathComponent("base.png").path)));
            wfShowRole(copy,r.adjust,r.cutout);wfRolePNG(copy,\(quote(folder.appendingPathComponent("cutout.png").path)));
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
    private static func geometryScript(document: URL, solution: GeometrySolution) -> String {
        let rect = solution.sourceCropRect
        return """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),doc=o.doc;
        try {
            var roles=wfRoles(doc);if(!roles)throw new Error('WORKFLOW_STRUCTURE');
            var bounds=wfBounds(roles.base),cx=(bounds[0]+bounds[2])/2,cy=(bounds[1]+bounds[3])/2;
            var px=\(solution.rotationPivot.x),py=\(solution.rotationPivot.y),angle=\(solution.angleDegrees),radians=angle*Math.PI/180;
            if(angle!==0){
                // 用完整底图固定组边界，旋转和位移同时作用于三层及其蒙版。
                var baseWasVisible=roles.base.visible;roles.base.visible=true;
                try { roles.adjust.rotate(angle,AnchorPosition.MIDDLECENTER); }
                finally { roles.base.visible=baseWasVisible; }
                var dx=px+(cx-px)*Math.cos(radians)-(cy-py)*Math.sin(radians)-cx;
                var dy=py+(cx-px)*Math.sin(radians)+(cy-py)*Math.cos(radians)-cy;
                roles.adjust.translate(UnitValue(dx,'px'),UnitValue(dy,'px'));
            }
            var d=new ActionDescriptor(),r=new ActionDescriptor();
            r.putUnitDouble(charIDToTypeID('Top '),charIDToTypeID('#Pxl'),\(rect.minY));r.putUnitDouble(charIDToTypeID('Left'),charIDToTypeID('#Pxl'),\(rect.minX));
            r.putUnitDouble(charIDToTypeID('Btom'),charIDToTypeID('#Pxl'),\(rect.maxY));r.putUnitDouble(charIDToTypeID('Rght'),charIDToTypeID('#Pxl'),\(rect.maxX));
            d.putObject(charIDToTypeID('T   '),charIDToTypeID('Rctn'),r);d.putUnitDouble(charIDToTypeID('Angl'),charIDToTypeID('#Ang'),0);
            d.putBoolean(charIDToTypeID('Dlt '),false);executeAction(charIDToTypeID('Crop'),d,DialogModes.NO);
            wfSave(doc);return wfJSON(wfMetadata(doc));
        }finally{wfClose(o);}
        """
    }
}
