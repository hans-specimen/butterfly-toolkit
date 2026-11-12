// 图鉴素材扫描：按编号配对 D/V，明确报告重复、缺面和名称冲突。
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
    static func group(_ files: [URL]) -> [CardInputGroup] {
        var groups: [String: CardInputGroup] = [:]
        for url in Set(files.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted(by: { $0.path < $1.path }) {
            let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "_")
            guard parts.count == 4, parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }), ["D", "V"].contains(parts[3].uppercased()) else {
                groups[url.path] = CardInputGroup(id: url.lastPathComponent, chineseName: "无法识别文件名", latinName: "", sex: .unknown, files: [url], issue: "需要 编号_中文名_拉丁名_D/V.png")
                continue
            }
            var chinese = parts[1].trimmingCharacters(in: .whitespaces)
            var sex: CardSex = .male
            if let last = chinese.last, ["雌", "♀", "雄", "♂"].contains(String(last)) {
                sex = ["雌", "♀"].contains(String(last)) ? .female : .male
                chinese.removeLast(); chinese = chinese.trimmingCharacters(in: .whitespaces)
            }
            let identifier = parts[0].trimmingCharacters(in: .whitespaces)
            let latin = parts[2].trimmingCharacters(in: .whitespaces)
            var value = groups[identifier] ?? CardInputGroup(id: identifier, chineseName: chinese, latinName: latin, sex: sex, files: [])
            value.files.append(url)
            if value.chineseName != chinese || value.latinName != latin || value.sex != sex { value.issue = "同编号的名称或性别不一致，请检查素材" }
            if parts[3].uppercased() == "D" {
                if value.front != nil { value.issue = "同编号有重复正面，请移除重复素材后重新导入" }
                else { value.front = url }
            } else {
                if value.back != nil { value.issue = "同编号有重复反面，请移除重复素材后重新导入" }
                else { value.back = url }
            }
            groups[identifier] = value
        }
        return groups.values.map { group in
            var value = group
            if value.issue == nil {
                if value.front == nil { value.issue = "缺少正面 D，已跳过，请补图" }
                else if value.back == nil { value.issue = "缺少反面 V，已跳过，请补图" }
            }
            return value
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
