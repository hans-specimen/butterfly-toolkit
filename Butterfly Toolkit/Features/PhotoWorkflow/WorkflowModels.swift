import Foundation
import CoreGraphics

nonisolated enum WorkflowStage: String, Codable, CaseIterable, Sendable {
    case stack, matte, geometry, hd, png4k, derivatives
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

nonisolated struct WorkflowBatch: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var sourceDirectory: URL
    var outputDirectory: URL
    var checkAfterStack: Bool = true
    var checkAfterMatte: Bool = true
    var specimens: [WorkflowSpecimen]
    var presets: WorkflowPresets = WorkflowPresets()
    var revision: Int = 0
    var isPaused: Bool = false

    var sideTasks: [WorkflowSideTask] { specimens.flatMap { [$0.front, $0.back] } }
    var activeTasks: [WorkflowSideTask] { specimens.filter { !$0.isExcluded }.flatMap { [$0.front, $0.back] } }
    /// Derived from durable per-side records so partially confirmed specimens can advance independently.
    var currentStage: WorkflowStage? {
        WorkflowStage.allCases.first { stage in activeTasks.contains { $0[stage].state != .completed } }
    }
    var allSucceeded: Bool {
        !specimens.isEmpty && !specimens.contains(where: \.isExcluded) &&
            sideTasks.allSatisfy { task in WorkflowStage.allCases.allSatisfy { task[$0].state == .completed } }
    }
    func task(id: UUID) -> WorkflowSideTask? { sideTasks.first { $0.id == id } }

    func validate() throws {
        guard schemaVersion == 1, revision >= 0, sourceDirectory.isFileURL, outputDirectory.isFileURL else {
            throw WorkflowStateError.invalidManifest("Unsupported schema or batch metadata")
        }
        let identities = specimens.map(\.id) + sideTasks.map(\.id)
        guard Set(identities).count == identities.count else { throw WorkflowStateError.invalidManifest("Duplicate task identity") }
        for specimen in specimens {
            guard !specimen.baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  specimen.front.side == .front, specimen.back.side == .back,
                  specimen.exclusionReason == nil || specimen.exclusionReason?.isEmpty == false else {
                throw WorkflowStateError.invalidManifest("Invalid specimen mapping")
            }
            for task in [specimen.front, specimen.back] {
                guard task.sourceRevision > 0, Set(task.records.keys) == Set(WorkflowStage.allCases),
                      task.sources.files.allSatisfy({ $0.url.isFileURL && !$0.fingerprint.isEmpty }) else {
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
    var leftWingTip: CGPoint?
    var rightWingTip: CGPoint?
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
