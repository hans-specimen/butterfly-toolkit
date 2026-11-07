import Foundation
import ImageIO
import CoreGraphics

nonisolated enum WorkflowBridgeError: LocalizedError, Equatable {
    case unsavedDocument, staleSource, invalidStructure, ownershipConflict, invalidImage(String), photoshop(String)
    var errorDescription: String? {
        switch self {
        case .unsavedDocument: "Photoshop 文档尚未保存，请保存后刷新。"
        case .staleSource: "保存版本或输入图片已变化，请刷新后重试。"
        case .invalidStructure: "PSD 角色图层或蒙版已删除、合并或单独变换，请修复后刷新。"
        case .ownershipConflict: "PSD 已存在或不属于此任务，已停止以保护文件。"
        case .invalidImage(let detail): "图片或 AI 结果校验失败：\(detail)"
        case .photoshop(let detail): "Photoshop 处理失败：\(detail)"
        }
    }
}

nonisolated struct WorkflowMatteService: Sendable {
    typealias Run = @Sendable (URL, [String]) async throws -> AIEvent
    let engine: URL
    let workspace: URL
    let device: String
    private let run: Run
    init(engine: URL, workspace: URL, device: String = "mps", run: @escaping Run = { engine, arguments in
        try await AIProcessRunner().run(engine: engine, arguments: arguments) { _ in }
    }) {
        self.engine = engine; self.workspace = workspace; self.device = device; self.run = run
    }
    func infer(input: StackPNG) async throws -> MatteArtifact {
        let task = Task.detached(priority: .userInitiated) { try await performInference(input: input) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performInference(input: StackPNG) async throws -> MatteArtifact {
        let original = try WorkflowRaster.read(input.pngURL)
        guard try AIFileValidation.hash(input.pngURL.path) == input.fingerprint,
              original.size == input.pixelSize, original.orientation == input.orientation,
              original.orientation == 1, !input.colorProfile.isEmpty, original.hasProfile else {
            throw WorkflowBridgeError.staleSource
        }
        let result = try await run(engine, ["--workspace", workspace.path, "infer", "--input", input.pngURL.path, "--device", device])
        guard result.event == "completed", result.input.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == input.pngURL.resolvingSymlinksInPath(),
              let alphaPath = result.predictionAlpha, let cutoutPath = result.prediction else {
            throw WorkflowBridgeError.invalidImage("缺少完整推理事件或输入身份不符")
        }
        let alphaURL = URL(fileURLWithPath: alphaPath), cutoutURL = URL(fileURLWithPath: cutoutPath)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: cutoutURL.deletingLastPathComponent().appendingPathComponent("result.json"))) as? [String: Any]
        guard record?["inputSha256"] as? String == input.fingerprint,
              try AIFileValidation.hash(input.pngURL.path) == input.fingerprint else { throw WorkflowBridgeError.staleSource }
        let alphaHash = try AIFileValidation.hash(alphaPath), cutoutHash = try AIFileValidation.hash(cutoutPath)
        let alpha = try WorkflowRaster.read(alphaURL), cutout = try WorkflowRaster.read(cutoutURL)
        try WorkflowRaster.validateMatte(original: original, alpha: alpha, cutout: cutout)
        guard try AIFileValidation.hash(alphaPath) == alphaHash, (try AIFileValidation.hash(cutoutPath)) == cutoutHash,
              (try AIFileValidation.hash(input.pngURL.path)) == input.fingerprint else { throw WorkflowBridgeError.staleSource }
        return MatteArtifact(inputPNGFingerprint: input.fingerprint, alphaURL: alphaURL,
            alphaFingerprint: alphaHash, cutoutURL: cutoutURL,
            cutoutFingerprint: cutoutHash, orientation: 1, pixelSize: input.pixelSize)
    }
}

nonisolated struct WorkflowDecodedImage: Sendable {
    let image: CGImage
    let raster: WorkflowRaster
}

/// Decode every pixel, normalizing ICC to sRGB and checking premultiplied RGB/alpha coordinates.
nonisolated struct WorkflowRaster: Sendable {
    let size: CGSize
    let orientation: Int
    let hasProfile: Bool
    let profileName: String?
    let profileData: Data?
    let pixels: [UInt8]
    static func read(_ url: URL) throws -> Self { try decode(url).raster }
    static func decode(_ url: URL) throws -> WorkflowDecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width > 0, image.height > 0 else { throw WorkflowBridgeError.invalidImage(url.lastPathComponent) }
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard success else { throw WorkflowBridgeError.invalidImage("无法完整解码") }
        let raster = Self(size: CGSize(width: image.width, height: image.height), orientation: info[kCGImagePropertyOrientation] as? Int ?? 1,
                    hasProfile: try hasEmbeddedICC(url), profileName: info[kCGImagePropertyProfileName] as? String, profileData: image.colorSpace?.copyICCData() as Data?, pixels: pixels)
        return WorkflowDecodedImage(image: image,raster: raster)
    }
    private static func hasEmbeddedICC(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { return false }
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            if data[(offset + 4)..<(offset + 8)] == Data("iCCP".utf8) { return length > 0 }
            offset += length + 12
        }
        return false
    }
    static func validateMatte(original: Self, alpha: Self, cutout: Self, respectSourceAlpha: Bool = false) throws {
        guard original.size == alpha.size, original.size == cutout.size, alpha.orientation == 1, cutout.orientation == 1 else {
            throw WorkflowBridgeError.invalidImage("Alpha 尺寸或方向不符")
        }
        guard cutout.hasProfile, original.profileData == cutout.profileData else { throw WorkflowBridgeError.invalidImage("透明结果的 ICC 与输入不同") }
        var hasSubject = false, hasTransparency = false
        for i in stride(from: 0, to: alpha.pixels.count, by: 4) {
            let a = Int(alpha.pixels[i]), ca = Int(cutout.pixels[i + 3]), sourceAlpha = Int(original.pixels[i + 3])
            let expectedAlpha = respectSourceAlpha ? (a * sourceAlpha + 127) / 255 : a
            guard alpha.pixels[i + 3] == 255, abs(expectedAlpha - ca) <= 1,
                  abs(Int(alpha.pixels[i + 1]) - a) <= 1, abs(Int(alpha.pixels[i + 2]) - a) <= 1 else {
                throw WorkflowBridgeError.invalidImage("Alpha 与透明结果不一致或坐标翻转")
            }
            hasSubject = hasSubject || a > 0; hasTransparency = hasTransparency || a < 255
            for channel in 0..<3 {
                let expected = respectSourceAlpha ? Int(original.pixels[i + channel]) * a / 255 : (sourceAlpha == 0 ? 0 : Int(original.pixels[i + channel]) * a / sourceAlpha)
                guard abs(Int(cutout.pixels[i + channel]) - expected) <= 4 else {
                    throw WorkflowBridgeError.invalidImage("前景与输入像素坐标不符")
                }
            }
        }
        guard respectSourceAlpha || (hasSubject && hasTransparency) else { throw WorkflowBridgeError.invalidImage("蒙版为空或完全不透明") }
    }
}
