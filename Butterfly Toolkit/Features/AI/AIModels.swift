// 定义 AI 目录、样本、分组、推理事件与比较视口的数据模型，集中表达素材资格及同步查看的坐标规则。

import Foundation
import CoreGraphics

// MARK: - 模型目录与样本

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

// MARK: - 标本分组与训练资格

nonisolated enum AISampleUse: String, Codable, CaseIterable, Identifiable {
    case unassigned = "未分组", training = "训练", validation = "验证", test = "测试", excluded = "暂不使用"
    var id: Self { self }
}

nonisolated struct AISampleCuration: Codable, Sendable {
    var specimenGroup: String = ""
    var groupConfirmed: Bool = false
    var referenceKind: String = "人工精扣"
    // 对齐、人工答案和标本组确认同时满足后，才具备进入训练集合的基础资格。
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
    // 用途归属于整只标本，避免正反面或裁切被分入不同数据集合。
    func use(for sampleID: String) -> AISampleUse {
        guard let record = samples[sampleID], record.groupConfirmed else { return .unassigned }
        return groupUses[record.specimenGroup] ?? .unassigned
    }
}

// MARK: - 推理结果与桥接事件

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

// MARK: - 共用图片视口

// 中心点使用原图坐标，缩放倍数基于适合窗口的比例，供左右面板共用。
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
    // 将屏幕拖动距离还原到原图坐标，保持不同缩放比例下的平移一致。
    mutating func move(translation: CGSize, scale: CGFloat, start: CGPoint) {
        center = CGPoint(x: start.x - translation.width / max(scale, 0.001), y: start.y - translation.height / max(scale, 0.001))
    }
    mutating func fit(_ size: CGSize) { center = CGPoint(x: size.width / 2, y: size.height / 2); zoom = 1 }
}

// MARK: - 工作区错误

nonisolated struct AIWorkspaceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
