// 采集信息整理：识别表格列，保留日期精度与歧义原文，不按地点内的逗号拆分。
import Foundation

nonisolated struct CardCollectionInfo: Codable, Equatable, Sendable {
    var locality = ""
    var country = ""
    var altitude = ""
    var date = ""
    var warnings: [String] = []
    var formatted: String {
        [locality, country, Self.normalizedAltitude(altitude), Self.normalizedDate(date)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    // MARK: - 表格解析
    struct Row {
        let source: String
        let info: CardCollectionInfo
    }

    static func parse(_ raw: String) throws -> Self {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Self() }
        let rows = try parseBatch(raw)
        guard rows.count == 1, let row = rows.first else {
            throw CardError.message("请粘贴一行国家、采集点、日期的表格，可另含海拔；原文已保留。")
        }
        return row.info
    }

    static func parseBatch(_ raw: String) throws -> [Row] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        let rows = lines.enumerated().compactMap { index, line -> (number: Int, source: String, columns: [String])? in
            guard line.contains("\t") || !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var text = line
            let separator = line.contains("\t") ? "\t" : "|"
            if separator == "|" {
                text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("|") { text.removeFirst() }
                if text.hasSuffix("|") { text.removeLast() }
            }
            let columns = text.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            let nonempty = columns.filter { !$0.isEmpty }
            if !nonempty.isEmpty, nonempty.allSatisfy({ $0.range(of: "^:?-{2,}:?$", options: .regularExpression) != nil }) {
                return nil
            }
            return (index + 1, line, columns)
        }
        let aliases = [["国家", "country"], ["采集点", "地点", "locality", "location"], ["日期", "采集时间", "date"], ["海拔", "altitude", "elevation"]]
        let possibleHeader = rows.first?.columns.map { value in aliases.firstIndex { $0.contains(value.lowercased()) } }
        let header = (possibleHeader?.compactMap { $0 }.count ?? 0) >= 2 ? possibleHeader : nil
        let headerSource = header == nil ? nil : rows.first?.source
        let data = rows.dropFirst(header == nil ? 0 : 1)
        return try data.map { row in
            do {
                // 保留表头列序，逐只重新整理时仍能正确识别字段。
                let source = headerSource.map { $0 + "\n" + row.source } ?? row.source
                return Row(source: source, info: try parseRow(row.columns, header: header))
            } catch {
                throw CardError.message("第 \(row.number) 行无法解析。\(error.localizedDescription)")
            }
        }
    }

    private static func parseRow(_ row: [String], header: [Int?]?) throws -> Self {
        guard (3...4).contains(row.count) else {
            throw CardError.message("请核对国家、采集点和日期三列，可另含海拔。")
        }
        var result = Self()
        if let header {
            guard header.count == row.count, header.allSatisfy({ $0 != nil }), Set(header.compactMap { $0 }).count == header.count else { throw CardError.message("无法确定表头对应关系，请手动填写；原文已保留。") }
            for (column, value) in zip(header, row) {
                switch column { case 0: result.country = value; case 1: result.locality = value; case 2: result.date = value; case 3: result.altitude = value; default: break }
            }
        } else {
            result.country = row[0]; result.locality = row[1]
            if row.count == 3 { result.date = row[2] }
            else if isAltitude(row[2]) { result.altitude = row[2]; result.date = row[3] }
            else if isAltitude(row[3]) || row[3].isEmpty { result.date = row[2]; result.altitude = row[3] }
            else { throw CardError.message("第四列无法确定为海拔，请手动填写；原文已保留。") }
        }
        let normalized = normalizedDate(result.date)
        if !result.date.isEmpty, !isCanonicalDate(normalized) { result.warnings.append("日期格式不确定，已保留原文，请核对") }
        result.date = normalized; result.altitude = normalizedAltitude(result.altitude)
        return result
    }
    // MARK: - 米与日期精度
    private static func isAltitude(_ value: String) -> Bool { value.range(of: "^[0-9]+(?:\\.[0-9]+)?\\s*(?:m|米)$", options: [.regularExpression, .caseInsensitive]) != nil }
    static func normalizedAltitude(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAltitude(text) { return text.replacingOccurrences(of: "\\s*(?:m|米)$", with: "m", options: [.regularExpression, .caseInsensitive]) }
        if text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil { return text + "m" }
        return text
    }
    static func normalizedDate(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCanonicalDate(text) { return text.split(separator: ".").map { String(Int($0)!) }.joined(separator: ".") }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let parts = text.replacingOccurrences(of: ".", with: "").split(whereSeparator: { $0.isWhitespace })
        if parts.count == 2, let month = months.firstIndex(of: String(parts[0].prefix(3)).lowercased()), let year = Int(parts[1]), (1000...9999).contains(year), parts[0].allSatisfy({ $0.isLetter }) {
            let full = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
            if [months[month], full[month], month == 8 ? "sept" : ""].contains(parts[0].lowercased()) { return "\(year).\(month + 1)" }
        }
        return text
    }
    private static func isCanonicalDate(_ text: String) -> Bool {
        guard text.range(of: "^[0-9]{4}(?:\\.[0-9]{1,2}){0,2}$", options: .regularExpression) != nil else { return false }
        let p = text.split(separator: ".").compactMap { Int($0) }
        guard p[0] >= 1000 else { return false }
        if p.count > 1, !(1...12).contains(p[1]) { return false }
        if p.count == 3 {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return false }
            return calendar.component(.day, from: date) == p[2] && calendar.component(.month, from: date) == p[1]
        }
        return true
    }
}
