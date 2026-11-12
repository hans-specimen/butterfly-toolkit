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
}

nonisolated struct CardFields: Codable, Equatable, Sendable {
    var chineseName = ""
    var latinName = ""
    var sex: CardSex = .male
    var rawCollection = ""
    var collection = CardCollectionInfo()
    var collectionText = ""
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
    }
    var outputName: String {
        [input.id, fields.chineseName, fields.latinName].map(Self.safeName).joined(separator: "_") + ".png"
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
