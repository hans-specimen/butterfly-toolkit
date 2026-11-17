// 兼容前置及后置标本编号，统一新输出名称，并保留原片按编号、槽位排序的顺序。
import Foundation

nonisolated enum SpecimenFilename {
    // MARK: - 编号与名称
    private static let number = /(?i)(?:[a-z]+[ -]?)?[0-9]+(?:-[0-9]+)?/
    private static let prefix = /(?i)((?:[a-z]+[ -]?)?[0-9]+(?:-[0-9]+)?)(?:[_*\s]+|(?=\p{Han}))/

    static func components(_ stem: String) -> (name: String, number: String?) {
        let stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        // 两端都有数字时沿用旧前缀身份，尾部数字可能只是名称的补充标记。
        if let match = stem.prefixMatch(of: prefix) {
            return (String(stem[match.range.upperBound...]), String(match.output.1))
        }
        if let separator = stem.lastIndex(of: "_") {
            let suffix = String(stem[stem.index(after: separator)...])
            if suffix.wholeMatch(of: number) != nil {
                return (String(stem[..<separator]).trimmingCharacters(in: .whitespaces), suffix)
            }
        }
        return stem.wholeMatch(of: number) != nil ? ("", stem) : (stem, nil)
    }

    static func normalized(_ stem: String) -> String {
        let value = components(stem)
        return [value.name, value.number ?? ""].filter { !$0.isEmpty }.joined(separator: "_")
    }

    // MARK: - 输入顺序
    static func sortKey(_ stem: String) -> String {
        let value = components(stem)
        // 只移动字母加数字的标本编号；IMG_1、DSC_1 等相机序号保留原自然排序。
        guard let number = value.number, number.rangeOfCharacter(from: .letters) != nil else { return stem }
        return "\(number)_\(value.name)"
    }
}
