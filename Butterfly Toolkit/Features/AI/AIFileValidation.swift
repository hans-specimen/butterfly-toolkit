// 负责通过内容哈希校验 AI 素材与结果，在载入工作区时撤销失效的对齐确认并隐藏过期输出。

import Foundation
import CryptoKit

nonisolated enum AIFileValidation {
    // MARK: - 文件内容指纹

    // 分块计算哈希，避免原尺寸图片整体载入内存。
    static func hash(_ path: String) throws -> String {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func sourceHashes(_ sample: AISample) throws -> [String: String] {
        var hashes = try ["original": hash(sample.original)]
        if let reference = sample.reference { hashes["reference"] = try hash(reference) }
        return hashes
    }
    // MARK: - 导入素材与结果有效性

    // 人工确认只对当时的文件内容有效；缺失校验记录也必须重新确认。
    static func revalidateImported(_ sample: AISample) -> AISample {
        var checked = sample
        if let expected = sample.sourceHashes, let current = try? sourceHashes(sample), expected == current {
            return checked
        }
        checked.alignment = "unverified"
        checked.alignmentNote = sample.reference == nil
            ? "导入原图已变化、缺失或没有内容校验记录，请重新添加待抠图片。"
            : "导入素材已变化、缺失或没有内容校验记录，原有人工确认已失效。请重新检查并导入成对 PNG。"
        return checked
    }
    static func captureOutput(prediction: String, alpha: String, original: String) throws -> AIOutput {
        try AIOutput(prediction: prediction, predictionAlpha: alpha, inputHash: hash(original), predictionHash: hash(prediction), alphaHash: hash(alpha))
    }
    // 输入、透明图与 Alpha 都需匹配，避免显示不完整或与当前原图无关的结果。
    static func outputIsCurrent(_ output: AIOutput, sample: AISample) -> Bool {
        guard let input = output.inputHash, let prediction = output.predictionHash, let alpha = output.alphaHash,
              let current = try? captureOutput(prediction: output.prediction, alpha: output.predictionAlpha, original: sample.original) else { return false }
        return current.inputHash == input && current.predictionHash == prediction && current.alphaHash == alpha
    }
    // MARK: - 工作区记录恢复

    static func readCuration(engine: URL, samples: [AISample]) throws -> AICuration {
        let url = engine.appendingPathComponent("outputs/toolkit-ai/workspace.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AICuration() }
        var library = try JSONDecoder().decode(AICuration.self, from: Data(contentsOf: url))
        library.imported = library.imported.map(revalidateImported)
        let allSamples = samples + library.imported
        library.resultNotes = [:]
        library.predictions = library.predictions.filter { id, output in
            guard let sample = allSamples.first(where: { $0.id == id }) else { return true } // 保留其他批次的记录，待对应批次载入时再校验。
            let valid = outputIsCurrent(output, sample: sample)
            if !valid { library.resultNotes?[id] = "已隐藏旧结果：输入或输出已变化、Alpha 缺失，或缺少内容校验记录。请重新抠图。" }
            return valid
        }
        return library
    }
}
