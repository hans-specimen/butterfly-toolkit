// 统一文本输入的换行、Tab 和错误定位，表格解析时保留 Tab 列分隔符。
import Foundation

nonisolated enum ToolkitTextInput {
    static func replacingTabs(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .components(separatedBy: "\n")
    }

    static func controlError(_ text: String, line: Int? = nil, allowTabs: Bool = false) -> String? {
        guard let scalar = text.unicodeScalars.first(where: {
            CharacterSet.controlCharacters.contains($0) && (!allowTabs || $0 != "\t")
        }) else { return nil }
        let code = String(format: "U+%04X", scalar.value)
        let location = line.map { "第 \($0) 行" } ?? ""
        return "\(location)含有不可见控制字符（\(code)），请删除。"
    }

    static func filenameError(_ text: String, line: Int? = nil) -> String? {
        if let error = controlError(text, line: line) { return error }
        let location = line.map { "第 \($0) 行" } ?? ""
        if let character = text.unicodeScalars.first(where: { $0 == "/" || $0 == ":" || $0 == "\\" }) {
            return "\(location)含有文件名不能使用的字符「\(character)」。"
        }
        if text == "." || text == ".." { return "\(location)不能使用「\(text)」作为名称。" }
        return nil
    }

    static func singleLineError(_ text: String, filename: Bool = false) -> String? {
        let rows = lines(replacingTabs(text))
        for (index, row) in rows.enumerated() {
            let line = rows.count == 1 ? nil : index + 1
            if let error = controlError(row, line: line) { return error }
            let content = row.trimmingCharacters(in: .whitespaces)
            if index > 0, !content.isEmpty {
                return "第 \(index + 1) 行有多余内容，此处只接受一行。"
            }
            if filename, let error = filenameError(content, line: line) { return error }
        }
        return nil
    }

    static func filenameRows(_ text: String) throws -> [String] {
        try lines(replacingTabs(text)).enumerated().map { index, row in
            let name = row.trimmingCharacters(in: .whitespaces)
            if let message = controlError(row, line: index + 1) ?? filenameError(name, line: index + 1) {
                throw InvalidText(message: message)
            }
            return name
        }
    }

    private struct InvalidText: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func multilineError(_ text: String) -> String? {
        for (index, line) in lines(text).enumerated() {
            if let error = controlError(line, line: index + 1) { return error }
        }
        return nil
    }

    static func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard singleLineError(text) == nil,
              let value = Int(replacingTabs(text).trimmingCharacters(in: .whitespacesAndNewlines)),
              range.contains(value) else { return nil }
        return value
    }
}
