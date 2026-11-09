// 定义照片工作流的批次、阶段、源文件、PSD 快照、几何与导出模型，并校验清单一致性和输出路径。

import Foundation
import CoreGraphics
import Darwin

// MARK: - 阶段与固定源映射
nonisolated enum WorkflowStage: String, Codable, CaseIterable, Sendable {
    case stack, matte, geometry, hd, png4k, derivatives
    // 保留旧派生阶段以兼容清单解码，但不再将其纳入处理流程。
    static let processingStages: [Self] = [.stack, .matte, .geometry, .hd, .png4k]
}

nonisolated enum WorkflowSide: String, Codable, CaseIterable, Sendable {
    case front, back
    var fileSuffix: String { self == .front ? "D" : "V" }
    // 仅供旧清单定位已保存文件；新生成名称统一使用 D/V。
    var legacyFileSuffix: String { self == .front ? "F" : "U" }
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

nonisolated enum WorkflowStatus: String, Codable, Sendable {
    case pending, running, waitingReview, completed, failed, excluded
}

nonisolated struct WorkflowSourceFile: Codable, Equatable, Sendable {
    var url: URL
    /// 仅已排除标本的未校验历史源引用可以为空。
    var fingerprint: String
}

/// 每面冻结三张照片或一份已合成 PSD，不受队列位置或排除操作影响；可选槽位兼容旧三图清单。
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
    var xianyu = WorkflowPreset(fingerprint: "xianyu-2000-rgb238-v1")
    var white1k = WorkflowPreset(fingerprint: "white-1000-margin-10-v1")
    var footage = WorkflowPreset(fingerprint: "transparent-tight-v1")
}

nonisolated enum WorkflowPSDChange: String, Codable, Equatable, Sendable {
    case stackContent, maskOnly, geometry
}

// MARK: - 单面任务与批次记录
nonisolated struct WorkflowSideTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var side: WorkflowSide
    var sources: WorkflowSources
    var sourceRevision: Int = 1
    var records: [WorkflowStage: WorkflowStageRecord] = Dictionary(uniqueKeysWithValues:
        WorkflowStage.allCases.map { ($0, WorkflowStageRecord(stage: $0)) })
    var stackAttemptURL: URL?
    var exportHD: Bool?
    var geometryApplySourceVersion: String?
    var fourKExportRequested: Bool?
    var snapshot: PSDSnapshot?
    var stackPNG: StackPNG?
    var matteArtifact: MatteArtifact?
    var geometryRequest: GeometryRequest = GeometryRequest()
    var geometrySolution: GeometrySolution?
    /// 仅修改蒙版时重新校验已保存候选，不重新估算角度或裁切。
    var geometryRevalidationRequired: Bool = false
    var lastPSDChange: WorkflowPSDChange?
    var roleImages: RoleImages?
    var squareLayout: SquareLayout = .png4k
    var artifacts: [WorkflowArtifact] = []
    var historicalArtifacts: [WorkflowArtifact]?

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
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var sourceDirectory: URL
    /// 保存内部批次记录与可恢复的工作数据，不代表用户选择的导出目录。
    var outputDirectory: URL
    var outputLocations: WorkflowOutputLocations?
    var checkAfterStack: Bool = true
    var checkAfterMatte: Bool = true
    var checkGeometry: Bool?
    var check4K: Bool?
    var specimens: [WorkflowSpecimen]
    /// nil 保留旧版默认语义；空数组明确表示不选择派生图片。
    var selectedDerivativeKinds: [WorkflowAssetKind]?
    var watermarkURL: URL?
    var presets: WorkflowPresets = WorkflowPresets()
    var revision: Int = 0
    var isPaused: Bool = false
    /// nil 保持旧批次行为；新流程必须经过人工定稿才可导出。
    var manualFinalization: Bool?

    var sideTasks: [WorkflowSideTask] { specimens.flatMap { [$0.front, $0.back] } }
    var activeTasks: [WorkflowSideTask] { specimens.filter { !$0.isExcluded }.flatMap { [$0.front, $0.back] } }
    /// 从各面的持久记录推导阶段，使已确认的部分标本可以独立推进。
    var currentStage: WorkflowStage? {
        let stage = WorkflowStage.processingStages.first { stage in activeTasks.contains { $0[stage].state != .completed } }
        return manualFinalization == true && stage == .hd ? .png4k : stage
    }
    var allSucceeded: Bool {
        !specimens.isEmpty && !specimens.contains(where: \.isExcluded) &&
            sideTasks.allSatisfy { task in WorkflowStage.processingStages.allSatisfy { task[$0].state == .completed } }
    }
    func task(id: UUID) -> WorkflowSideTask? { sideTasks.first { $0.id == id } }

    var hasCheckpoints: Bool { manualFinalization == true || checkAfterStack || checkAfterMatte || checkGeometry != false || check4K != false }
    func validateStart() throws {
        if !hasCheckpoints && (exportDirectory(for: .hd) == nil || exportDirectory(for: .png4k) == nil) {
            throw WorkflowBridgeError.invalidImage("取消全部检查点时，请先选择堆栈原图和 PNG4K 输出文件夹")
        }
    }

    func exportDirectory(for kind: WorkflowAssetKind) -> URL? {
        if manualFinalization == true {
            guard kind == .hd || kind == .png4k else { return nil }
            return sourceDirectory.appendingPathComponent(sourceDirectory.lastPathComponent + (kind == .hd ? "_堆栈原图" : "_4K_PNG"),isDirectory: true)
        }
        if let outputLocations {
            return kind == .hd ? outputLocations.hd : kind == .png4k ? outputLocations.png4k : nil
        }
        // 旧版清单使用批次目录内的子文件夹。
        let folders: [WorkflowAssetKind: String] = [.hd: "高清堆栈", .png4k: "png 4k", .xianyu: "闲鱼产品图", .white1k: "1K 白底", .footage: "png 素材"]
        return outputDirectory.appendingPathComponent(folders[kind]!)
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

    func validateArtifactURL(_ url: URL, kind: WorkflowAssetKind) throws {
        guard let root = exportDirectory(for: kind), Self.isContained(url, in: root),
              manualFinalization != true || Self.isContained(root,in: sourceDirectory),
              manualFinalization == true || outputLocations != nil || Self.isContained(url, in: outputDirectory) else {
            throw WorkflowStateError.invalidManifest("Export destination escapes its selected directory")
        }
    }

    func validateOutputURL(_ url: URL) throws {
        if Self.isContained(url, in: outputDirectory) { return }
        if manualFinalization == true || outputLocations != nil {
            for kind in [WorkflowAssetKind.hd, .png4k] {
                if let root = exportDirectory(for: kind), Self.isContained(url, in: root),
                   manualFinalization != true || Self.isContained(root,in: sourceDirectory) { return }
            }
        }
        // 原图旁的 PSD 必须严格使用冻结后的标本名和正反面后缀。
        let allowed = specimens.flatMap { specimen in
            WorkflowSide.allCases.flatMap { side in
                [side.fileSuffix,side.legacyFileSuffix].map { sourceDirectory.appendingPathComponent("\(specimen.baseName)_\($0).psd") }
            }
        }
        let imported = sideTasks.filter { $0.sources.isPSD }.map { $0.sources.first.url.standardizedFileURL }
        if Self.isContained(url, in: sourceDirectory), (allowed + imported).contains(url.standardizedFileURL) { return }
        throw WorkflowStateError.invalidManifest("Output destination is outside the batch's authorized locations")
    }
    private static func isSafeBaseName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." &&
            !name.contains("/") && !name.contains("\\") && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func validate() throws {
        guard schemaVersion == 1, revision >= 0, sourceDirectory.isFileURL, outputDirectory.isFileURL else {
            throw WorkflowStateError.invalidManifest("Unsupported schema or batch metadata")
        }
        for folder in ["PSD", ".work", "高清堆栈", "png 4k", "闲鱼产品图", "1K 白底", "png 素材"] {
            try validateOutputURL(outputDirectory.appendingPathComponent(folder))
        }
        for directory in [outputLocations?.hd, outputLocations?.png4k].compactMap({ $0 }) {
            guard directory.isFileURL else { throw WorkflowStateError.invalidManifest("Invalid export directory") }
        }
        let identities = specimens.map(\.id) + sideTasks.map(\.id)
        guard Set(identities).count == identities.count else { throw WorkflowStateError.invalidManifest("Duplicate task identity") }
        for specimen in specimens {
            guard Self.isSafeBaseName(specimen.baseName),
                  specimen.front.side == .front, specimen.back.side == .back,
                  specimen.exclusionReason == nil || specimen.exclusionReason?.isEmpty == false else {
                throw WorkflowStateError.invalidManifest("Invalid specimen mapping")
            }
            for task in [specimen.front, specimen.back] {
                if let attempt = task.stackAttemptURL { try validateOutputURL(attempt) }
                for artifact in task.artifacts {
                    if (manualFinalization == true || outputLocations != nil) && artifact.kind.stage != .derivatives { try validateArtifactURL(artifact.url, kind: artifact.kind) }
                    else { try validateOutputURL(artifact.url) }
                }
                guard task.sourceRevision > 0, Set(task.records.keys) == Set(WorkflowStage.allCases),
                      task.sources.isPSD || task.sources.files.count == 3,
                      task.sources.files.allSatisfy({ $0.url.isFileURL && (specimen.isExcluded || !$0.fingerprint.isEmpty) }) else {
                    throw WorkflowStateError.invalidManifest("Incomplete source or stage records")
                }
                if task.sources.isPSD {
                    guard Self.isContained(task.sources.first.url,in: sourceDirectory),
                          task.stackAttemptURL == nil || task.stackAttemptURL == task.sources.first.url,
                          task.snapshot == nil || task.snapshot?.workingURL == task.sources.first.url else {
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
                          (snapshot.roles?.isValid == true || (manualFinalization == true && snapshot.finalRoles?.isValid == true)),
                          snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0 else {
                        throw WorkflowStateError.invalidManifest("Matte requires a saved PSD with role identities")
                    }
                }
                if manualFinalization == true && task[.geometry].state == .completed {
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
