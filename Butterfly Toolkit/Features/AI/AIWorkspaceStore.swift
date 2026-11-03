import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class AIWorkspaceStore: ObservableObject {
    @Published var enginePath: String
    @Published var catalog: AICatalog?
    @Published var samples: [AISample] = []
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            if let id = selectedID, pairedSamples.contains(where: { $0.id == id }) {
                if !materialSelection.contains(id) { materialSelection = [id] }
            } else { materialSelection = [] }
        }
    }
    @Published private(set) var materialSelection: Set<String> = []
    @Published var curation = AICuration()
    @Published var isLoading = false
    @Published var processingID: String?
    @Published var status = "选择 AI 项目以载入本机模型和测试素材"
    @Published var error: String?
    @Published var taskName = "白色缘毛 · 试验 01"
    @Published var trainingSelection: Set<String> = []
    @Published var trainingRuns: [AITrainingRun] = []
    @Published var currentTraining: AITrainingRun?
    @Published var isTraining = false
    @Published var trainingEpochs = 5
    @Published var trainingInputSize = 512
    @Published var inferenceModelID = "base"
    var trainingRunner: AIProcessRunner?
    var trainingOperation: Task<Void, Never>?
    @Published var device = "mps"
    @Published var workspacePath = "/Users/hans/SynologyDrive/Developer/butterfly-ai-footage"
    @Published var importSummary: [String] = []
    private var runner: AIProcessRunner?
    private var operation: Task<Void, Never>?
    private var hasLoaded = false

    init() {
        enginePath = UserDefaults.standard.string(forKey: "aiEnginePath") ?? ""
        UserDefaults.standard.removeObject(forKey: "aiRunPath")
    }
    var selected: AISample? { samples.first { $0.id == selectedID } }
    var engineURL: URL { URL(fileURLWithPath: enginePath, isDirectory: true) }
    var workspaceURL: URL { URL(fileURLWithPath: workspacePath, isDirectory: true) }
    var busy: Bool { isLoading || processingID != nil || isTraining }
    var pairedSamples: [AISample] { samples.filter { $0.reference != nil } }
    func setMaterialSelection(_ ids: Set<String>) {
        let orderedIDs = pairedSamples.map(\.id)
        let valid = ids.intersection(orderedIDs)
        if materialSelection != valid { materialSelection = valid }
        // A range/all selection keeps the current preview; fallback follows table order, never Set order.
        if let selectedID, valid.contains(selectedID) { return }
        selectedID = orderedIDs.first { valid.contains($0) }
    }
    func selectPairedSampleIfAvailable() {
        if selected?.reference == nil, let first = pairedSamples.first { selectedID = first.id }
    }
    var alignedCount: Int { samples.filter { $0.alignment == "aligned" }.count }
    var trainingCandidates: [AISample] { samples.filter { canTrain($0) } }
    func canTrain(_ sample: AISample) -> Bool {
        record(for: sample).canTrain(sample)
    }
    func record(for sample: AISample) -> AISampleCuration { curation.samples[sample.id] ?? AISampleCuration() }

    func loadOnce() { if !hasLoaded && !enginePath.isEmpty { hasLoaded = true; load() } }
    func chooseEngine() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择已有 Butterfly AI 项目"
        panel.message = "请选择包含 .venv、scripts、models 和 outputs 的项目文件夹。不会安装依赖或下载模型。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enginePath = url.path
        UserDefaults.standard.set(enginePath, forKey: "aiEnginePath")
        load()
    }
    func load() {
        guard !busy, !enginePath.isEmpty else { return }
        isLoading = true; error = nil; status = "正在读取本机模型与当前素材库…"
        let engine = engineURL
        let workspace = workspaceURL
        let worker = AIProcessRunner(); runner = worker
        catalog = nil; samples = []; selectedID = nil; trainingSelection = []
        operation = Task {
            defer { isLoading = false; runner = nil; operation = nil }
            do {
                let event = try await worker.run(engine: engine, arguments: ["catalog"], workspace: workspace) { _ in }
                guard let loaded = event.catalog, loaded.schemaVersion == 1 else { throw AIWorkspaceError(message: "AI 连接返回了不支持的数据格式，请检查连接脚本版本。") }
                catalog = loaded
                curation = try await Task.detached {
                    try AIFileValidation.readCuration(engine: engine, samples: loaded.samples, workspace: workspace)
                }.value
                samples = curation.imported
                for index in samples.indices {
                    if let note = curation.resultNotes?[samples[index].id] {
                        samples[index].prediction = nil; samples[index].predictionAlpha = nil; samples[index].resultNote = note
                    }
                    if let saved = curation.predictions[samples[index].id], FileManager.default.fileExists(atPath: saved.prediction) {
                        samples[index].prediction = saved.prediction; samples[index].predictionAlpha = saved.predictionAlpha
                    }
                }
                selectedID = samples.first?.id
                await loadTrainingHistory()
                saveCuration()
                status = "已载入 \(samples.count) 张图片 · \(pairedSamples.count) 份配对训练素材"
            } catch is CancellationError { status = "已取消读取" }
            catch { catalog = nil; samples = []; self.error = error.localizedDescription; status = "载入失败" }
        }
    }
    func runInference() {
        guard !busy, let sample = selected else { return }
        let engine = engineURL
        let worker = AIProcessRunner(); runner = worker
        processingID = sample.id; error = nil; status = "准备处理 \(sample.name)…"
        operation = Task {
            defer { processingID = nil; runner = nil; operation = nil }
            do {
                let result = try await worker.run(engine: engine, arguments: ["infer", "--input", sample.original, "--device", device] + (inferenceModelID == "base" ? [] : ["--model", inferenceModelID]), workspace: workspaceURL) { [self] event in
                    if event.event == "status", let message = event.message { await self.setStatus(message) }
                }
                guard let prediction = result.prediction, let alpha = result.predictionAlpha,
                      FileManager.default.fileExists(atPath: prediction), FileManager.default.fileExists(atPath: alpha) else {
                    throw AIWorkspaceError(message: "推理进程结束，但没有找到完整输出。请检查结果目录。")
                }
                let verifiedOutput = try await Task.detached {
                    var output = try AIFileValidation.captureOutput(prediction: prediction, alpha: alpha, original: sample.original)
                    output.modelName = result.modelName
                    let recordURL = URL(fileURLWithPath: prediction).deletingLastPathComponent().appendingPathComponent("result.json")
                    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
                    guard record?["inputSha256"] as? String == output.inputHash else {
                        throw AIWorkspaceError(message: "原图已变化，刚完成的结果不再与当前原图对应，请重新处理。")
                    }
                    return output
                }.value
                curation.predictions[sample.id] = verifiedOutput
                if let index = samples.firstIndex(where: { $0.id == sample.id }) {
                    samples[index].prediction = prediction; samples[index].predictionAlpha = alpha; samples[index].resultNote = nil
                }
                saveCuration()
                status = "\(sample.name) 已完成 · 已另存原尺寸 PNG"
            } catch is CancellationError { status = "已取消处理 · 原图未改动" }
            catch { self.error = error.localizedDescription; status = "\(sample.name) 处理失败" }
        }
    }
    private func setStatus(_ message: String) { status = message }
    func cancel() { status = "正在停止处理…"; runner?.cancel() }

    @discardableResult func saveCuration() -> Bool {
        do {
            let url = workspaceURL.appendingPathComponent("outputs/toolkit-ai/workspace.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(curation).write(to: url, options: .atomic)
            return true
        } catch { self.error = "素材设置未能保存：\(error.localizedDescription)"; return false }
    }
    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func openReport() {
        guard let path = catalog?.reportPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    func exportSelected() {
        guard let sample = selected, let path = sample.prediction else { return }
        let panel = NSSavePanel()
        panel.title = "另存 AI 透明 PNG"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = sample.name + "-AI.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Self.copyResult(from: URL(fileURLWithPath: path), to: destination, protectedPaths: [sample.original, sample.reference, sample.alpha].compactMap { $0 })
            status = "已另存：\(destination.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
    nonisolated static func copyResult(from source: URL, to destination: URL, protectedPaths: [String]) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !protectedPaths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == target }),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw AIWorkspaceError(message: "为保护原图和已有结果，不覆盖现有文件。请使用新的文件名。")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func chooseImages() {
        guard !busy, catalog != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "添加待抠图片"
        panel.message = "选择 PNG 或 JPEG，可多选；无需人工答案。原文件保持不变，副本用于本机抠图。"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importImages(urls) }
    }

    func importImages(_ urls: [URL]) async {
        guard !busy, catalog != nil, !urls.isEmpty else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        var importedIDs: [String] = []
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            status = "正在添加 \(index + 1)/\(urls.count)：\(url.lastPathComponent)…"
            do {
                let event = try await AIProcessRunner().run(engine: engineURL, arguments: ["import-image", "--input", url.path], workspace: workspaceURL) { _ in }
                guard event.event == "imported", let sample = event.sample, sample.reference == nil else {
                    throw AIWorkspaceError(message: "导入返回了无效图片记录，请检查 AI 连接脚本。")
                }
                curation.imported.append(sample); samples.append(sample); importedIDs.append(sample.id)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if let first = importedIDs.first { selectedID = first; saveCuration() }
        status = "已添加 \(importedIDs.count) 张待抠图片" + (failures.isEmpty ? " · 请选择图片开始抠图" : " · \(failures.count) 张导入失败")
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func importPair(original: URL, reference: URL, kind: String, confirmed: Bool) async -> Bool {
        guard !busy, catalog != nil else { return false }
        isLoading = true; defer { isLoading = false }
        let engine = workspaceURL
        do {
            var sample = try await Task.detached(priority: .userInitiated) {
                var imported = try Self.preparePair(original: original, reference: reference, engine: engine)
                imported.sourceHashes = try AIFileValidation.sourceHashes(imported)
                return imported
            }.value
            sample.alignment = confirmed ? "aligned" : "unverified"
            sample.alignmentNote = confirmed ? "用户已检查并确认原图与人工答案对齐" : "尺寸一致；内容对齐仍需人工确认，暂不可训练"
            sample.answerConfirmed = confirmed
            curation.imported.append(sample)
            curation.samples[sample.id] = AISampleCuration(referenceKind: kind)
            samples.append(sample); selectedID = sample.id; saveCuration()
            status = "已复制导入素材；源文件保持不变"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    nonisolated static func preparePair(original: URL, reference: URL, engine: URL) throws -> AISample {
        guard original.pathExtension.lowercased() == "png", reference.pathExtension.lowercased() == "png" else {
            throw AIWorkspaceError(message: "请使用无损导出的原图 PNG 和带透明度的人工答案 PNG；本入口不读取或修改 PSD。")
        }
        func metadata(_ url: URL) throws -> (Int, Int, String, Bool) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int else {
                throw AIWorkspaceError(message: "无法读取 PNG：\(url.lastPathComponent)")
            }
            return (width, height, values[kCGImagePropertyProfileName] as? String ?? "未标记色彩配置", values[kCGImagePropertyHasAlpha] as? Bool ?? false)
        }
        let sourceInfo = try metadata(original), referenceInfo = try metadata(reference)
        guard sourceInfo.0 == referenceInfo.0, sourceInfo.1 == referenceInfo.1, referenceInfo.3 else {
            throw AIWorkspaceError(message: "原图与人工答案必须尺寸相同，且答案必须带透明通道。未导入任何素材。")
        }
        let id = UUID().uuidString
        let directory = engine.appendingPathComponent("data/processed/toolkit-imports/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: original, to: directory.appendingPathComponent("original.png"))
            try FileManager.default.copyItem(at: reference, to: directory.appendingPathComponent("foreground.png"))
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        return AISample(id: "toolkit-import/\(id)", name: original.deletingPathExtension().lastPathComponent,
                        original: directory.appendingPathComponent("original.png").path, reference: directory.appendingPathComponent("foreground.png").path,
                        alpha: nil, prediction: nil, predictionAlpha: nil, width: sourceInfo.0, height: sourceInfo.1, color: sourceInfo.2,
                        alignment: "unverified", alignmentNote: "待核对", rois: [])
    }
}
