// 图鉴卡片的数据模型：保存输入身份、可编辑文字、渲染版本及恢复所需的最小状态。
import Foundation

// MARK: - 文字与输入
nonisolated enum CardSex: String, Codable, CaseIterable, Sendable {
    case male, female, unknown
    var title: String { switch self { case .male: "♂ 雄"; case .female: "♀ 雌"; case .unknown: "未鉴定" } }
}

nonisolated struct CardInputGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var chineseName: String
    var latinName: String
    var sex: CardSex
    var front: URL?
    var back: URL?
    var files: [URL]
    var issue: String?
    var rasters: [String:CardRasterInfo]?
    // 旧清单只用 id 保存编号，缺少此字段时仍沿用原编号。
    var hasNoSpecimenNumber: Bool?
    var specimenNumber: String? { hasNoSpecimenNumber == true || wasRejectedByLegacyParser ? nil : id }
    var sourceName: String { (front ?? back ?? files.first)?.deletingPathExtension().lastPathComponent ?? id }
    var wasRejectedByLegacyParser: Bool { front == nil && back == nil && chineseName == "无法识别文件名" }
}

nonisolated struct CardFields: Codable, Equatable, Sendable {
    var chineseName = ""
    var latinName = ""
    var sex: CardSex = .male
    var rawCollection = ""
    var collection = CardCollectionInfo()
    var collectionText = ""

    var formattedChineseName: String {
        let name = chineseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = latinName.split(whereSeparator: \.isWhitespace)
        guard !name.isEmpty, !name.hasSuffix("指名亚种"), terms.count == 3,
              terms[1].caseInsensitiveCompare(terms[2]) == .orderedSame else { return chineseName }
        var base = name
        if base.hasSuffix("亚种") {
            base = String(base.dropLast(2)).trimmingCharacters(in: .whitespaces)
            if base.lowercased().hasSuffix(terms[2].lowercased()) {
                base = String(base.dropLast(terms[2].count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return base + "指名亚种"
    }
}

// MARK: - 工作记录
nonisolated struct CardRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var input: CardInputGroup
    var fields: CardFields
    var revision = 0
    var renderedRevision: Int?
    var previewHash: String?
    var roles: [String: Int]?
    var sources: [String: String] = [:]
    var workHash: String?
    var manualAdjusted = false
    var exportedURL: URL?
    var exportedRevision: Int?
    var layoutPending: Bool?
    var issue: String?
    var collision = false
    var isExported: Bool { exportedURL != nil && exportedRevision == revision }
    init(input: CardInputGroup) {
        self.input = input
        fields = CardFields(chineseName: input.chineseName, latinName: input.latinName, sex: input.sex)
        fields.chineseName = fields.formattedChineseName
    }
    var title: String {
        [fields.chineseName, fields.latinName].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? input.sourceName
    }
    var missingNames: String? {
        let missing = [(fields.chineseName, "中文名"), (fields.latinName, "拉丁名")].compactMap { value, label in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? label : nil
        }
        return missing.isEmpty ? nil : "缺少" + missing.joined(separator: "、")
    }
    var outputName: String {
        let parts = [input.specimenNumber ?? "", fields.formattedChineseName, fields.latinName].map(Self.safeName).filter { !$0.isEmpty }
        return (parts.isEmpty ? "图鉴卡片" : parts.joined(separator: "_")) + ".png"
    }
    private static func safeName(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct CardPreparedState: Codable, Sendable {
    var roles: [String:Int]
    var workHash: String
    var layoutPending: Bool
}

nonisolated enum CardError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}

nonisolated struct CardSession: Codable, Sendable {
    var schemaVersion = 1
    var records: [CardRecord] = []
    var outputDirectory = URL(fileURLWithPath: "/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/tmp")
}
