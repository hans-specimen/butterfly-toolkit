// 连接照片工作流界面与执行器，管理建批次草稿、选中状态、异步预览、构图编辑和人工 PSD 操作。

import SwiftUI
import Combine
import AppKit

// MARK: - 输入分组与批次冻结
nonisolated enum WorkflowInputMode: String, CaseIterable, Sendable {
    case photos, psd
    var title: String { self == .photos ? "从景深合成开始" : "从 PS 抠图开始（已有 PSD）" }
    var filesPerSide: Int { self == .photos ? 3 : 1 }
}
// 移除照片只清空当前槽位，历史引用仍保留，便于明确排除整组后追溯原映射。
nonisolated struct WorkflowDraftGroup: Identifiable, Sendable {
    var id = UUID()
    var files: [URL?] {
        didSet { for index in files.indices { if let url = files[index] { historicalFiles[index] = url } } }
    }
    private(set) var historicalFiles: [URL]
    var suggestedName: String?
    var excluded = false
    init(files: [URL?], suggestedName: String? = nil) {
        precondition([2,6].contains(files.count) && files.allSatisfy { $0 != nil })
        self.files = files; historicalFiles = files.map { $0! }; self.suggestedName = suggestedName
    }
    mutating func swapFaces() {
        let prior = historicalFiles
        let half = files.count / 2
        files = Array(files[half...])+Array(files[..<half])
        historicalFiles = Array(prior[half...])+Array(prior[..<half])
    }
}

nonisolated struct WorkflowBatchDraft: Sendable {
    var directory: URL
    var groups: [WorkflowDraftGroup]
    var remainder: [URL]
    var otherFiles: [URL]
    var inputMode: WorkflowInputMode = .photos
    var ignoreRemainder = false
    var photoCount: Int { groups.reduce(0) { $0 + $1.files.count } + remainder.count }
    static func scan(directory: URL,inputMode: WorkflowInputMode = .photos) throws -> Self {
        let files = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: [.isRegularFileKey],options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if inputMode == .psd {
            let psds = files.filter { $0.pathExtension.lowercased() == "psd" }
            let pairs = try psdGroups(files: psds)
            return Self(directory: directory,groups: pairs.groups,remainder: pairs.remainder,otherFiles: files.filter { $0.pathExtension.lowercased() != "psd" },inputMode: .psd)
        }
        let photos = files.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let count = photos.count/6
        return Self(directory: directory,groups: (0..<count).map { WorkflowDraftGroup(files: photos[($0*6)..<($0*6+6)].map { Optional($0) }) },remainder: Array(photos.dropFirst(count*6)),otherFiles: files.filter { !["jpg","jpeg"].contains($0.pathExtension.lowercased()) })
    }
    static func psdGroups(files: [URL]) throws -> (groups: [WorkflowDraftGroup],remainder: [URL]) {
        var pairs: [String: (name: String, faces: [String: URL])] = [:]
        var remainder: [URL] = []
        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.count > 2,stem.suffix(2).first == "_",let side = stem.last?.uppercased(),["D","V"].contains(side) else {
                remainder.append(file); continue
            }
            let name = String(stem.dropLast(2)), key = name.precomposedStringWithCanonicalMapping.lowercased()
            var pair = pairs[key] ?? (name,[:])
            guard pair.faces[side] == nil else { throw WorkflowBridgeError.invalidImage("PSD 正反面重复：\(file.lastPathComponent)") }
            pair.faces[side] = file; pairs[key] = pair
        }
        var groups: [WorkflowDraftGroup] = []
        for pair in pairs.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if let front = pair.faces["D"],let back = pair.faces["V"] {
                groups.append(WorkflowDraftGroup(files: [front,back],suggestedName: pair.name))
            } else { remainder.append(contentsOf: pair.faces.values) }
        }
        return (groups,remainder.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }
    func freeze(names: String,output: URL,checkStack: Bool,checkMatte: Bool,locations: WorkflowOutputLocations? = nil,checkGeometry: Bool = true,check4K: Bool = true,manualFinalization: Bool = false,matteProvider: WorkflowMatteProvider = .photoshop) throws -> WorkflowBatch {
        let names = names.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !groups.isEmpty,names.count == groups.count,names.allSatisfy({ !$0.isEmpty }),Set(names.map { $0.lowercased() }).count == names.count else { throw WorkflowBridgeError.invalidImage("名称必须每组一行，不能空白或重名") }
        guard remainder.isEmpty || ignoreRemainder else { throw WorkflowBridgeError.invalidImage(inputMode == .psd ? "请补齐 D/V 配对或明确排除未配对 PSD" : "请明确排除剩余未分组照片") }
        guard groups.allSatisfy({ $0.files.count == inputMode.filesPerSide * 2 }) else { throw WorkflowBridgeError.invalidImage("分组与输入方式不符") }
        let activeURLs = groups.filter { !$0.excluded }.flatMap(\.files)
        guard activeURLs.allSatisfy({ $0 != nil }),Set(activeURLs.compactMap { $0?.resolvingSymlinksInPath() }).count == activeURLs.count else { throw WorkflowBridgeError.invalidImage("照片缺失或在多个固定位置重复，请补拍替换或排除整组") }
        guard groups.contains(where: { !$0.excluded }) else { throw WorkflowBridgeError.invalidImage("至少保留一只标本") }
        if FileManager.default.fileExists(atPath: output.path),!((try FileManager.default.contentsOfDirectory(atPath: output.path)).isEmpty) { throw WorkflowBridgeError.invalidImage("输出目录非空，请选择新的批次目录；已有批次请打开清单") }
        let specimens = try zip(groups,names).map { group,name -> WorkflowSpecimen in
            let files: [WorkflowSourceFile]
            if group.excluded {
                // 仅保留历史引用：不读取已排除槽位，也不将其标记为已校验内容。
                files = group.historicalFiles.map { WorkflowSourceFile(url: $0,fingerprint: "") }
            } else {
                guard group.files.allSatisfy({ $0 != nil }) else { throw WorkflowBridgeError.invalidImage("组 \(name) 的固定映射不完整") }
                files = try group.files.map { url in
                    let url = url!; return try WorkflowSourceFile(url: url.resolvingSymlinksInPath(),fingerprint: AIFileValidation.hash(url.path))
                }
            }
            func side(_ value: WorkflowSide,_ offset: Int) -> WorkflowSideTask {
                let sources = inputMode == .psd ? WorkflowSources(first: files[offset]) : WorkflowSources(first: files[offset],second: files[offset+1],third: files[offset+2])
                var task = WorkflowSideTask(side: value,sources: sources)
                if group.excluded { for stage in WorkflowStage.allCases { task[stage].state = .excluded; task[stage].exclusionReason = "建批次时排除" } }; return task
            }
            return WorkflowSpecimen(id: group.id,baseName: name,front: side(.front,0),back: side(.back,inputMode.filesPerSide),exclusionReason: group.excluded ? "建批次时排除" : nil)
        }
        var batch = WorkflowBatch(sourceDirectory: directory,outputDirectory: output,outputLocations: locations,checkAfterStack: inputMode == .photos && checkStack,checkAfterMatte: checkMatte,checkGeometry: checkGeometry,check4K: check4K,specimens: specimens)
        batch.matteProvider = matteProvider; batch.psdSubdirectory = true
        if manualFinalization { batch.manualFinalization = true; batch.checkAfterStack = false; batch.checkAfterMatte = false; batch.checkGeometry = true; batch.check4K = true }
        try batch.validate(); try batch.validateStart(); return batch
    }
}

// MARK: - 界面状态与当前预览
@MainActor final class PhotoWorkflowStore: ObservableObject {
    @Published var draft: WorkflowBatchDraft?
    @Published var inputMode: WorkflowInputMode = .photos {
        didSet { if inputMode != oldValue,let directory = draft?.directory { scan(directory) } }
    }
    @Published var names = ""
    @Published var hdDirectory: URL?
    @Published var png4kDirectory: URL?
    @Published var matteProvider: WorkflowMatteProvider = .photoshop
    var effectiveMatteProvider: WorkflowMatteProvider { batch?.effectiveMatteProvider ?? matteProvider }
    var workingPSDDirectory: URL? {
        if let task = currentTask {
            if let saved = task.snapshot { return saved.workingURL.deletingLastPathComponent() }
            if task.sources.isPSD { return task.sources.first.url.deletingLastPathComponent() }
        }
        return batch?.generatedPSDDirectory
    }
    @Published var checkAfterStack = UserDefaults.standard.object(forKey: "workflowCheckStack") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAfterStack,forKey: "workflowCheckStack") }
    }
    @Published var checkAfterMatte = UserDefaults.standard.object(forKey: "workflowCheckMatte") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAfterMatte,forKey: "workflowCheckMatte") }
    }
    @Published var checkGeometry = true
    @Published var check4K = true
    var needsExportDirectories: Bool { false }
    var usesFinalization: Bool { batch?.manualFinalization == true }
    var canStart: Bool { draft != nil && (!needsExportDirectories || (hdDirectory != nil && png4kDirectory != nil)) }
    @Published var batch: WorkflowBatch?
    @Published var selectedSpecimens: Set<UUID> = []
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var currentSpecimenID: UUID? { didSet { if currentSpecimenID != oldValue { retainCurrentDetailOnly(); selectCurrentTaskStage() } } }
    @Published var face: WorkflowSide = .front { didSet { if face != oldValue { retainCurrentDetailOnly(); selectCurrentTaskStage() } } }
    @Published var stage: WorkflowStage = .stack { didSet { if stage != oldValue { cancelMove(); if !isSelectingTaskStage { prepareSelected() } } } }
    private var isSelectingTaskStage = false
    @Published var error: String?
    @Published var busy = false
    @Published var previewMode = "底图" { didSet { if previewMode != oldValue { prepareSelected() } } }
    @Published var previewBackground = "棋盘"
    @Published var zoom = 1.0
    @Published var showSafeFrame = true
    @Published var pickingTips = false
    @Published var tips: [CGPoint] = []
    @Published private(set) var images: [UUID: CGImage] = [:]
    @Published private(set) var imageIdentities: [UUID: WorkflowPreviewImageIdentity] = [:]
    @Published private(set) var isDragging = false
    @Published private(set) var dragOffset: CGSize = .zero
    @Published private(set) var detailRequested: Set<UUID> = []
    private var requestedImageIdentities: [UUID: WorkflowPreviewImageIdentity] = [:]
    @Published private(set) var solutions: [UUID: GeometrySolution] = [:]
    @Published private(set) var requests: [UUID: GeometryRequest] = [:]
    @Published private(set) var layouts: [UUID: SquareLayout] = [:]
    @Published private(set) var gates: [UUID: WorkflowPreviewGate] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var previewInteractionStarted: [UUID: TimeInterval] = [:]
    private var warmSources: Set<String> = []
    @Published var manualTaskID: UUID?
    @Published var manualChange: WorkflowPSDChange = .maskOnly
    private var executor: WorkflowExecutor?
    private var manifestURL: URL?
    private var isResettingPreviews = false
    private let geometry: WorkflowGeometryCache
    private let previews: any WorkflowPreviewServing
    private(set) var previewTasks: [UUID: Task<Void,Never>] = [:]
    private var command: Task<Void,Never>?
    init(geometry: WorkflowGeometryCache = WorkflowGeometryCache(),previews: (any WorkflowPreviewServing)? = nil) {
        self.geometry = geometry; self.previews = previews ?? WorkflowPreviewService(geometry: geometry)
    }
    var currentSpecimen: WorkflowSpecimen? { batch?.specimens.first { $0.id == currentSpecimenID } }
    var currentTask: WorkflowSideTask? { face == .front ? currentSpecimen?.front : currentSpecimen?.back }
    var currentSolution: GeometrySolution? { currentTask.flatMap { solutions[$0.id] ?? $0.geometrySolution } }
    var currentRequest: GeometryRequest {
        guard let task = currentTask else { return GeometryRequest() }
        if let draft = requests[task.id] { return draft }
        var request = task.geometryRequest
        if let saved = task.geometrySolution,task[.geometry].state == .completed || task.geometryRevalidationRequired { request.angleStrategy = .manual(degrees: saved.angleDegrees) }
        return request
    }
    var currentLayout: SquareLayout { currentTask.flatMap { layouts[$0.id] } ?? currentTask?.squareLayout ?? .png4k }
    var currentPreviewLayout: SquareLayout {
        var value = currentLayout
        if isDragging { value.center.x += dragOffset.width; value.center.y += dragOffset.height }
        return value
    }
    var currentPreviewSolution: GeometrySolution? {
        guard var value = currentSolution else { return nil }
        if isDragging { value.sourceCropRect = value.sourceCropRect.offsetBy(dx: -dragOffset.width,dy: -dragOffset.height); value.isApplicable = false }
        return value
    }
    func displayImage(for task: WorkflowSideTask) -> CGImage? {
        guard let identity = desiredImageIdentity(task),imageIdentities[task.id] == identity else { return nil }
        return images[task.id]
    }
    var currentDetailReady: Bool {
        guard let task = currentTask,detailRequested.contains(task.id),let image = displayImage(for: task),let roles = task.roleImages else { return false }
        return image.width == Int(roles.pixelSize.width) && image.height == Int(roles.pixelSize.height)
    }
    private func desiredImageIdentity(_ task: WorkflowSideTask) -> WorkflowPreviewImageIdentity? {
        guard let roles = task.roleImages,roles.snapshotVersion == task.snapshot?.contentVersion else { return nil }
        let mode = stage == .png4k ? "抠图" : previewMode
        let url = mode == "蒙版" ? roles.maskPNG : mode == "抠图" ? roles.cutoutPNG : roles.basePNG
        return WorkflowPreviewImageIdentity(sourceVersion: roles.snapshotVersion,url: url,maximumPixelSize: detailRequested.contains(task.id) ? Int(max(roles.pixelSize.width,roles.pixelSize.height)) : 2048)
    }
    func loadCurrentDetail() {
        guard manualTaskID == nil || usesFinalization,let task = currentTask else { return }
        retainCurrentDetailOnly()
        detailRequested.insert(task.id); requestPreview(task: task)
    }
    private func retainCurrentDetailOnly() {
        let obsolete = detailRequested.filter { $0 != currentTask?.id }
        for id in obsolete {
            detailRequested.remove(id)
            previewTasks[id]?.cancel(); previewTasks[id] = nil
            images[id] = nil; imageIdentities[id] = nil; requestedImageIdentities[id] = nil
            gates[id] = nil; loading.remove(id)
            // 新缩略图请求同时使尚未完成的旧全尺寸预览结果失效。
            if manualTaskID == nil,let task = batch?.task(id: id) { requestPreview(task: task) }
        }
    }
    func useQuickPreview() {
        guard manualTaskID == nil || usesFinalization,let task = currentTask else { return }
        detailRequested.remove(task.id); requestPreview(task: task)
    }
    var canConfirm: Bool {
        guard !isDragging,!busy,manualTaskID == nil,let batch,!batch.isPaused,!selectedSpecimens.isEmpty else { return false }
        let selected = batch.specimens.filter { selectedSpecimens.contains($0.id) && !$0.isExcluded }
        guard selected.count == selectedSpecimens.count else { return false }
        return selected.flatMap { [$0.front,$0.back] }.allSatisfy { task in
            guard displayImage(for: task) != nil,task.roleImages?.snapshotVersion == task.snapshot?.contentVersion,gates[task.id]?.canConfirm == true,solutions[task.id]?.sourceVersion == task.snapshot?.contentVersion else { return false }
            if stage == .png4k { return task[.geometry].state == .completed && (usesFinalization ? task.snapshot?.finalRoles?.isValid == true : task[.hd].state == .completed) && squareValid(task: task) }
            return task[.geometry].state == .waitingReview || task[.geometry].state == .completed
        }
    }
    var canResumeAutomatic: Bool {
        guard batch?.isPaused == true else { return false }
        return !usesFinalization || manualTaskID == nil || batch?.activeTasks.contains { task in
            [WorkflowStage.stack,.matte,.geometry].contains { task[$0].state == .pending }
        } == true
    }
    func displayedRecord(_ task: WorkflowSideTask) -> WorkflowStageRecord {
        if usesFinalization && stage == .hd { return task[.geometry] }
        if usesFinalization && stage == .png4k && task[.hd].state == .failed { return task[.hd] }
        return task[stage]
    }
    var canFinalize: Bool {
        guard usesFinalization, manualTaskID == nil, let task = currentTask,
              task.manualAdoptionRequired != true, task.geometryApplySourceVersion == nil,
              [.waitingReview, .completed].contains(task[.geometry].state),
              displayImage(for: task) != nil, !loading.contains(task.id),
              task.roleImages?.snapshotVersion == task.snapshot?.contentVersion else { return false }
        return gates[task.id]?.canConfirm == true
    }
    @Published var notice: String?
    @Published var exportPolicy: WorkflowExportPolicy = .skipExisting
    @Published var exportHDSelected = true
    @Published var exportPNGSelected = true
    @Published var queueFilter = "全部"
    var runningTask: WorkflowSideTask? { batch?.activeTasks.first { task in task.records.values.contains { $0.state == .running } } }
    var runningDescription: String? {
        guard let task = runningTask, let specimen = batch?.specimens.first(where: { $0.front.id == task.id || $0.back.id == task.id }),
              let step = WorkflowStage.processingStages.first(where: { task[$0].state == .running }) else { return nil }
        return "\(specimen.baseName)_\(task.side.fileSuffix) · \(step.title)"
    }
    var batchSummary: String {
        let tasks = batch?.activeTasks ?? []
        let failed = tasks.filter { task in task.records.values.contains { $0.state == .failed } }.count
        let reviewing = tasks.filter { $0[.geometry].state == .waitingReview }.count
        let confirmed = tasks.filter { $0[.geometry].state == .completed && !$0.records.values.contains { [.running,.failed].contains($0.state) } }.count
        let running = tasks.filter { task in task.records.values.contains { $0.state == .running } }.count
        return "待处理 \(max(0,tasks.count-failed-reviewing-confirmed-running)) · 处理中 \(running) · 失败 \(failed) · 待检查 \(reviewing) · 已确认 \(confirmed)"
    }
    func summaryRecord(_ task: WorkflowSideTask) -> WorkflowStageRecord {
        if let record = task.records.values.first(where: { $0.state == .failed || $0.state == .running }) { return record }
        if task[.png4k].state == .completed { return task[.png4k] }
        if task[.hd].state == .completed { return task[.hd] }
        for step in [WorkflowStage.stack,.matte,.geometry] where task[step].state != .completed { return task[step] }
        return task[.geometry]
    }
    var filteredSpecimens: [WorkflowSpecimen] {
        (batch?.specimens ?? []).filter { specimen in
            if queueFilter == "全部" { return true }
            return [specimen.front,specimen.back].contains { task in
                switch queueFilter {
                case "失败": return task.records.values.contains { $0.state == .failed }
                case "待检查": return task[.geometry].state == .waitingReview
                case "已确认": return task[.geometry].state == .completed
                case "待导出": return task[.geometry].state == .completed && (task[.hd].state != .completed || task[.png4k].state != .completed)
                default: return true
                }
            }
        }
    }
    func selectCurrentTaskStage() {
        guard let task = currentTask else { return }
        // 选择变化由视图统一准备预览，避免阶段切换提前重复派发解码任务。
        isSelectingTaskStage = true; defer { isSelectingTaskStage = false }
        if task[.geometry].state == .completed { stage = .png4k }
        else if task[.geometry].state == .waitingReview { stage = .hd }
        else { stage = [WorkflowStage.stack,.matte,.geometry].first { task[$0].state != .completed } ?? .hd }
    }
    func locateRunning() {
        guard let task = runningTask, let specimen = batch?.specimens.first(where: { $0.front.id == task.id || $0.back.id == task.id }) else { return }
        currentSpecimenID = specimen.id; face = task.side; selectCurrentTaskStage()
    }
    func nextReview() {
        guard let batch, let task = batch.activeTasks.first(where: { $0.id != currentTask?.id && $0[.geometry].state == .waitingReview }),
              let specimen = batch.specimens.first(where: { $0.front.id == task.id || $0.back.id == task.id }) else { return }
        currentSpecimenID = specimen.id; face = task.side; stage = .hd
    }
    // 正在处理时也允许提交另一面的确认或导出；操作不改变当前查看图片。
    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
        if busy { Task { do { try await action(); await sync() } catch { self.error = error.localizedDescription } } }
        else { launch(action) }
    }
    func confirmCurrent() {
        guard canFinalize, let e = executor, let b = batch, let task = currentTask, let version = task.snapshot?.contentVersion else { return }
        enqueue { [self] in
            try await e.confirmFinalTasks(batchID: b.id, versions: [task.id:version]); await sync()
            notice = "此图已确认，可以单独或批量导出"
        }
    }
    func exportTaskIDs(scope: String) -> Set<UUID> {
        let candidates: [WorkflowSideTask]
        if scope == "此图" { candidates = currentTask.map { [$0] } ?? [] }
        else if scope == "所选" { candidates = batch?.activeTasks.filter { selectedTaskIDs.contains($0.id) } ?? [] }
        else { candidates = batch?.activeTasks ?? [] }
        return Set(candidates.filter { $0[.geometry].state == .completed && $0[.geometry].confirmedVersion == $0.snapshot?.contentVersion }.map(\.id))
    }
    func exportImages(scope: String) {
        guard let e = executor, let b = batch else { return }
        let ids = exportTaskIDs(scope: scope), kinds = Set(([exportHDSelected ? WorkflowAssetKind.hd : nil, exportPNGSelected ? .png4k : nil]).compactMap { $0 })
        guard !ids.isEmpty,!kinds.isEmpty else { error = "请选择已确认图片及至少一种输出"; return }
        let policy = exportPolicy, layouts = layouts.filter { ids.contains($0.key) }
        notice = busy ? "已加入导出队列，等待自动处理结束" : manualTaskID != nil ? "已加入导出队列，等待结束人工编辑并继续" : "正在导出"
        enqueue { [self] in try await e.requestExports(batchID: b.id,taskIDs: ids,kinds: kinds,policy: policy,layouts: layouts); await sync(); notice = batch?.activeTasks.contains(where: { !($0.requestedExports ?? [:]).isEmpty }) == true ? "导出已排队，逐张结果会持续更新" : "导出任务结束，逐张结果见导出记录" }
    }
    func finishEditing() {
        guard let e = executor,let b = batch else { return }
        launch { [self] in try await e.endManualEditing(batchID: b.id); manualTaskID = nil; await sync(); notice = "人工编辑已结束，点击继续处理恢复队列" }
    }
    // MARK: - 批次创建、打开与切换
    func scan(_ directory: URL) {
        do {
            let scanned = try WorkflowBatchDraft.scan(directory: directory,inputMode: inputMode)
            draft = scanned; names = inputMode == .psd ? scanned.groups.compactMap(\.suggestedName).joined(separator: "\n") : ""; error = nil
        } catch { draft = nil; names = ""; self.error = error.localizedDescription }
    }
    func start() {
        guard let draft else { error = "请选择输入文件夹"; return }
        let outputDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butterfly Toolkit/PhotoWorkflow/\(UUID().uuidString)", isDirectory: true)
        let locations = WorkflowOutputLocations(hd: hdDirectory, png4k: png4kDirectory)
        let names = names,stack = checkAfterStack,matte = checkAfterMatte,geometry = checkGeometry,fourK = check4K,provider = WorkflowMatteProvider.photoshop
        launch { [self] in
            let frozen = try await Task.detached { try draft.freeze(names: names,output: outputDirectory,checkStack: stack,checkMatte: matte,locations: locations,checkGeometry: geometry,check4K: fourK,manualFinalization: true,matteProvider: provider) }.value
            let e = makeExecutor(output: outputDirectory)
            let manifest = outputDirectory.appendingPathComponent("batch.json")
            try await e.register(batch: frozen,manifestURL: manifest)
            await clearPreviewState(); executor = e; manifestURL = manifest
            batch = try await e.batch(batchID: frozen.id); currentSpecimenID = frozen.specimens.first { !$0.isExcluded }?.id; selectedSpecimens = Set(frozen.specimens.filter { !$0.isExcluded }.map(\.id))
            try await e.runPending(batchID: frozen.id)
        }
    }
    func exportDirectory(for kind: WorkflowAssetKind) -> URL? {
        if let batch { return batch.exportDirectory(for: kind) }
        if let selected = kind == .hd ? hdDirectory : png4kDirectory { return selected }
        guard let directory = draft?.directory else { return nil }
        return directory.appendingPathComponent(directory.lastPathComponent + (kind == .hd ? "_堆栈原图" : "_4K_PNG"),isDirectory: true)
    }
    func selectExportDirectory(_ url: URL, kind: WorkflowAssetKind) {
        guard let executor, let batch else {
            if kind == .hd { hdDirectory = url } else { png4kDirectory = url }
            return
        }
        launch { try await executor.setExportDirectory(batchID: batch.id, kind: kind, directory: url) }
    }

    private var canSwitchBatch: Bool { !busy && manualTaskID == nil }
    func openBatch(_ url: URL) {
        guard canSwitchBatch else { error = "请先结束当前操作，并保存、刷新及明确继续人工 PSD 编辑"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            let e = makeExecutor(output: url.deletingLastPathComponent())
            let id = try await e.register(manifestURL: url)
            let value = try await e.batch(batchID: id)
            await clearPreviewState(); executor = e; manifestURL = url; batch = value
            currentSpecimenID = value.specimens.first { !$0.isExcluded }?.id
            selectedSpecimens = Set(value.specimens.filter { !$0.isExcluded }.map(\.id))
            stage = value.currentStage ?? .png4k
        }
    }
    func closeBatch() {
        guard canSwitchBatch else { error = "请先结束当前操作，并保存、刷新及明确继续人工 PSD 编辑"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            await clearPreviewState(); executor = nil; manifestURL = nil; batch = nil
            currentSpecimenID = nil; selectedSpecimens = []; draft = nil; names = ""; hdDirectory = nil; png4kDirectory = nil; stage = .stack
        }
    }
    private func persistBeforeSwitch() async throws {
        guard manualTaskID == nil else { throw WorkflowStateError.invalidTransition }
        guard let executor,let batch,let manifestURL else { return }
        await executor.pause(batchID: batch.id)
        let paused = try await executor.batch(batchID: batch.id)
        // 执行器暂停采用尽力保存策略；切换批次则必须确认持久化成功。
        try await WorkflowBatchStore().save(paused,to: manifestURL)
        self.batch = paused
    }
    private func clearPreviewState() async {
        isResettingPreviews = true
        defer { isResettingPreviews = false }
        for task in previewTasks.values { task.cancel() }
        previewTasks = [:]; images = [:]; imageIdentities = [:]; requestedImageIdentities = [:]
        gates = [:]; solutions = [:]; requests = [:]; layouts = [:]; loading = []; detailRequested = []; previewInteractionStarted = [:]; warmSources = []; cancelMove()
        await geometry.removeAll()
    }
    private func makeExecutor(output: URL) -> WorkflowExecutor {
        let workspace = output.appendingPathComponent(".work")
        return WorkflowExecutor(services: .live(bridge: PhotoshopWorkflowBridge(workspace: workspace),geometry: geometry))
    }
    // MARK: - 命令执行与状态同步
    private func launch(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        command = Task { [self] in
            let poll = Task { [self] in
                while !Task.isCancelled { await sync(); try? await Task.sleep(for: .milliseconds(350)) }
            }
            do { try await action() } catch { self.error = error.localizedDescription }
            poll.cancel(); await sync(); busy = false; prepareSelected()
        }
    }
    func sync(readBatch: @Sendable (WorkflowExecutor,UUID) async throws -> WorkflowBatch = { try await $0.batch(batchID: $1) }) async {
        guard let executor,let id = batch?.id else { return }
        do {
            let value = try await readBatch(executor,id)
            // 读取可能跨越批次切换；只接收仍属于当前执行器与批次的返回值。
            guard !Task.isCancelled,!isResettingPreviews,self.executor === executor,batch?.id == id else { return }
            let previous = batch; batch = value
            if let currentTask, let old = previous?.task(id: currentTask.id),
               old[stage].state == .running, currentTask[stage].state != .running {
                selectCurrentTaskStage()
            }
            for task in value.sideTasks where task.roleImages != previous?.task(id: task.id)?.roleImages {
                images[task.id] = nil; solutions[task.id] = nil; requests[task.id] = nil; gates[task.id] = nil
                if task.roleImages != nil { requestPreview(task: task) }
            }
        } catch {
            guard !Task.isCancelled,!isResettingPreviews,self.executor === executor,batch?.id == id else { return }
            self.error = error.localizedDescription
        }
    }
    func prepareSelected() {
        guard manualTaskID == nil || usesFinalization,let batch else { return }
        let ordered = batch.specimens.filter { $0.id == currentSpecimenID }
            + batch.specimens.filter { $0.id != currentSpecimenID && selectedSpecimens.contains($0.id) }
        var visible: [Task<Void,Never>] = []
        for specimen in ordered {
            for task in [specimen.front,specimen.back] where task.roleImages != nil {
                if gates[task.id] == nil || requestedImageIdentities[task.id] != desiredImageIdentity(task) {
                    requestPreview(task: task,after: specimen.id == currentSpecimenID ? [] : visible)
                }
                if specimen.id == currentSpecimenID,let pending = previewTasks[task.id] { visible.append(pending) }
            }
        }
    }
    func refreshVisibleImage() {
        guard manualTaskID == nil || usesFinalization,let task = currentTask else { return }; requestPreview(task: task)
    }
    // MARK: - 构图草稿与异步预览
    func editRequest(_ edit: (inout GeometryRequest) -> Void) {
        guard let task = currentTask,manualTaskID == nil else { return }
        if let version = task.snapshot?.contentVersion,warmSources.contains(version),images[task.id] != nil { previewInteractionStarted[task.id] = ProcessInfo.processInfo.systemUptime }
        var request = currentRequest; edit(&request); requests[task.id] = request
        // 交互时立即用缓存源图更新预览，精确校验随后异步完成。
        if var solution = solutions[task.id] {
            if case .manual(let angle) = request.angleStrategy { solution.angleDegrees = angle }
            let b = solution.subjectBounds,factor = 1-2*request.targetMargin
            var width = b.width/factor,height = b.height/factor
            let ratio: Double? = switch request.ratio { case .adaptive: nil; case .fiveByFour: 1.25; case .elevenByEightPointFive: 22.0/17; case .square: 1 }
            if let ratio { height = max(height,width/ratio); width = height*ratio }
            let center = request.centerOverride ?? CGPoint(x: b.midX,y: b.midY)
            solution.sourceCropRect = CGRect(x: center.x-width/2,y: center.y-height/2,width: width,height: height); solution.isApplicable = false
            solutions[task.id] = solution
        }
        requestPreview(task: task,request: request)
    }
    func resetSuggestion() { guard let task = currentTask else { return }; requests[task.id] = GeometryRequest(); requestPreview(task: task,request: GeometryRequest()) }
    func pickTip(_ point: CGPoint) {
        guard pickingTips else { return }; tips.append(point)
        if tips.count == 2 {
            let ordered = tips.sorted { $0.x < $1.x }; editRequest { $0.angleStrategy = .twoPoints(left: ordered[0],right: ordered[1]) }; pickingTips = false; tips = []
        }
    }
    func updateMove(_ delta: CGSize) {
        guard manualTaskID == nil,!busy,(stage == .geometry && !usesFinalization) || stage == .png4k else { return }
        isDragging = true; dragOffset = delta
        if let id = currentTask?.id { previewInteractionStarted[id] = ProcessInfo.processInfo.systemUptime }
    }
    func cancelMove() { isDragging = false; dragOffset = .zero }
    func commitMove(_ delta: CGSize) { cancelMove(); move(delta) }
    private func move(_ delta: CGSize) {
        if stage == .png4k { var l = currentLayout; l.center.x += delta.width; l.center.y += delta.height; editLayout(l) }
        else if let solution = currentSolution { editRequest { $0.centerOverride = CGPoint(x: solution.sourceCropRect.midX-delta.width,y: solution.sourceCropRect.midY-delta.height) } }
    }
    func editLayout(_ layout: SquareLayout) {
        guard let task = currentTask,manualTaskID == nil else { return }
        if images[task.id] != nil { previewInteractionStarted[task.id] = ProcessInfo.processInfo.systemUptime }
        layouts[task.id] = layout
    }
    private func squareValid(task: WorkflowSideTask) -> Bool {
        guard let solution = solutions[task.id],solution.subjectBounds.width > 0,solution.subjectBounds.height > 0 else { return false }
        let l = layouts[task.id] ?? task.squareLayout,b = solution.subjectBounds,s = min(Double(l.canvasSide-2*l.safeMargin)/b.width,Double(l.canvasSide-2*l.safeMargin)/b.height)
        return l.safeMargin >= 0 && l.safeMargin <= 512 && l.center.x-b.width*s/2 >= 0 && l.center.y-b.height*s/2 >= 0 && l.center.x+b.width*s/2 <= 4096 && l.center.y+b.height*s/2 <= 4096
    }
    private func requestPreview(task: WorkflowSideTask,request: GeometryRequest? = nil,after predecessors: [Task<Void,Never>] = []) {
        guard !isResettingPreviews,let roles = task.roleImages,let identity = desiredImageIdentity(task) else { return }
        previewTasks[task.id]?.cancel()
        requestedImageIdentities[task.id] = identity
        if imageIdentities[task.id] != identity { images[task.id] = nil; imageIdentities[task.id] = nil }
        // 取消旧任务之外还更新令牌，拦截不响应取消的解码或几何服务迟到结果。
        var gate = gates[task.id] ?? WorkflowPreviewGate(); let token = gate.begin(sourceVersion: roles.snapshotVersion); gates[task.id] = gate; loading.insert(task.id)
        let request = request ?? requests[task.id] ?? task.geometryRequest
        let saved = task.geometrySolution
        let useSaved = requests[task.id] == nil && (task[.geometry].state == .completed || task.geometryRevalidationRequired || usesFinalization)
        previewTasks[task.id] = Task { [self] in
            for predecessor in predecessors { await predecessor.value }
            do {
                try Task.checkCancellation()
                let image = try await previews.image(url: identity.url,version: roles.snapshotVersion,maximumPixelSize: identity.maximumPixelSize)
                guard !Task.isCancelled,gates[task.id]?.token == token,desiredImageIdentity(task) == identity else { return }
                imageIdentities[task.id] = identity; images[task.id] = image
                let solution = try await previews.geometry(source: roles,request: request,savedCandidate: useSaved ? saved : nil)
                guard !Task.isCancelled,gates[task.id]?.token == token else { return }
                guard solution.sourceVersion == roles.snapshotVersion else { throw WorkflowBridgeError.staleSource }
                guard !Task.isCancelled,gates[task.id]?.accept(token: token,sourceVersion: roles.snapshotVersion,valid: solution.isApplicable) == true else { return }
                solutions[task.id] = solution; loading.remove(task.id); warmSources.insert(roles.snapshotVersion)
            } catch is CancellationError {} catch {
                guard gates[task.id]?.token == token else { return }; loading.remove(task.id); self.error = error.localizedDescription
            }
        }
    }
    // MARK: - 检查点确认与人工编辑
    func primary() {
        if usesFinalization {
            if stage == .hd || stage == .geometry { confirmCurrent() }
            else if stage == .png4k { exportImages(scope: "此图") }
            return
        }
        guard let e = executor,let b = batch else { return }
        let selected = b.specimens.filter { selectedSpecimens.contains($0.id) }.flatMap { [$0.front,$0.back] }
        launch { [self] in
            switch stage {
            case .stack,.matte: try await e.continueAfterReview(batchID: b.id,stage: stage,specimenIDs: b.specimens.filter { !$0.isExcluded }.map(\.id))
            case .geometry:
                if usesFinalization {
                    try await e.confirmFinalPSD(batchID: b.id,specimenIDs: selectedSpecimens)
                    manualTaskID = nil; await clearPreviewState(); await sync(); stage = .png4k
                    return
                }
                try await e.confirmGeometry(batchID: b.id,solutions: Dictionary(uniqueKeysWithValues: selected.compactMap { task in solutions[task.id].map { (task.id,$0) } }),exportHD: true)
            case .png4k:
                try await e.confirm4K(batchID: b.id,layouts: Dictionary(uniqueKeysWithValues: selected.map { ($0.id,layouts[$0.id] ?? $0.squareLayout) }))
            case .derivatives: throw WorkflowStateError.invalidTransition
            case .hd: try await e.retry(batchID: b.id,specimenIDs: Array(selectedSpecimens),stage: stage)
            }
        }
    }
    func retry() { guard let e = executor,let b = batch else { return }; enqueue { try await e.retryTasks(batchID: b.id,taskIDs: Set(b.activeTasks.map(\.id))) } }
    func reprocessCurrent(from stage: WorkflowStage) {
        guard let e = executor, let b = batch, let task = currentTask else { return }
        launch { [self] in
            try await e.reprocessTask(batchID: b.id,taskID: task.id,from: stage,expectedVersion: task.snapshot?.contentVersion)
            await clearPreviewState(); await sync(); selectCurrentTaskStage()
        }
    }
    func retryCurrent() { guard let e = executor,let b = batch,let task = currentTask else { return }; enqueue { try await e.retryTasks(batchID: b.id,taskIDs: [task.id]) } }
    func excludeSelected() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.update(batchID: b.id,event: .excludeSpecimens(ids: selectedSpecimens,reason: "用户暂不处理",expectedRevision: b.revision)); try await e.runPending(batchID: b.id) } }
    func pause() { guard let e = executor,let b = batch else { return }; notice = "正在等待当前步骤安全保存并暂停"; Task { await e.pause(batchID: b.id); await sync() } }
    func resume() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.continueAutomatic(batchID: b.id); manualTaskID = nil } }
    var canOpenPSD: Bool { currentTask?.snapshot != nil && (manualTaskID == nil || manualTaskID == currentTask?.id) }
    func openPSD() {
        guard canOpenPSD,let e = executor,let b = batch,let task = currentTask else { return }
        enqueue { [self] in let url = try await e.beginManualEditing(batchID: b.id,taskID: task.id); manualTaskID = task.id; if usesFinalization { stage = .geometry }; NSWorkspace.shared.open(url) }
    }
    func migrateToFinalization() {
        guard let e = executor,let b = batch else { return }
        launch { [self] in
            try await e.migrateToFinalization(batchID: b.id)
            await clearPreviewState(); await sync(); stage = .geometry
        }
    }
    func adoptCurrentPSD() {
        guard let e = executor, let b = batch, let id = manualTaskID else { return }
        launch { [self] in
            try await e.adoptCurrentPSD(batchID: b.id,taskID: id)
            await clearPreviewState(); await sync(); stage = .hd
            notice = "已采用保存的姿态与裁切，请结束编辑后检查确认"
        }
    }
    func refreshSaved() {
        guard let e = executor,let b = batch,let taskID = manualTaskID ?? (usesFinalization ? currentTask?.id : nil) else { return }
        images[taskID] = nil; gates[taskID] = nil; solutions[taskID] = nil
        launch { [self] in
            if usesFinalization {
                if manualTaskID == taskID { try await e.refreshManualPSD(batchID: b.id,taskID: taskID) }
                else { try await e.refreshFinalPSD(batchID: b.id,taskID: taskID) }
                await clearPreviewState(); await sync(); stage = .geometry; return
            }
            try await e.refreshSavedPSD(batchID: b.id,taskID: taskID,change: manualChange); await sync(); if let task = batch?.task(id: taskID) { requestPreview(task: task) }; if manualChange != .maskOnly { stage = .geometry } }
    }
}
