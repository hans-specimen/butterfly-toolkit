// 独立 AI 工具使用的推理服务；照片工作流不依赖此服务。

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

nonisolated struct WorkflowMatteService: Sendable {
    typealias Run = @Sendable (WorkflowInferenceRequest) async throws -> AIEvent
    let engine: URL
    let workspace: URL
    let device: String
    private let run: Run
    private let worker: AIInferenceWorker
    init(engine: URL,workspace: URL,device: String = "mps",worker: AIInferenceWorker = AIInferenceWorker(),run: Run? = nil) {
        self.engine = engine; self.workspace = workspace; self.device = device; self.worker = worker
        self.run = run ?? { try await worker.infer($0) }
    }
    func shutdown() async { await worker.shutdown() }
    func infer(input: StackPNG) async throws -> MatteArtifact {
        let task = Task.detached(priority: .userInitiated) { try await performInference(input: input) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func performInference(input: StackPNG) async throws -> MatteArtifact {
        let original = try WorkflowRaster.readMatteInput(input.pngURL)
        guard try AIFileValidation.hash(input.pngURL.path) == input.fingerprint,
              original.size == input.pixelSize, original.orientation == input.orientation,
              original.orientation == 1, !input.colorProfile.isEmpty, original.hasProfile else {
            throw WorkflowBridgeError.staleSource
        }
        let result = try await run(WorkflowInferenceRequest(engine: engine,workspace: workspace,input: input.pngURL,device: device))
        try Task.checkCancellation()
        guard result.event == "completed", result.input.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == input.pngURL.resolvingSymlinksInPath(),
              let alphaPath = result.predictionAlpha, let cutoutPath = result.prediction else {
            throw WorkflowBridgeError.invalidImage("缺少完整推理事件或输入身份不符")
        }
        let alphaURL = URL(fileURLWithPath: alphaPath), cutoutURL = URL(fileURLWithPath: cutoutPath)
        // 同时校验推理记录与当前输入哈希，防止外部文件在推理期间被替换。
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: cutoutURL.deletingLastPathComponent().appendingPathComponent("result.json"))) as? [String: Any]
        guard record?["inputSha256"] as? String == input.fingerprint,
              try AIFileValidation.hash(input.pngURL.path) == input.fingerprint else { throw WorkflowBridgeError.staleSource }
        let alphaHash = try AIFileValidation.hash(alphaPath), cutoutHash = try AIFileValidation.hash(cutoutPath)
        let alpha = try WorkflowRaster.read(alphaURL), cutout = try WorkflowRaster.read(cutoutURL)
        try WorkflowRaster.validateMatte(original: original, alpha: alpha, cutout: cutout)
        guard try AIFileValidation.hash(alphaPath) == alphaHash, (try AIFileValidation.hash(cutoutPath)) == cutoutHash,
              (try AIFileValidation.hash(input.pngURL.path)) == input.fingerprint else { throw WorkflowBridgeError.staleSource }
        // 先验证外部结果，再生成独立清理产物；不覆盖引擎结果或人工 PSD。
        let values = stride(from: 0,to: alpha.pixels.count,by: 4).map { alpha.pixels[$0] }
        let source = try WorkflowRaster.read(input.pngURL)
        guard source.size == alpha.size,source.pixels.count == alpha.pixels.count else { throw WorkflowBridgeError.staleSource }
        // 按实际合成后的可见度分类；保留区域仍写原蒙版，避免回写时重复乘底图 Alpha。
        let effective = values.indices.map { UInt8((Int(values[$0])*Int(source.pixels[$0*4+3])+127)/255) }
        let analysis = try MaskResidueCleanup.analyze(effective,width: Int(alpha.size.width),height: Int(alpha.size.height))
        let cleaned = values.indices.map { analysis.alpha[$0] == 0 ? UInt8(0) : values[$0] }
        do {
            let folder = workspace.appendingPathComponent("AI/matte-cleaned/\(UUID())",isDirectory: true)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            do {
                let reportURL = folder.appendingPathComponent("cleanup-report.json")
                try JSONEncoder().encode(analysis.report).write(to: reportURL,options: .atomic)
                let changed = cleaned != stride(from: 0,to: alpha.pixels.count,by: 4).map { alpha.pixels[$0] }
                let cleanAlpha = changed ? folder.appendingPathComponent("alpha.png") : alphaURL
                let cleanCutout = changed ? folder.appendingPathComponent("cutout.png") : cutoutURL
                if changed {
                    try WorkflowRaster.writeCleanedMatte(alpha: cleaned,originalAlpha: alpha,cutoutURL: cutoutURL,alphaURL: cleanAlpha,outputURL: cleanCutout)
                    try WorkflowRaster.validateMatte(original: original,alpha: WorkflowRaster.read(cleanAlpha),cutout: WorkflowRaster.read(cleanCutout))
                }
                guard try AIFileValidation.hash(alphaPath) == alphaHash,try AIFileValidation.hash(cutoutPath) == cutoutHash,
                      try AIFileValidation.hash(input.pngURL.path) == input.fingerprint else { throw WorkflowBridgeError.staleSource }
                try Task.checkCancellation()
                return MatteArtifact(inputPNGFingerprint: input.fingerprint,alphaURL: cleanAlpha,
                    alphaFingerprint: try AIFileValidation.hash(cleanAlpha.path),cutoutURL: cleanCutout,
                    cutoutFingerprint: try AIFileValidation.hash(cleanCutout.path),orientation: 1,pixelSize: input.pixelSize,
                    cleanupReportURL: reportURL,cleanupReportFingerprint: try AIFileValidation.hash(reportURL.path),
                    cleanupAlgorithmVersion: analysis.report.algorithmVersion)
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
    }
}
