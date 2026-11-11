// 定义照片工作流的批次、阶段、源文件、PSD 快照、几何与导出模型，并校验清单一致性和输出路径。

import Foundation
import CoreGraphics
import Darwin

// MARK: - 阶段与固定源映射
nonisolated enum WorkflowStage: String, Codable, CaseIterable, Sendable {
    case stack, matte, geometry, hd, png4k, derivatives
    static let processingStages: [Self] = [.stack, .matte, .geometry, .hd, .png4k]
}

nonisolated enum WorkflowSide: String, Codable, CaseIterable, Sendable {
    case front, back
    var fileSuffix: String { self == .front ? "D" : "V" }
}

nonisolated enum WorkflowAssetKind: String, Codable, CaseIterable, Sendable {
    case hd, png4k, xianyu, white1k, footage
    var stage: WorkflowStage {
        switch self {
        case .hd: .hd
        case .png4k: .png4k
        case .xianyu, .white1k, .footage: .derivatives
        }
    }
}

// 显式导出请求冻结保存版本与目标目录，供排队和重启恢复核对。
nonisolated enum WorkflowExportPolicy: String, Codable, CaseIterable, Sendable {
    case skipExisting, overwrite
    var title: String { self == .skipExisting ? "跳过已导出" : "覆盖已导出" }
}
nonisolated struct WorkflowExportRequest: Codable, Equatable, Sendable {
    var snapshotVersion: String
    var directory: URL
    var policy: WorkflowExportPolicy
}

nonisolated enum WorkflowStatus: String, Codable, Sendable {
    case pending, running, waitingReview, completed, failed, excluded
}

nonisolated struct WorkflowSourceFile: Codable, Equatable, Sendable {
    var url: URL
    /// 仅已排除标本的未校验历史源引用可以为空。
    var fingerprint: String
}

/// 每面冻结三张照片或一份已合成 PSD，不受队列位置或排除操作影响。
nonisolated struct WorkflowSources: Codable, Equatable, Sendable {
    var first: WorkflowSourceFile
    var second: WorkflowSourceFile?
    var third: WorkflowSourceFile?
    var files: [WorkflowSourceFile] { [first, second, third].compactMap { $0 } }
    var isPSD: Bool { second == nil && third == nil && first.url.pathExtension.lowercased() == "psd" }
}

nonisolated struct WorkflowStageRecord: Codable, Equatable, Sendable {
    var stage: WorkflowStage
    var state: WorkflowStatus = .pending
    var inputVersion: Int = 1
    var outputVersion: String?
    var confirmedVersion: String?
    /// 开始、取消、重试和失效时更新；异步结果必须匹配此修订号。
    var revision: Int = 0
    var error: String?
    var exclusionReason: String?
}

nonisolated struct WorkflowPreset: Codable, Equatable, Sendable {
    var version: Int = 1
    var fingerprint: String
}

nonisolated struct WorkflowPresets: Codable, Equatable, Sendable {
    var geometry = WorkflowPreset(fingerprint: "geometry-adaptive-margin-0.1-v1")
    var png4k = WorkflowPreset(fingerprint: "square-4096-margin-256-v1")
    var hd = WorkflowPreset(fingerprint: "jpeg-quality-0.82-v1")
}

// MARK: - 单面任务与批次记录
// MARK: - 人工精修的打开基线与保存凭据

nonisolated struct WorkflowPSDFileVersion: Codable, Equatable, Sendable {
    let hash: String
    let modificationDate: Date

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct WorkflowManualEdit: Codable, Equatable, Sendable {
    let sessionID: UUID
    let workingURL: URL
    let baseline: WorkflowPSDFileVersion
    var observedDocumentID: Int?
}

nonisolated struct WorkflowAcceptedFinalPSD: Codable, Equatable, Sendable {
    let taskID: UUID
    let sourceRevision: Int
    let workingURL: URL
    let snapshotURL: URL
    let contentVersion: String
}

nonisolated struct WorkflowOpenPhotoshopDocument: Equatable, Sendable {
    let url: URL
    let documentID: Int
    let saved: Bool
}

nonisolated struct WorkflowSideTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var side: WorkflowSide
    var sources: WorkflowSources
    var sourceRevision: Int = 1
    var records: [WorkflowStage: WorkflowStageRecord] = Dictionary(uniqueKeysWithValues:
        WorkflowStage.allCases.map { ($0, WorkflowStageRecord(stage: $0)) })
    var stackAttemptURL: URL?
    var checkpoints: [WorkflowStage: PSDSnapshot]?
    var manualAdoptionRequired: Bool?
    var geometryApplySourceVersion: String?
    var snapshot: PSDSnapshot?
    var geometryRequest: GeometryRequest = GeometryRequest()
    var geometrySolution: GeometrySolution?
    var roleImages: RoleImages?
    var squareLayout: SquareLayout = .png4k
    var artifacts: [WorkflowArtifact] = []
    var requestedExports: [WorkflowAssetKind: WorkflowExportRequest]?
    var exportNotes: [WorkflowAssetKind: String]?
    var manualEdit: WorkflowManualEdit?
    var manualEditError: String?
    var acceptedFinalPSD: WorkflowAcceptedFinalPSD?
    var finalPreparationError: String?
    /// 主动清理后只允许从相同归属与哈希的工作 PSD 重建缓存。
    var intermediatesCleared: Bool = false

    var finalPSDVersion: String? { acceptedFinalPSD?.contentVersion ?? snapshot?.contentVersion }
    var pendingFinalPSD: WorkflowAcceptedFinalPSD? {
        guard let acceptedFinalPSD else { return nil }
        if snapshot?.contentVersion == acceptedFinalPSD.contentVersion,
           snapshot?.snapshotURL == acceptedFinalPSD.snapshotURL,
           snapshot?.finalRoles?.isValid == true, roleImages?.isFinalized == true,
           roleImages?.snapshotVersion == acceptedFinalPSD.contentVersion { return nil }
        return acceptedFinalPSD
    }

    subscript(stage: WorkflowStage) -> WorkflowStageRecord {
        get { records[stage] ?? WorkflowStageRecord(stage: stage) }
        set { records[stage] = newValue }
    }
}

nonisolated struct WorkflowSpecimen: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var baseName: String
    var front: WorkflowSideTask
    var back: WorkflowSideTask
    var exclusionReason: String?
    var isExcluded: Bool { exclusionReason != nil }
}

nonisolated struct WorkflowOutputLocations: Codable, Equatable, Sendable {
    var hd: URL?
    var png4k: URL?
}

nonisolated struct WorkflowBatch: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 3
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID = UUID()
    var sourceDirectory: URL
    /// 冻结用户选择的名称；真实目录固定后，不再随入口链接重指改变生成位置。
    var sourceDirectoryName: String
    /// 保存内部批次记录与可恢复的工作数据，不代表用户选择的导出目录。
    var outputDirectory: URL
    var outputLocations: WorkflowOutputLocations?
    var specimens: [WorkflowSpecimen]
    var presets: WorkflowPresets = WorkflowPresets()
    var revision: Int = 0
    var isPaused: Bool = false
    var selectedExportKinds: Set<WorkflowAssetKind> = []
    var intermediateCleanupError: String?
    /// 同名批次在建批时固定隔离目录；恢复时不能再根据文件是否存在改变位置。
    var psdBatchSubdirectory: Bool = false
    private var sourcePSDDirectory: URL {
        sourceDirectory.resolvingSymlinksInPath().appendingPathComponent(sourceDirectoryName + "_psd",isDirectory: true)
    }
    var generatedPSDDirectory: URL {
        return psdBatchSubdirectory
            ? sourcePSDDirectory.appendingPathComponent("批次-\(id)",isDirectory: true)
            : sourcePSDDirectory
    }

    var sideTasks: [WorkflowSideTask] { specimens.flatMap { [$0.front, $0.back] } }
    var activeTasks: [WorkflowSideTask] { specimens.filter { !$0.isExcluded }.flatMap { [$0.front, $0.back] } }
    var manualReviewSessionID: UUID? { activeTasks.lazy.compactMap { $0.manualEdit?.sessionID }.first }

    func acceptedFinalURL(taskID: UUID, contentVersion: String) -> URL {
        outputDirectory.appendingPathComponent(".work/accepted-final/\(taskID)/\(contentVersion).psd")
    }

    func validateAcceptedFinalURL(_ url: URL, taskID: UUID, contentVersion: String) throws {
        let relative = ".work/accepted-final/\(taskID)/\(contentVersion).psd"
        let rooted = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(relative)
        guard WorkflowPSDFileVersion.isHash(contentVersion),
              url == acceptedFinalURL(taskID: taskID, contentVersion: contentVersion),
              Self.isContained(url, in: outputDirectory),
              url.resolvingSymlinksInPath().standardizedFileURL.path == rooted.path else {
            throw WorkflowStateError.invalidManifest("Invalid accepted PSD path")
        }
    }

    /// 从各面的持久记录推导阶段，使已确认的部分标本可以独立推进。
    var currentStage: WorkflowStage? {
        let stage = WorkflowStage.processingStages.first { stage in activeTasks.contains { $0[stage].state != .completed } }
        return stage == .hd ? .png4k : stage
    }
    var allSucceeded: Bool {
        !activeTasks.isEmpty && !selectedExportKinds.isEmpty && activeTasks.allSatisfy { task in
            task[.geometry].state == .completed && (task.requestedExports ?? [:]).allSatisfy { kind, _ in
                !selectedExportKinds.contains(kind) && task[kind.stage].state == .failed
            } &&
            !task.records.values.contains { $0.state == .running } &&
            [WorkflowStage.stack, .matte, .geometry].allSatisfy { task[$0].state == .completed } &&
            selectedExportKinds.allSatisfy { kind in
                task[kind.stage].state == .completed && task.artifacts.contains { $0.kind == kind && $0.state == .completed && $0.fileFingerprint == task[kind.stage].outputVersion }
            }
        }
    }
    func task(id: UUID) -> WorkflowSideTask? { sideTasks.first { $0.id == id } }

    func exportDirectory(for kind: WorkflowAssetKind) -> URL? {
        if let selected = kind == .hd ? outputLocations?.hd : kind == .png4k ? outputLocations?.png4k : nil { return selected }
        guard kind == .hd || kind == .png4k else { return nil }
        return sourceDirectory.appendingPathComponent(sourceDirectoryName + (kind == .hd ? "_堆栈原图" : "_4K_PNG"), isDirectory: true)
    }

    // MARK: - 输出路径与清单校验
    // 解析已有祖先再拼回未创建部分，避免符号链接让输出逃离授权目录。
    private static func canonicalComponents(_ url: URL) -> [String]? {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        let fm = FileManager.default
        // 目标尚不存在时，Foundation 不会解析中间路径的符号链接，因此先找到已存在的祖先。
        while !fm.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/", (try? fm.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else { return nil }
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        guard let resolved = realpath(ancestor.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).pathComponents + missing
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL, !url.pathComponents.contains(".."),
              let root = canonicalComponents(root), let destination = canonicalComponents(url) else { return false }
        return destination.count > root.count && destination.prefix(root.count).elementsEqual(root)
    }

    private func validateExportRoot(_ kind: WorkflowAssetKind) throws {
        if let root = exportDirectory(for: kind) {
            let work = outputDirectory.appendingPathComponent(".work", isDirectory: true)
            guard root.resolvingSymlinksInPath().standardizedFileURL != work.resolvingSymlinksInPath().standardizedFileURL,
                  !Self.isContained(root, in: work) else {
                throw WorkflowStateError.invalidManifest("导出目录不能位于批次中转目录内")
            }
        }
        let selected = kind == .hd ? outputLocations?.hd : outputLocations?.png4k
        if selected == nil, let root = exportDirectory(for: kind),
           !Self.isContained(root,in: sourceDirectory) {
            throw WorkflowStateError.invalidManifest("默认导出目录不能通过链接指向素材目录之外")
        }
    }

    func validateArtifactURL(_ url: URL, kind: WorkflowAssetKind) throws {
        try validateExportRoot(kind)
        let work = outputDirectory.appendingPathComponent(".work", isDirectory: true)
        guard let root = exportDirectory(for: kind), Self.isContained(url, in: root),
              url.resolvingSymlinksInPath().standardizedFileURL != work.resolvingSymlinksInPath().standardizedFileURL,
              !Self.isContained(url, in: work) else {
            throw WorkflowStateError.invalidManifest("Export destination escapes its selected directory")
        }
    }

    func validateOutputURL(_ url: URL) throws {
        // 先验证工作子目录，避免链接借内部记录／导出目录的授权绕过本批次的边界。
        if url.standardizedFileURL.pathComponents.starts(with: sourcePSDDirectory.standardizedFileURL.pathComponents) {
            guard isGeneratedPSDURL(url) else { throw WorkflowStateError.invalidManifest("工作 PSD 路径不属于本批次或包含链接") }
            return
        }
        if Self.isContained(url, in: outputDirectory) { return }
        if isGeneratedPSDURL(url) { return }
        throw WorkflowStateError.invalidManifest("Output destination is outside the batch's authorized locations")
    }

    /// 工作副本可位于批次隔离或重新处理目录；仅授权本批次的固定文件名，不能放开整个原图目录。
    private func isGeneratedPSDURL(_ url: URL) -> Bool {
        let root = sourcePSDDirectory.standardizedFileURL
        guard Self.isContained(root,in: sourceDirectory),
              Self.isContained(url,in: root), Self.isContained(url,in: sourceDirectory) else { return false }
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: root.pathComponents) else { return false }
        guard let source = Self.canonicalComponents(sourceDirectory),
              Self.canonicalComponents(url) == source + [sourceDirectoryName + "_psd"] + Array(components.dropFirst(root.pathComponents.count)) else { return false }
        var relative = Array(components.dropFirst(root.pathComponents.count))
        guard let name = relative.popLast(), specimens.contains(where: { specimen in
            WorkflowSide.allCases.contains { side in
                name == "\(specimen.baseName)_\(side.fileSuffix).psd"
            }
        }) else { return false }
        if psdBatchSubdirectory {
            guard relative.first == "批次-\(id)" else { return false }
            relative.removeFirst()
        }
        if relative.isEmpty { return true }
        guard relative.count == 1, relative[0].hasPrefix("重新处理-") else { return false }
        return UUID(uuidString: String(relative[0].dropFirst("重新处理-".count))) != nil
    }
    private static func isSafeBaseName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." &&
            !name.contains("/") && !name.contains("\\") && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion, revision >= 0, sourceDirectory.isFileURL, outputDirectory.isFileURL,
              Self.isSafeBaseName(sourceDirectoryName), sourceDirectory.standardizedFileURL == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw WorkflowStateError.invalidManifest("此批次使用旧流程或清单已损坏，请新建批次；旧文件未作修改")
        }
        guard selectedExportKinds.isSubset(of: [.hd, .png4k]) else { throw WorkflowStateError.invalidManifest("Invalid selected exports") }
        for folder in [".work"] {
            try validateOutputURL(outputDirectory.appendingPathComponent(folder))
        }
        for kind in [WorkflowAssetKind.hd, .png4k] { try validateExportRoot(kind) }
        for directory in [outputLocations?.hd, outputLocations?.png4k].compactMap({ $0 }) {
            guard directory.isFileURL else { throw WorkflowStateError.invalidManifest("Invalid export directory") }
        }
        let identities = specimens.map(\.id) + sideTasks.map(\.id)
        guard Set(identities).count == identities.count else { throw WorkflowStateError.invalidManifest("Duplicate task identity") }
        let edits = sideTasks.compactMap(\.manualEdit)
        guard Set(edits.map(\.sessionID)).count <= 1,
              Set(edits.map { $0.workingURL.resolvingSymlinksInPath().path }).count == edits.count else {
            throw WorkflowStateError.invalidManifest("Invalid batch review session")
        }
        for specimen in specimens {
            guard Self.isSafeBaseName(specimen.baseName),
                  specimen.front.side == .front, specimen.back.side == .back,
                  specimen.exclusionReason == nil || specimen.exclusionReason?.isEmpty == false else {
                throw WorkflowStateError.invalidManifest("Invalid specimen mapping")
            }
            for task in [specimen.front, specimen.back] {
                if let attempt = task.stackAttemptURL {
                    guard isGeneratedPSDURL(attempt) else { throw WorkflowStateError.invalidManifest("工作 PSD 不属于当前批次目录") }
                }
                if let saved = task.snapshot {
                    guard isGeneratedPSDURL(saved.workingURL) else { throw WorkflowStateError.invalidManifest("工作 PSD 不属于当前批次目录") }
                }
                for artifact in task.artifacts {
                    try validateArtifactURL(artifact.url, kind: artifact.kind)
                }
                guard task.sourceRevision > 0, Set(task.records.keys) == Set(WorkflowStage.allCases),
                      task.sources.isPSD || task.sources.files.count == 3,
                      task.sources.files.allSatisfy({ $0.url.isFileURL && (specimen.isExcluded || !$0.fingerprint.isEmpty) }) else {
                    throw WorkflowStateError.invalidManifest("Incomplete source or stage records")
                }
                if task.sources.isPSD {
                    guard Self.isContained(task.sources.first.url,in: sourceDirectory),
                          task.stackAttemptURL.map({ Self.canonicalComponents($0) != Self.canonicalComponents(task.sources.first.url) }) ?? true,
                          task.snapshot.map({ Self.canonicalComponents($0.workingURL) != Self.canonicalComponents(task.sources.first.url) }) ?? true,
                          task.stackAttemptURL == nil || isGeneratedPSDURL(task.stackAttemptURL!),
                          task.snapshot == nil || isGeneratedPSDURL(task.snapshot!.workingURL) else {
                        throw WorkflowStateError.invalidManifest("Imported PSD must retain its frozen source path")
                    }
                }
                for stage in WorkflowStage.allCases {
                    let record = task[stage]
                    guard record.stage == stage, record.inputVersion > 0, record.revision >= 0,
                          (record.confirmedVersion == nil || record.confirmedVersion == record.outputVersion),
                          (!specimen.isExcluded || (record.state == .excluded && record.exclusionReason == specimen.exclusionReason)) else {
                        throw WorkflowStateError.invalidManifest("Inconsistent stage record")
                    }
                    if record.state == .completed || record.state == .waitingReview {
                        guard record.outputVersion?.isEmpty == false else { throw WorkflowStateError.invalidManifest("Missing output version") }
                    }
                    if (stage == .geometry || stage == .png4k) && record.state == .completed {
                        guard record.confirmedVersion == record.outputVersion else { throw WorkflowStateError.invalidManifest("Missing required confirmation") }
                    }
                }
                if task[.matte].state == .completed || task[.matte].state == .waitingReview {
                    guard let snapshot = task.snapshot, snapshot.taskID == task.id,
                          (snapshot.roles?.isValid == true || snapshot.finalRoles?.isValid == true),
                          snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0 else {
                        throw WorkflowStateError.invalidManifest("Matte requires a saved PSD with role identities")
                    }
                }
                if let review = task.manualEdit {
                    guard !specimen.isExcluded,
                          review.workingURL == task.snapshot?.workingURL,
                          WorkflowPSDFileVersion.isHash(review.baseline.hash),
                          review.baseline.modificationDate.timeIntervalSinceReferenceDate.isFinite,
                          (review.observedDocumentID ?? 1) > 0,
                          task[.stack].state == .completed, task[.matte].state == .completed,
                          [.waitingReview, .completed].contains(task[.geometry].state) else {
                        throw WorkflowStateError.invalidManifest("Invalid PSD review baseline")
                    }
                    try validateOutputURL(review.workingURL)
                }
                if let accepted = task.acceptedFinalPSD {
                    guard !specimen.isExcluded,
                          accepted.taskID == task.id, accepted.sourceRevision == task.sourceRevision,
                          accepted.workingURL == task.snapshot?.workingURL,
                          task[.geometry].state == .completed,
                          task[.geometry].confirmedVersion == accepted.contentVersion else {
                        throw WorkflowStateError.invalidManifest("Invalid accepted PSD version")
                    }
                    try validateOutputURL(accepted.workingURL)
                    try validateAcceptedFinalURL(accepted.snapshotURL, taskID: task.id, contentVersion: accepted.contentVersion)
                }
                if task[.geometry].state == .completed {
                    guard task.acceptedFinalPSD != nil else { throw WorkflowStateError.invalidManifest("Final confirmation requires an accepted saved PSD") }
                }
                if task[.geometry].state == .completed && task.pendingFinalPSD == nil {
                    guard task.snapshot?.finalRoles?.isValid == true,task.roleImages?.isFinalized == true,
                          task[.geometry].confirmedVersion == task.snapshot?.contentVersion else {
                        throw WorkflowStateError.invalidManifest("Final export requires confirmation of the saved final PSD")
                    }
                }
                guard task.artifacts.allSatisfy({ $0.ownerTaskID == task.id }) else {
                    throw WorkflowStateError.invalidManifest("Artifact owned by another side task")
                }
            }
        }
    }
}

// MARK: - 产物与保存快照
nonisolated struct WorkflowArtifact: Codable, Equatable, Sendable {
    var ownerTaskID: UUID
    var kind: WorkflowAssetKind
    var url: URL
    var sourceFingerprint: String
    var presetFingerprint: String
    var fileFingerprint: String
    var state: WorkflowStatus
}

nonisolated struct PSDRoleIdentifiers: Codable, Equatable, Sendable {
    var originalStackGroup: String
    var adjustmentGroup: String
    var baseLayer: String
    var cutoutLayer: String
    var mask: String
    var isValid: Bool {
        let identifiers = [originalStackGroup, adjustmentGroup, baseLayer, cutoutLayer, mask]
        return identifiers.allSatisfy { !$0.isEmpty } && Set(identifiers).count == identifiers.count
    }
}

nonisolated struct PSDSnapshot: Codable, Equatable, Sendable {
    var taskID: UUID
    var workingURL: URL
    var snapshotURL: URL
    var contentVersion: String
    var pixelSize: CGSize
    /// 仅完成堆栈的快照可以没有角色标识，抠图阶段完成后则必须具备。
    var roles: PSDRoleIdentifiers?
    var structureSummary: String
    var finalRoles: FinalPSDIdentifiers?
    var cleanupReportURL: URL?
    var cleanupReportFingerprint: String?
    var cleanupAlgorithmVersion: Int?
    /// 报告只对应此自动保存版本；人工保存后失效。
    var cleanupSnapshotVersion: String?
    var cleanupGeometry: GeometrySolution?
}

nonisolated struct StackPNG: Codable, Equatable, Sendable {
    var snapshotVersion: String
    var pngURL: URL
    var fingerprint: String
    var pixelSize: CGSize
    var orientation: Int
    var colorProfile: String
    /// 通过 alpha 通道判断源背景有效性；可直接使用 RGBA PNG，不能使用其亮度。
    var validBackgroundAlphaURL: URL?
}

nonisolated struct MatteArtifact: Codable, Equatable, Sendable {
    var inputPNGFingerprint: String
    var alphaURL: URL
    var alphaFingerprint: String
    var cutoutURL: URL
    var cutoutFingerprint: String
    var orientation: Int
    var pixelSize: CGSize
    var cleanupReportURL: URL?
    var cleanupReportFingerprint: String?
    var cleanupAlgorithmVersion: Int?
}

/// 人工定稿仅锁定最终导出来源，允许替换图层和应用蒙版。
nonisolated struct FinalPSDIdentifiers: Codable, Equatable, Sendable {
    var adjustmentGroup: String
    var baseLayer: String
    var cutoutLayer: String
    var isValid: Bool {
        let ids = [adjustmentGroup,baseLayer,cutoutLayer]
        return ids.allSatisfy { !$0.isEmpty } && Set(ids).count == 3
    }
}

// 角色图像覆盖完整可编辑范围；可见裁切框与像素数组原点分别保存，不能混用。
nonisolated struct RoleImages: Codable, Equatable, Sendable {
    var snapshotVersion: String
    var basePNG: URL
    var cutoutPNG: URL
    var maskPNG: URL
    var pixelSize: CGSize
    var coordinateOrigin: CGPoint
    var editableExtent: CGRect
    var cropViewport: CGRect
    /// 最终透明图可独立修饰；maskPNG 为其实际 Alpha 的灰度图。
    var isFinalized: Bool?
}

nonisolated struct SquareLayout: Codable, Equatable, Sendable {
    var canvasSide: Int
    var safeMargin: Int
    var center: CGPoint
    static var png4k: Self { Self(canvasSide: 4096, safeMargin: 256, center: CGPoint(x: 2048, y: 2048)) }
    static var white1k: Self { Self(canvasSide: 1000, safeMargin: 10, center: CGPoint(x: 500, y: 500)) }
}
