// 图鉴素材扫描：识别可选名称与编号，按素材身份配对正反面并报告冲突。
import Foundation

nonisolated enum CardInputParser {
    // MARK: - 目录扫描
    static func scan(_ selections: [URL]) throws -> [CardInputGroup] {
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        for selection in selections {
            let values = try selection.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                var scanError: Error?
                guard let enumerator = FileManager.default.enumerator(at: selection, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { continue }
                for case let url as URL in enumerator {
                    let value = try url.resourceValues(forKeys: keys)
                    if value.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if value.isRegularFile == true, url.pathExtension.lowercased() == "png" { files.append(url) }
                }
                if let scanError { throw scanError }
            } else if selection.pathExtension.lowercased() == "png" { files.append(selection) }
        }
        return group(files).map { original in
            var value=original; value.rasters=[:]
            for url in value.files {
                do {
                    let raster=try CardRasterInfo.read(url); value.rasters?[url.path]=raster
                    if let issue=raster.issue { value.issue=issue + "：" + url.lastPathComponent }
                } catch { value.issue=error.localizedDescription }
            }
            return value
        }
    }

    // MARK: - 文件名及分组
    private static let sideSuffix = /(?:^|[_*\s-]+)[DdVv]$/
    private static let specimenNumber = /(?i)(?:[a-z]+[ -]?)?[0-9]+(?:-[0-9]+)?/
    private static let numberPrefix = /(?i)(?:[a-z]+[ -]?)?[0-9]+(?:-[0-9]+)?(?=\s|\p{Han})/
    private static let latinSuffix = /(?:^|[^A-Za-z])([A-Z][a-z]+(?:\s+[a-z][a-z-]*){1,2})$/
    private static let han = /\p{Han}/

    static func group(_ files: [URL]) -> [CardInputGroup] {
        var groups: [String: CardInputGroup] = [:]
        for url in Set(files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted(by: { $0.path < $1.path }) {
            var stem = trimmed(url.deletingPathExtension().lastPathComponent)
            var sex: CardSex = .male
            stripFemaleSuffix(&stem, sex: &sex)
            let suffix = stem.firstMatch(of: sideSuffix)
            let compactSide = stem.wholeMatch(of: /.*(?:[a-z0-9\p{Han}]|-[Ff])[DV]/) != nil
            guard let side = stem.last, suffix != nil || compactSide else {
                groups[url.path] = CardInputGroup(id: url.path, chineseName: "", latinName: "", sex: .unknown,
                                                  files: [url], issue: "文件名末尾需要 D 或 V 来区分正反面", hasNoSpecimenNumber: true)
                continue
            }
            let isFront = "Dd".contains(side)
            if let suffix { stem = trimmed(stem[..<suffix.range.lowerBound]) }
            else { stem.removeLast() }
            stripFemaleSuffix(&stem, sex: &sex)
            let names = parseNames(stem, sex: &sex)
            // 无编号时只配对同一目录的同名同一性别，避免递归导入时串配。
            let id = names.number ?? url.deletingLastPathComponent().path + "/" +
                [names.chinese, names.latin, sex.rawValue, names.chinese.isEmpty && names.latin.isEmpty ? stem : ""].joined(separator: "\n")
            var value = groups[id] ?? CardInputGroup(id: id, chineseName: names.chinese, latinName: names.latin,
                sex: sex, files: [], hasNoSpecimenNumber: names.number == nil ? true : nil)
            value.files.append(url)
            if value.sex != sex || (!value.chineseName.isEmpty && !names.chinese.isEmpty && value.chineseName != names.chinese)
                || (!value.latinName.isEmpty && !names.latin.isEmpty && value.latinName != names.latin) {
                value.issue = "同编号的名称或性别不一致，请检查素材"
            }
            if value.chineseName.isEmpty { value.chineseName = names.chinese }
            if value.latinName.isEmpty { value.latinName = names.latin }
            if isFront {
                if value.front != nil { value.issue = "同组有重复正面，请移除重复素材后重新导入" }
                else { value.front = url }
            } else {
                if value.back != nil { value.issue = "同组有重复反面，请移除重复素材后重新导入" }
                else { value.back = url }
            }
            groups[id] = value
        }
        return groups.values.map { group in
            var value = group
            if value.issue == nil {
                if value.front == nil { value.issue = "缺少正面 D，已跳过，请补图" }
                else if value.back == nil { value.issue = "缺少反面 V，已跳过，请补图" }
            }
            return value
        }.sorted {
            let first = $0.specimenNumber ?? $0.sourceName, second = $1.specimenNumber ?? $1.sourceName
            let order = first.localizedStandardCompare(second)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func parseNames(_ stem: String, sex: inout CardSex) -> (number: String?, chinese: String, latin: String) {
        var parts = stem.components(separatedBy: CharacterSet(charactersIn: "_*")).map { trimmed($0) }
        var number: String?
        if let first = parts.first, first.wholeMatch(of: specimenNumber) != nil
            || (parts.count == 3 && !first.isEmpty && parts[2].firstMatch(of: han) == nil
                && (parts[1].firstMatch(of: han) != nil || first.firstMatch(of: han) == nil)) {
            number = parts.removeFirst()
        } else if let first = parts.first, let match = first.prefixMatch(of: numberPrefix) {
            number = String(match.output)
            parts[0] = trimmed(first[match.range.upperBound...])
        }
        parts = parts.filter { !$0.isEmpty }
        let name = parts.joined(separator: " ")
        var chinese = "", latin = ""
        if parts.count == 2, number != nil || parts[0].firstMatch(of: han) != nil, parts[1].firstMatch(of: han) == nil {
            (chinese, latin) = (parts[0], parts[1])
        } else if let suffix = name.firstMatch(of: latinSuffix)?.output.1 {
            chinese = trimmed(name[..<suffix.startIndex])
            latin = String(suffix)
        } else if name.firstMatch(of: han) != nil {
            chinese = name
        } else if name.wholeMatch(of: /[A-Za-z]+(?:[\s-]+[A-Za-z]+)*/) != nil {
            latin = name
        }
        stripFemaleSuffix(&chinese, sex: &sex)
        if let last = chinese.last, "雄♂".contains(last) {
            chinese = trimmed(chinese.dropLast())
        }
        latin = latin.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (number, chinese, latin)
    }

    private static func stripFemaleSuffix(_ name: inout String, sex: inout CardSex) {
        if let marker = name.firstMatch(of: /(?i)[_*\s]*(?:-f|雌|♀)$/) {
            name = trimmed(name[..<marker.range.lowerBound])
            sex = .female
        }
    }

    private static func trimmed(_ value: some StringProtocol) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
