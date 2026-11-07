import Foundation
import CoreGraphics
import Darwin

nonisolated enum WorkflowStage: String, Codable, CaseIterable, Sendable {
    case stack, matte, geometry, hd, png4k, derivatives
    // The legacy derivative case remains decodable, but is no longer a workflow step.
    static let processingStages: [Self] = [.stack, .matte, .geometry, .hd, .png4k]
}

nonisolated enum WorkflowSide: String, Codable, CaseIterable, Sendable {
    case front, back
    var fileSuffix: String { self == .front ? "F" : "U" }
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
    /// Empty only for an excluded specimen's unchecked historical source reference.
    var fingerprint: String
}

/// Fixed slots freeze the source-to-side mapping, independent of queue position or exclusions.
nonisolated struct WorkflowSources: Codable, Equatable, Sendable {
    var first: WorkflowSourceFile
    var second: WorkflowSourceFile
    var third: WorkflowSourceFile
    var files: [WorkflowSourceFile] { [first, second, third] }
}

nonisolated struct WorkflowStageRecord: Codable, Equatable, Sendable {
    var stage: WorkflowStage
    var state: WorkflowStatus = .pending
    var inputVersion: Int = 1
    var outputVersion: String?
    var confirmedVersion: String?
    /// Changes on start, cancellation, retry and invalidation; asynchronous results must match it.
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
    /// A mask edit rechecks this saved candidate; it does not estimate a new angle or crop.
    var geometryRevalidationRequired: Bool = false
    var lastPSDChange: WorkflowPSDChange?
    var roleImages: RoleImages?
    var squareLayout: SquareLayout = .png4k
    var artifacts: [WorkflowArtifact] = []

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
    /// Internal batch records and resumable working data; not a user-selected export folder.
    var outputDirectory: URL
    var outputLocations: WorkflowOutputLocations?
    var checkAfterStack: Bool = true
    var checkAfterMatte: Bool = true
    var checkGeometry: Bool?
    var check4K: Bool?
    var specimens: [WorkflowSpecimen]
    /// nil is the legacy default; [] explicitly selects no derivatives.
    var selectedDerivativeKinds: [WorkflowAssetKind]?
    var watermarkURL: URL?
    var presets: WorkflowPresets = WorkflowPresets()
    var revision: Int = 0
    var isPaused: Bool = false

    var sideTasks: [WorkflowSideTask] { specimens.flatMap { [$0.front, $0.back] } }
    var activeTasks: [WorkflowSideTask] { specimens.filter { !$0.isExcluded }.flatMap { [$0.front, $0.back] } }
    /// Derived from durable per-side records so partially confirmed specimens can advance independently.
    var currentStage: WorkflowStage? {
        WorkflowStage.processingStages.first { stage in activeTasks.contains { $0[stage].state != .completed } }
    }
    var allSucceeded: Bool {
        !specimens.isEmpty && !specimens.contains(where: \.isExcluded) &&
            sideTasks.allSatisfy { task in WorkflowStage.processingStages.allSatisfy { task[$0].state == .completed } }
    }
    func task(id: UUID) -> WorkflowSideTask? { sideTasks.first { $0.id == id } }

    var hasCheckpoints: Bool { checkAfterStack || checkAfterMatte || checkGeometry != false || check4K != false }
    func validateStart() throws {
        if !hasCheckpoints && (exportDirectory(for: .hd) == nil || exportDirectory(for: .png4k) == nil) {
            throw WorkflowBridgeError.invalidImage("取消全部检查点时，请先选择堆栈原图和 PNG4K 输出文件夹")
        }
    }

    func exportDirectory(for kind: WorkflowAssetKind) -> URL? {
        if let outputLocations {
            return kind == .hd ? outputLocations.hd : kind == .png4k ? outputLocations.png4k : nil
        }
        // Older manifests used subfolders within the batch directory.
        let folders: [WorkflowAssetKind: String] = [.hd: "高清堆栈", .png4k: "png 4k", .xianyu: "闲鱼产品图", .white1k: "1K 白底", .footage: "png 素材"]
        return outputDirectory.appendingPathComponent(folders[kind]!)
    }

    private static func canonicalComponents(_ url: URL) -> [String]? {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        let fm = FileManager.default
        // Foundation does not resolve intermediate symlinks when the destination does not exist yet.
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
              outputLocations != nil || Self.isContained(url, in: outputDirectory) else {
            throw WorkflowStateError.invalidManifest("Export destination escapes its selected directory")
        }
    }

    func validateOutputURL(_ url: URL) throws {
        if Self.isContained(url, in: outputDirectory) { return }
        if outputLocations != nil {
            for kind in [WorkflowAssetKind.hd, .png4k] {
                if let root = exportDirectory(for: kind), Self.isContained(url, in: root) { return }
            }
        }
        // PSDs beside originals must have exactly the frozen specimen name and side.
        let allowed = specimens.flatMap { specimen in
            WorkflowSide.allCases.map { sourceDirectory.appendingPathComponent("\(specimen.baseName)_\($0.fileSuffix).psd") }
        }
        if Self.isContained(url, in: sourceDirectory), allowed.contains(url.standardizedFileURL) { return }
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
                    if outputLocations != nil && artifact.kind.stage != .derivatives { try validateArtifactURL(artifact.url, kind: artifact.kind) }
                    else { try validateOutputURL(artifact.url) }
                }
                guard task.sourceRevision > 0, Set(task.records.keys) == Set(WorkflowStage.allCases),
                      task.sources.files.allSatisfy({ $0.url.isFileURL && (specimen.isExcluded || !$0.fingerprint.isEmpty) }) else {
                    throw WorkflowStateError.invalidManifest("Incomplete source or stage records")
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
                    guard let snapshot = task.snapshot, snapshot.taskID == task.id, snapshot.roles?.isValid == true,
                          snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0 else {
                        throw WorkflowStateError.invalidManifest("Matte requires a saved PSD with role identities")
                    }
                }
                guard task.artifacts.allSatisfy({ $0.ownerTaskID == task.id }) else {
                    throw WorkflowStateError.invalidManifest("Artifact owned by another side task")
                }
            }
        }
    }
}

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
    /// Stack-only snapshots can lack roles. A completed matte stage cannot.
    var roles: PSDRoleIdentifiers?
    var structureSummary: String
}

nonisolated struct StackPNG: Codable, Equatable, Sendable {
    var snapshotVersion: String
    var pngURL: URL
    var fingerprint: String
    var pixelSize: CGSize
    var orientation: Int
    var colorProfile: String
    /// Read the alpha channel for source-background validity; this may be the RGBA PNG itself, never its luminance.
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

nonisolated enum GeometryRatio: String, Codable, CaseIterable, Sendable {
    case adaptive, fiveByFour, elevenByEightPointFive, square
}

nonisolated enum GeometryAngleStrategy: Codable, Equatable, Sendable {
    case automaticWingTips
    case twoPoints(left: CGPoint, right: CGPoint)
    case manual(degrees: Double)
}

nonisolated struct GeometryRequest: Codable, Equatable, Sendable {
    var ratio: GeometryRatio = .adaptive
    var targetMargin: Double = 0.1
    var angleStrategy: GeometryAngleStrategy = .automaticWingTips
    var centerOverride: CGPoint?
}

/// Fractions of output width (left/right) or height (top/bottom), not pixel distances.
nonisolated struct WorkflowMargins: Codable, Equatable, Sendable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double
}

nonisolated struct GeometrySolution: Codable, Equatable, Sendable {
    var sourceVersion: String
    /// Incremental to the identified saved source snapshot, never an instruction to repeat a prior PS edit.
    var angleDegrees: Double
    /// Current saved PSD coordinates, x right/y down; positive angles rotate clockwise about this pivot.
    var rotationPivot: CGPoint
    var leftWingTip: CGPoint?
    var rightWingTip: CGPoint?
    /// Bounds and crop are in the current saved PSD plane AFTER rotation, before the crop-origin shift.
    var subjectBounds: CGRect
    var sourceCropRect: CGRect
    var outputSize: CGSize
    var actualMargins: WorkflowMargins
    var isApplicable: Bool
    var reason: String?
}

nonisolated struct RoleImages: Codable, Equatable, Sendable {
    var snapshotVersion: String
    var basePNG: URL
    var cutoutPNG: URL
    var maskPNG: URL
    var pixelSize: CGSize
    var coordinateOrigin: CGPoint
    var editableExtent: CGRect
    var cropViewport: CGRect
}

nonisolated struct SquareLayout: Codable, Equatable, Sendable {
    var canvasSide: Int
    var safeMargin: Int
    var center: CGPoint
    static var png4k: Self { Self(canvasSide: 4096, safeMargin: 256, center: CGPoint(x: 2048, y: 2048)) }
    static var white1k: Self { Self(canvasSide: 1000, safeMargin: 10, center: CGPoint(x: 500, y: 500)) }
}
