import Foundation
import CoreGraphics

nonisolated struct AICatalog: Codable, Sendable {
    var schemaVersion: Int
    var model: AIModel
    var samples: [AISample]
    var runPath: String
    var reportPath: String?
}

nonisolated struct AIModel: Codable, Sendable {
    var name: String
    var revision: String
    var available: Bool
    var inputSize: Int
    var numericStatus: String
    var numericCheckPath: String?
    var qualitySummary: String
    var testedSamples: Int
}

nonisolated struct AIRegion: Codable, Identifiable, Sendable {
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var id: String { name }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
}

nonisolated struct AISample: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var original: String
    var reference: String?
    var alpha: String?
    var prediction: String?
    var predictionAlpha: String?
    var width: Int
    var height: Int
    var color: String
    var alignment: String
    var alignmentNote: String
    var rois: [AIRegion]
    var sourceHashes: [String: String]? = nil
    var resultNote: String? = nil
    var dimensions: String { "\(width) × \(height)" }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
    var alignmentTitle: String {
        switch alignment {
        case "aligned": "已对齐"
        case "misaligned": "需对齐"
        default: "待核对"
        }
    }
}

nonisolated enum AISampleUse: String, Codable, CaseIterable, Identifiable {
    case unassigned = "未分组", training = "训练", validation = "验证", test = "测试", excluded = "暂不使用"
    var id: Self { self }
}

nonisolated struct AISampleCuration: Codable, Sendable {
    var specimenGroup: String = ""
    var groupConfirmed: Bool = false
    var referenceKind: String = "人工精扣"
    func canTrain(_ sample: AISample) -> Bool {
        sample.alignment == "aligned" && sample.reference != nil && groupConfirmed && !specimenGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated struct AICuration: Codable, Sendable {
    var samples: [String: AISampleCuration] = [:]
    var groupUses: [String: AISampleUse] = [:]
    var imported: [AISample] = []
    var predictions: [String: AIOutput] = [:]
    var resultNotes: [String: String]? = nil
    func use(for sampleID: String) -> AISampleUse {
        guard let record = samples[sampleID], record.groupConfirmed else { return .unassigned }
        return groupUses[record.specimenGroup] ?? .unassigned
    }
}

nonisolated struct AIOutput: Codable, Sendable {
    var prediction: String
    var predictionAlpha: String
    var inputHash: String? = nil
    var predictionHash: String? = nil
    var alphaHash: String? = nil
}

nonisolated struct AIEvent: Decodable, Sendable {
    var event: String
    var message: String?
    var catalog: AICatalog?
    var sample: AISample?
    var input: String?
    var outputDirectory: String?
    var prediction: String?
    var predictionAlpha: String?
}

nonisolated struct AIViewport {
    var center: CGPoint = .zero
    var zoom: CGFloat = 1
    func scale(image: CGSize, panel: CGSize) -> CGFloat {
        min(panel.width / max(image.width, 1), panel.height / max(image.height, 1)) * zoom
    }
    func imageRect(image: CGSize, panel: CGSize) -> CGRect {
        let scale = scale(image: image, panel: panel)
        return CGRect(x: panel.width / 2 - center.x * scale, y: panel.height / 2 - center.y * scale,
                      width: image.width * scale, height: image.height * scale)
    }
    mutating func move(translation: CGSize, scale: CGFloat, start: CGPoint) {
        center = CGPoint(x: start.x - translation.width / max(scale, 0.001), y: start.y - translation.height / max(scale, 0.001))
    }
    mutating func fit(_ size: CGSize) { center = CGPoint(x: size.width / 2, y: size.height / 2); zoom = 1 }
}

nonisolated struct AIWorkspaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
