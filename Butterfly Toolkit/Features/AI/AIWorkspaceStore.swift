// 管理 AI 工作区的界面状态、目录载入、素材导入、单图推理与分组记录，并保护原始文件及结果内容的一致性。

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class AIWorkspaceStore: ObservableObject {
    // MARK: - 界面状态与派生数据

    @Published var enginePath: String
    @Published var catalog: AICatalog?
    @Published var samples: [AISample] = []
    @Published var selectedID: String?
    @Published var curation = AICuration()
    @Published var isLoading = false
    @Published var processingID: String?
    @Published var status = "选择 AI 项目以载入本机模型和测试素材"
    @Published var error: String?
    @Published var taskName = "白色缘毛 · 试验 01"
    @Published var trainingSelection: Set<String> = []
    @Published var device = "mps"
    private var runner: AIProcessRunner?
    private var operation: Task<Void, Never>?
    private var hasLoaded = false
    private var selectedRunPath: String?

    init() {
        enginePath = UserDefaults.standard.string(forKey: "aiEnginePath") ?? ""
        selectedRunPath = UserDefaults.standard.string(forKey: "aiRunPath")
    }
    var selected: AISample? { samples.first { $0.id == selectedID } }
    var engineURL: URL { URL(fileURLWithPath: enginePath, isDirectory: true) }
    var busy: Bool { isLoading || processingID != nil }
    var pairedSamples: [AISample] { samples.filter { $0.reference != nil } }
    func selectPairedSampleIfAvailable() {
        if selected?.reference == nil, let first = pairedSamples.first { selectedID = first.id }
    }
    var alignedCount: Int { samples.filter { $0.alignment == "aligned" }.count }
    var trainingCandidates: [AISample] { samples.filter { canTrain($0) } }
    func canTrain(_ sample: AISample) -> Bool {
        record(for: sample).canTrain(sample) && curation.use(for: sample.id) == .training
    }
    func record(for sample: AISample) -> AISampleCuration { curation.samples[sample.id] ?? AISampleCuration() }

    // MARK: - 项目选择与目录载入

    func loadOnce() { if !hasLoaded && !enginePath.isEmpty { hasLoaded = true; load() } }
    func chooseEngine() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择已有 Butterfly AI 项目"
        panel.message = "请选择包含 .venv、scripts、models 和 outputs 的项目文件夹。不会安装依赖或下载模型。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enginePath = url.path
        selectedRunPath = nil
        UserDefaults.standard.removeObject(forKey: "aiRunPath")
        UserDefaults.standard.set(enginePath, forKey: "aiEnginePath")
        load()
    }
    func chooseRun() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "载入已有测试批次"
        panel.message = "选择包含 run.json 的测试结果文件夹。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = engineURL.appendingPathComponent("outputs")
        if panel.runModal() == .OK, let url = panel.url { load(run: url) }
    }
    func load(run: URL? = nil) {
        guard !busy, !enginePath.isEmpty else { return }
        isLoading = true; error = nil; status = "正在读取本机模型与测试记录…"
        let engine = engineURL
        let requestedRun = (run?.path ?? selectedRunPath).flatMap { $0.isEmpty ? nil : $0 }
        let worker = AIProcessRunner(); runner = worker
        catalog = nil; samples = []; selectedID = nil; trainingSelection = []
        operation = Task {
            defer { isLoading = false; runner = nil; operation = nil }
            do {
                let event = try await worker.run(engine: engine, arguments: ["catalog"] + (requestedRun.map { ["--run", $0] } ?? [])) { _ in }
                guard let loaded = event.catalog, loaded.schemaVersion == 1 else { throw AIWorkspaceError(message: "AI 连接返回了不支持的数据格式，请检查连接脚本版本。") }
                catalog = loaded
                selectedRunPath = loaded.runPath.isEmpty ? nil : loaded.runPath
                UserDefaults.standard.set(selectedRunPath, forKey: "aiRunPath")
                // 大文件哈希校验移出主执行器，载入后只合并仍有效的持久化结果。
                curation = try await Task.detached {
                    try AIFileValidation.readCuration(engine: engine, samples: loaded.samples)
                }.value
                samples = loaded.samples + curation.imported.filter { item in !loaded.samples.contains(where: { $0.id == item.id }) }
                for index in samples.indices {
                    if let note = curation.resultNotes?[samples[index].id] {
                        samples[index].prediction = nil; samples[index].predictionAlpha = nil; samples[index].resultNote = note
                    }
                    if let saved = curation.predictions[samples[index].id], FileManager.default.fileExists(atPath: saved.prediction) {
                        samples[index].prediction = saved.prediction; samples[index].predictionAlpha = saved.predictionAlpha
                    }
                }
                selectedID = samples.first?.id
                status = "已载入 \(samples.count) 张图片 · \(pairedSamples.count) 份配对训练素材"
            } catch is CancellationError { status = "已取消读取" }
            catch { catalog = nil; samples = []; self.error = error.localizedDescription; status = "载入失败" }
        }
    }
    // MARK: - 单图推理与取消

    func runInference() {
        guard !busy, let sample = selected else { return }
        let engine = engineURL
        let worker = AIProcessRunner(); runner = worker
        processingID = sample.id; error = nil; status = "准备处理 \(sample.name)…"
        operation = Task {
            defer { processingID = nil; runner = nil; operation = nil }
            do {
                let result = try await worker.run(engine: engine, arguments: ["infer", "--input", sample.original, "--device", device]) { [self] event in
                    if event.event == "status", let message = event.message { await self.setStatus(message) }
                }
                guard let prediction = result.prediction, let alpha = result.predictionAlpha,
                      FileManager.default.fileExists(atPath: prediction), FileManager.default.fileExists(atPath: alpha) else {
                    throw AIWorkspaceError(message: "推理进程结束，但没有找到完整输出。请检查结果目录。")
                }
                let verifiedOutput = try await Task.detached {
                    let output = try AIFileValidation.captureOutput(prediction: prediction, alpha: alpha, original: sample.original)
                    let recordURL = URL(fileURLWithPath: prediction).deletingLastPathComponent().appendingPathComponent("result.json")
                    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
                    // 与引擎记录的输入哈希核对，拒绝推理期间原图变化产生的过期结果。
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

    // MARK: - 分组记录与持久化

    func updateCuration(sample: AISample, group: String, confirmed: Bool, use: AISampleUse) {
        let group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = record(for: sample)
        record.specimenGroup = group; record.groupConfirmed = confirmed && !group.isEmpty
        curation.samples[sample.id] = record
        if record.groupConfirmed { curation.groupUses[group] = use }
        // 分组或用途改变后立即清除失去资格的选择，避免旧选择绕过训练条件。
        trainingSelection = trainingSelection.filter { id in samples.contains { $0.id == id && canTrain($0) } }
        saveCuration()
    }
    private func saveCuration() {
        do {
            let url = engineURL.appendingPathComponent("outputs/toolkit-ai/workspace.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(curation).write(to: url, options: .atomic)
        } catch { self.error = "素材设置未能保存：\(error.localizedDescription)" }
    }
    // MARK: - 文件定位与安全导出

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
        // 比较解析后的真实路径，并拒绝覆盖任何已有文件，保护原图及人工答案。
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !protectedPaths.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == target }),
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw AIWorkspaceError(message: "为保护原图和已有结果，不覆盖现有文件。请使用新的文件名。")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: - 待抠原图导入

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
        // 逐张导入并保留成功项；单个文件失败不阻断其余文件。
        for (index, url) in urls.enumerated() {
            status = "正在添加 \(index + 1)/\(urls.count)：\(url.lastPathComponent)…"
            do {
                let event = try await AIProcessRunner().run(engine: engineURL, arguments: ["import-image", "--input", url.path]) { _ in }
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

    // MARK: - 成对训练素材导入

    func importPair(original: URL, reference: URL, group: String, kind: String, confirmed: Bool) async -> Bool {
        guard !busy, catalog != nil else { return false }
        isLoading = true; defer { isLoading = false }
        let engine = engineURL
        do {
            var sample = try await Task.detached(priority: .userInitiated) {
                var imported = try Self.preparePair(original: original, reference: reference, engine: engine)
                imported.sourceHashes = try AIFileValidation.sourceHashes(imported)
                return imported
            }.value
            // 尺寸检查不能证明内容对齐，只有人工确认才能赋予已对齐状态。
            sample.alignment = confirmed ? "aligned" : "unverified"
            sample.alignmentNote = confirmed ? "用户已检查并确认原图与人工答案对齐" : "尺寸一致；内容对齐仍需人工确认，暂不可训练"
            curation.imported.append(sample)
            curation.samples[sample.id] = AISampleCuration(specimenGroup: group.trimmingCharacters(in: .whitespacesAndNewlines), groupConfirmed: confirmed && !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, referenceKind: kind)
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
        // 复制前验证真实 PNG 类型、尺寸及答案透明通道，避免留下无效导入。
        let sourceInfo = try metadata(original), referenceInfo = try metadata(reference)
        guard sourceInfo.0 == referenceInfo.0, sourceInfo.1 == referenceInfo.1, referenceInfo.3 else {
            throw AIWorkspaceError(message: "原图与人工答案必须尺寸相同，且答案必须带透明通道。未导入任何素材。")
        }
        let id = UUID().uuidString
        let directory = engine.appendingPathComponent("data/processed/toolkit-imports/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 成对副本必须一起建立；第二份复制失败时清理本次新建目录。
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
