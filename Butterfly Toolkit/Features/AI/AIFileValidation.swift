import Foundation
import CryptoKit

nonisolated enum AIFileValidation {
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
    static func outputIsCurrent(_ output: AIOutput, sample: AISample) -> Bool {
        guard let input = output.inputHash, let prediction = output.predictionHash, let alpha = output.alphaHash,
              let current = try? captureOutput(prediction: output.prediction, alpha: output.predictionAlpha, original: sample.original) else { return false }
        return current.inputHash == input && current.predictionHash == prediction && current.alphaHash == alpha
    }
    static func readCuration(engine: URL, samples: [AISample]) throws -> AICuration {
        let url = engine.appendingPathComponent("outputs/toolkit-ai/workspace.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AICuration() }
        var library = try JSONDecoder().decode(AICuration.self, from: Data(contentsOf: url))
        library.imported = library.imported.map(revalidateImported)
        let allSamples = samples + library.imported
        library.resultNotes = [:]
        library.predictions = library.predictions.filter { id, output in
            guard let sample = allSamples.first(where: { $0.id == id }) else { return true } // Preserve other batches, validate when loaded.
            let valid = outputIsCurrent(output, sample: sample)
            if !valid { library.resultNotes?[id] = "已隐藏旧结果：输入或输出已变化、Alpha 缺失，或缺少内容校验记录。请重新抠图。" }
            return valid
        }
        return library
    }
}
