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
        let files = try FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(),includingPropertiesForKeys: [.isRegularFileKey],options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
    func freeze(names: String,output: URL,locations: WorkflowOutputLocations? = nil,geometryRequest: GeometryRequest = GeometryRequest()) throws -> WorkflowBatch {
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
                task.geometryRequest = geometryRequest
                if group.excluded { for stage in WorkflowStage.allCases { task[stage].state = .excluded; task[stage].exclusionReason = "建批次时排除" } }; return task
            }
            return WorkflowSpecimen(id: group.id,baseName: name,front: side(.front,0),back: side(.back,inputMode.filesPerSide),exclusionReason: group.excluded ? "建批次时排除" : nil)
        }
        var batch = WorkflowBatch(sourceDirectory: directory.resolvingSymlinksInPath(),sourceDirectoryName: directory.lastPathComponent,outputDirectory: output,outputLocations: locations,specimens: specimens)
        let root = batch.generatedPSDDirectory
        // 为同名新批次冻结独立目录；断开的链接也占用名字，不能靠重试认领上一批文件。
        func occupied(_ file: URL) -> Bool {
            FileManager.default.fileExists(atPath: file.path) ||
                (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
        }
        batch.psdBatchSubdirectory = specimens.contains { specimen in
            WorkflowSide.allCases.contains { side in
                let file = root.appendingPathComponent("\(specimen.baseName)_\(side.fileSuffix).psd")
                return occupied(file) || occupied(file.appendingPathExtension("workflow-owner.json"))
            }
        }
        try batch.validate(); return batch
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
    var workingPSDDirectory: URL? {
        if let task = currentTask {
            if let saved = task.snapshot { return saved.workingURL.deletingLastPathComponent() }
        }
        return batch?.generatedPSDDirectory
    }
    @Published var draftGeometryRequest = GeometryRequest()
    var canStart: Bool { draft != nil }
    @Published var batch: WorkflowBatch?
    @Published var selectedSpecimens: Set<UUID> = []
    @Published var selectedTaskIDs: Set<UUID> = []
    @Published var currentSpecimenID: UUID? { didSet { if currentSpecimenID != oldValue { retainCurrentDetailOnly(); selectCurrentTaskStage() } } }
    @Published var face: WorkflowSide = .front { didSet { if face != oldValue { retainCurrentDetailOnly(); selectCurrentTaskStage() } } }
    @Published var stage: WorkflowStage = .stack { didSet { if stage != oldValue { cancelMove(); if !isSelectingTaskStage { prepareSelected() } } } }
    private var isSelectingTaskStage = false
    @Published var error: String?
    @Published var busy = false
    // 每个阶段只记住本阶段的看图选择，切换时不会沿用另一个阶段的图层或底色。
    @Published private var previewModes: [WorkflowStage: String] = [:]
    @Published private var previewBackgrounds: [WorkflowStage: String] = [:]
    var previewMode: String {
        get { previewModes[stage] ?? (stage == .matte || stage == .png4k ? "抠图" : "底图") }
        set { guard newValue != previewMode else { return }; previewModes[stage] = newValue; prepareSelected() }
    }
    var previewBackground: String {
        get { previewBackgrounds[stage] ?? (stage == .matte ? "天蓝" : "棋盘") }
        set { previewBackgrounds[stage] = newValue }
    }
    @Published var zoom = 1.0
    @Published var showSafeFrame = true
    @Published private(set) var images: [UUID: CGImage] = [:]
    @Published private(set) var imageIdentities: [UUID: WorkflowPreviewImageIdentity] = [:]
    @Published private(set) var isDragging = false
    @Published private(set) var dragOffset: CGSize = .zero
    @Published private(set) var detailRequested: Set<UUID> = []
    private var requestedImageIdentities: [UUID: WorkflowPreviewImageIdentity] = [:]
    @Published private(set) var solutions: [UUID: GeometrySolution] = [:]
    @Published private(set) var layouts: [UUID: SquareLayout] = [:]
    @Published private(set) var gates: [UUID: WorkflowPreviewGate] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var previewInteractionStarted: [UUID: TimeInterval] = [:]
    @Published var manualTaskID: UUID?
    private var executor: WorkflowExecutor?
    @Published private(set) var isUpdatingReview = false
    @Published private(set) var manualReviewSessionID: UUID?
    @Published private(set) var manualObservationError: String?
    @Published private(set) var photoshopOpenErrors: [UUID: String] = [:]
    @Published private(set) var preparingExportPreview: UUID?
    @Published private var exportPreviewVersions: [UUID: String] = [:]
    private var reviewObservation: Task<Void,Never>?
    private let makeReviewExecutor: ((URL) -> WorkflowExecutor)?
    private let openPhotoshopDocument: (URL) async throws -> Void
    private let isApplicationActive: @MainActor @Sendable () -> Bool
    private var isResettingPreviews = false
    private let geometry: WorkflowGeometryCache
    private let previews: any WorkflowPreviewServing
    private(set) var previewTasks: [UUID: Task<Void,Never>] = [:]
    private var command: Task<Void,Never>?
    init(geometry: WorkflowGeometryCache = WorkflowGeometryCache(),previews: (any WorkflowPreviewServing)? = nil,
         makeExecutor: ((URL) -> WorkflowExecutor)? = nil,
         openPhotoshopDocument: @escaping (URL) async throws -> Void = PhotoWorkflowStore.openInPhotoshop,
         isApplicationActive: @escaping @MainActor @Sendable () -> Bool = { NSApplication.shared.isActive }) {
        self.geometry = geometry; self.previews = previews ?? WorkflowPreviewService(geometry: geometry)
        self.makeReviewExecutor = makeExecutor; self.openPhotoshopDocument = openPhotoshopDocument
        self.isApplicationActive = isApplicationActive
    }
    var currentSpecimen: WorkflowSpecimen? { batch?.specimens.first { $0.id == currentSpecimenID } }
    var currentTask: WorkflowSideTask? { face == .front ? currentSpecimen?.front : currentSpecimen?.back }
    var currentSolution: GeometrySolution? { currentTask.flatMap { solutions[$0.id] ?? $0.geometrySolution } }

    var currentLayout: SquareLayout { currentTask.flatMap { layouts[$0.id] } ?? currentTask?.squareLayout ?? .png4k }
    var currentPreviewLayout: SquareLayout {
        var value = currentLayout
        if isDragging { value.center.x += dragOffset.width; value.center.y += dragOffset.height }
        return value
    }
    var currentPreviewSolution: GeometrySolution? { currentSolution }
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
        if stage == .png4k && !hasRequestedExportPreview(task) { return nil }
        let mode = stage == .png4k ? "抠图" : previewMode
        let url = mode == "蒙版" ? roles.maskPNG : mode == "抠图" ? roles.cutoutPNG : roles.basePNG
        return WorkflowPreviewImageIdentity(sourceVersion: roles.snapshotVersion,url: url,maximumPixelSize: detailRequested.contains(task.id) ? Int(max(roles.pixelSize.width,roles.pixelSize.height)) : 2048)
    }
    func loadCurrentDetail() {
        guard let task = currentTask,desiredImageIdentity(task) != nil else { return }
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
        guard let task = currentTask else { return }
        detailRequested.remove(task.id); requestPreview(task: task)
    }

    var canResumeAutomatic: Bool {
        guard batch?.isPaused == true else { return false }
        guard manualReviewSessionID == nil, !isUpdatingReview else { return false }
        return manualTaskID == nil || batch?.activeTasks.contains { task in
            [WorkflowStage.stack,.matte,.geometry].contains { task[$0].state == .pending }
        } == true
    }
    func displayedRecord(_ task: WorkflowSideTask) -> WorkflowStageRecord {
        if stage == .hd { return task[.geometry] }
        if stage == .png4k && task[.hd].state == .failed { return task[.hd] }
        return task[stage]
    }
    private func isReviewable(_ task: WorkflowSideTask) -> Bool {
        task.snapshot?.taskID == task.id && task[.stack].state == .completed && task[.matte].state == .completed &&
            [.waitingReview,.completed].contains(task[.geometry].state) &&
            task.geometryApplySourceVersion == nil && task.manualAdoptionRequired != true
    }
    var hasManualEditing: Bool { manualTaskID != nil || manualReviewSessionID != nil }
    var hasQueuedExports: Bool { batch?.activeTasks.contains { !($0.requestedExports ?? [:]).isEmpty } == true }
    var canFinalize: Bool {
        guard !busy, !isUpdatingReview, manualTaskID == nil,
              currentSpecimen?.isExcluded == false, let task = currentTask, isReviewable(task) else { return false }
        if task.manualEdit?.observedDocumentID != nil { return manualObservationError != nil }
        return task[.geometry].state == .waitingReview || task.manualEdit != nil || task.manualEditError != nil
    }
    func reviewStatus(_ task: WorkflowSideTask) -> String {
        if photoshopOpenErrors[task.id] != nil { return "打开失败" }
        if task.manualEditError != nil { return "确认失败" }
        if let edit = task.manualEdit { return edit.observedDocumentID == nil ? "等待打开" : "精修中" }
        if task[.geometry].state == .completed { return "已确认" }
        if task[.geometry].state == .waitingReview { return "待检查" }
        return task[.geometry].state.title
    }
    func outputPreparationStatus(_ task: WorkflowSideTask) -> String? {
        if task.finalPreparationError != nil { return "输出校验失败" }
        return task.pendingFinalPSD == nil ? nil : "待准备输出"
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
                case "失败": return photoshopOpenErrors[task.id] != nil || task.manualEditError != nil ||
                    task.finalPreparationError != nil || task.records.values.contains { $0.state == .failed }
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
        if isReviewable(task) {
            if stage == .hd || stage == .png4k { return }
            if hasManualEditing { stage = .hd; return }
        }
        if task[.geometry].state == .completed { stage = .png4k }
        else if task[.geometry].state == .waitingReview { stage = .hd }
        else { stage = [WorkflowStage.stack,.matte,.geometry].first { task[$0].state != .completed } ?? .hd }
    }
    func locateRunning() {
        guard let task = runningTask, let specimen = batch?.specimens.first(where: { $0.front.id == task.id || $0.back.id == task.id }) else { return }
        currentSpecimenID = specimen.id; face = task.side; selectCurrentTaskStage()
    }
    private var nextReviewTask: WorkflowSideTask? {
        batch?.activeTasks.first { $0.id != currentTask?.id && $0.manualEdit == nil && $0[.geometry].state == .waitingReview }
    }
    var hasNextReview: Bool { nextReviewTask != nil }
    func nextReview() {
        guard let batch, let task = nextReviewTask,
              let specimen = batch.specimens.first(where: { $0.front.id == task.id || $0.back.id == task.id }) else { return }
        currentSpecimenID = specimen.id; face = task.side; stage = .hd
    }
    // 正在处理时也允许提交另一面的确认或导出；操作不改变当前查看图片。
    private func enqueue(_ action: @escaping @MainActor () async throws -> Void) {
        if busy { Task { do { try await action(); await sync() } catch { self.error = error.localizedDescription } } }
        else { launch(action) }
    }
    func confirmCurrent() {
        guard canFinalize, let task = currentTask else { return }
        updateReview { executor, batchID in
            try await executor.confirmSavedTasks(batchID: batchID, taskIDs: [task.id])
        }
    }
    func exportTaskIDs(scope: String) -> Set<UUID> {
        let candidates: [WorkflowSideTask]
        if scope == "此图" { candidates = currentTask.map { [$0] } ?? [] }
        else if scope == "所选" { candidates = batch?.activeTasks.filter { selectedTaskIDs.contains($0.id) } ?? [] }
        else { candidates = batch?.activeTasks ?? [] }
        return Set(candidates.filter { task in
            task.manualEdit == nil && task[.geometry].state == .completed &&
                task.finalPSDVersion != nil && task[.geometry].confirmedVersion == task.finalPSDVersion
        }.map(\.id))
    }
    func exportImages(scope: String) {
        guard !isUpdatingReview, let e = executor, let b = batch else { return }
        let ids = exportTaskIDs(scope: scope), kinds = Set(([exportHDSelected ? WorkflowAssetKind.hd : nil, exportPNGSelected ? .png4k : nil]).compactMap { $0 })
        guard !ids.isEmpty,!kinds.isEmpty else { error = "请选择已确认图片及至少一种输出"; return }
        let policy = exportPolicy, layouts = layouts.filter { ids.contains($0.key) }
        if manualReviewSessionID != nil {
            updateReview { [self] executor, batchID in
                try await executor.requestExports(batchID: batchID, taskIDs: ids, kinds: kinds, policy: policy, layouts: layouts)
                await sync()
                notice = hasQueuedExports ? "已加入导出队列" : "导出任务结束，逐张结果见导出记录"
            }
        } else {
            notice = hasManualEditing ? "正在加入导出队列" : "正在导出"
            enqueue { [self] in
                try await e.requestExports(batchID: b.id,taskIDs: ids,kinds: kinds,policy: policy,layouts: layouts)
                await sync()
                notice = hasQueuedExports ? "导出已排队，逐张结果会持续更新" : "导出任务结束，逐张结果见导出记录"
            }
        }
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
        let names = names, request = draftGeometryRequest
        launch { [self] in
            let frozen = try await Task.detached { try draft.freeze(names: names,output: outputDirectory,locations: locations,geometryRequest: request) }.value
            let e = makeExecutor(output: outputDirectory)
            let manifest = outputDirectory.appendingPathComponent("batch.json")
            try await e.register(batch: frozen,manifestURL: manifest)
            await clearPreviewState(); executor = e
            batch = try await e.batch(batchID: frozen.id); currentSpecimenID = frozen.specimens.first { !$0.isExcluded }?.id; selectedSpecimens = Set(frozen.specimens.filter { !$0.isExcluded }.map(\.id))
            try await e.runPending(batchID: frozen.id)
        }
    }
    func exportDirectory(for kind: WorkflowAssetKind) -> URL? {
        guard kind == .hd || kind == .png4k else { return nil }
        if let batch { return batch.exportDirectory(for: kind) }
        if let selected = kind == .hd ? hdDirectory : png4kDirectory { return selected }
        guard let directory = draft?.directory else { return nil }
        return directory.resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent + (kind == .hd ? "_堆栈原图" : "_4K_PNG"),isDirectory: true)
    }
    var canChangeExportDirectory: Bool { canSwitchBatch }
    func selectExportDirectory(_ url: URL, kind: WorkflowAssetKind) {
        guard canChangeExportDirectory else { return }
        guard let executor, let batch else {
            if kind == .hd { hdDirectory = url } else { png4kDirectory = url }
            return
        }
        launch { try await executor.setExportDirectory(batchID: batch.id, kind: kind, directory: url) }
    }

    var canSwitchBatch: Bool { !busy && !isUpdatingReview && !hasManualEditing }
    func openBatch(_ url: URL) {
        guard canSwitchBatch else { error = "请先关闭正在精修的 PSD，等待核对完成"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            let e = makeExecutor(output: url.deletingLastPathComponent())
            let id = try await e.register(manifestURL: url)
            let value = try await e.batch(batchID: id)
            let session = await e.manualReviewLeaseID(batchID: id)
            await clearPreviewState(); executor = e; batch = value; manualReviewSessionID = session
            currentSpecimenID = value.specimens.first { !$0.isExcluded }?.id
            selectedSpecimens = Set(value.specimens.filter { !$0.isExcluded }.map(\.id))
            if let editing = value.activeTasks.first(where: { $0.manualEdit != nil }),
               let specimen = value.specimens.first(where: { $0.front.id == editing.id || $0.back.id == editing.id }) {
                currentSpecimenID = specimen.id; face = editing.side; stage = .hd
            } else {
                stage = value.currentStage ?? .png4k
                if stage == .geometry {
                    if currentTask?[.geometry].state == .waitingReview { stage = .hd }
                    else { nextReview() }
                }
            }
        }
    }
    func closeBatch() {
        guard canSwitchBatch else { error = "请先关闭正在精修的 PSD，等待核对完成"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            await clearPreviewState(); executor = nil; batch = nil; manualReviewSessionID = nil
            currentSpecimenID = nil; selectedSpecimens = []; draft = nil; names = ""; hdDirectory = nil; png4kDirectory = nil; stage = .stack
        }
    }
    private func persistBeforeSwitch() async throws {
        guard let executor, let batch else { return }
        try await executor.prepareToCloseBatch(batchID: batch.id)
        await sync()
    }
    private func clearPreviewState() async {
        isResettingPreviews = true
        defer { isResettingPreviews = false }
        for task in previewTasks.values { task.cancel() }
        exportPreviewVersions = [:]; preparingExportPreview = nil; photoshopOpenErrors = [:]
        manualObservationError = nil; selectedTaskIDs = []
        previewTasks = [:]; images = [:]; imageIdentities = [:]; requestedImageIdentities = [:]
        gates = [:]; solutions = [:]; layouts = [:]; loading = []; detailRequested = []; previewInteractionStarted = [:]; cancelMove()
        await geometry.removeAll()
    }
    private func makeExecutor(output: URL) -> WorkflowExecutor {
        if let makeReviewExecutor { return makeReviewExecutor(output) }
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
        guard let executor,let id = batch?.id,let revision = batch?.revision else { return }
        do {
            let value = try await readBatch(executor,id)
            // 读取可能跨越批次切换；只接收仍属于当前执行器与批次的返回值。
            guard !Task.isCancelled,!isResettingPreviews,self.executor === executor,
                  let previous = batch,previous.id == id,value.revision >= previous.revision else { return }
            if value.revision == previous.revision { return }
            batch = value
            if let currentTask, let old = previous.task(id: currentTask.id) {
                if [.stack,.matte,.geometry].contains(stage),
                   !isReviewable(old), isReviewable(currentTask) {
                    stage = .hd
                } else if old[stage].state == .running, currentTask[stage].state != .running {
                    selectCurrentTaskStage()
                }
            }
            let previousTasks = Dictionary(uniqueKeysWithValues: previous.sideTasks.map { ($0.id, $0) })
            for task in value.sideTasks {
                guard let old = previousTasks[task.id] else { continue }
                if photoshopOpenErrors[task.id] != nil, task.manualEdit == nil || task.manualEdit?.observedDocumentID != nil {
                    photoshopOpenErrors[task.id] = nil
                }
                let changedVersion = task.finalPSDVersion != old.finalPSDVersion || task.sourceRevision != old.sourceRevision
                guard changedVersion || task.roleImages != old.roleImages else { continue }
                invalidatePreview(task.id)
                if changedVersion { layouts[task.id] = nil; exportPreviewVersions[task.id] = nil }
                if task.id == currentSpecimen?.front.id || task.id == currentSpecimen?.back.id {
                    requestPreview(task: task)
                }
            }
        } catch {
            guard !Task.isCancelled,!isResettingPreviews,self.executor === executor,batch?.id == id,batch?.revision == revision else { return }
            self.error = error.localizedDescription
        }
    }
    private func invalidatePreview(_ id: UUID) {
        previewTasks.removeValue(forKey: id)?.cancel()
        images[id] = nil; imageIdentities[id] = nil; requestedImageIdentities[id] = nil
        solutions[id] = nil; gates[id] = nil; loading.remove(id)
        previewInteractionStarted[id] = nil
    }
    func prepareSelected() {
        guard let specimen = currentSpecimen else { return }
        for task in [specimen.front,specimen.back] {
            guard let identity = desiredImageIdentity(task) else { continue }
            if gates[task.id] == nil || requestedImageIdentities[task.id] != identity { requestPreview(task: task) }
        }
    }
    func refreshVisibleImage() {
        guard let task = currentTask else { return }; requestPreview(task: task)
    }
    // MARK: - 构图草稿与异步预览
    func updateMove(_ delta: CGSize) {
        guard manualTaskID == nil,!busy,stage == .png4k else { return }
        isDragging = true; dragOffset = delta
        if let id = currentTask?.id { previewInteractionStarted[id] = ProcessInfo.processInfo.systemUptime }
    }
    func cancelMove() { isDragging = false; dragOffset = .zero }
    func commitMove(_ delta: CGSize) { cancelMove(); move(delta) }
    private func move(_ delta: CGSize) {
        guard stage == .png4k else { return }
        var layout = currentLayout; layout.center.x += delta.width; layout.center.y += delta.height; editLayout(layout)
    }
    func editLayout(_ layout: SquareLayout) {
        guard let task = currentTask,manualTaskID == nil else { return }
        if images[task.id] != nil { previewInteractionStarted[task.id] = ProcessInfo.processInfo.systemUptime }
        layouts[task.id] = layout
    }

    private func requestPreview(task: WorkflowSideTask) {
        guard !isResettingPreviews, let batchID = batch?.id, let roles = task.roleImages, let identity = desiredImageIdentity(task) else { return }
        previewTasks[task.id]?.cancel()
        requestedImageIdentities[task.id] = identity
        if imageIdentities[task.id] != identity { images[task.id] = nil; imageIdentities[task.id] = nil }
        // 取消旧任务之外还更新令牌，拦截不响应取消的解码或几何服务迟到结果。
        var gate = gates[task.id] ?? WorkflowPreviewGate(); let token = gate.begin(sourceVersion: roles.snapshotVersion); gates[task.id] = gate; loading.insert(task.id)
        let request = task.geometryRequest
        let saved = task.geometrySolution
        previewTasks[task.id] = Task { [self] in
            do {
                try Task.checkCancellation()
                let image = try await previews.image(url: identity.url,version: roles.snapshotVersion,maximumPixelSize: identity.maximumPixelSize)
                guard !Task.isCancelled, batch?.id == batchID, batch?.task(id: task.id)?.roleImages == roles,
                      gates[task.id]?.token == token else { return }
                imageIdentities[task.id] = identity; images[task.id] = image
                let solution = try await previews.geometry(source: roles,request: request,savedCandidate: saved)
                guard !Task.isCancelled, batch?.id == batchID, batch?.task(id: task.id)?.roleImages == roles,
                      gates[task.id]?.token == token else { return }
                guard solution.sourceVersion == roles.snapshotVersion else { throw WorkflowBridgeError.staleSource }
                guard !Task.isCancelled,gates[task.id]?.accept(token: token,sourceVersion: roles.snapshotVersion,valid: solution.isApplicable) == true else { return }
                solutions[task.id] = solution; loading.remove(task.id)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, batch?.id == batchID, gates[task.id]?.token == token else { return }
                loading.remove(task.id); self.error = error.localizedDescription
            }
        }
    }
    // MARK: - 检查点确认与人工编辑
    func primary() {
        if stage == .hd { confirmCurrent() }
        else if stage == .png4k { exportImages(scope: "此图") }
    }
    func retry() { guard let e = executor,let b = batch else { return }; let stage = stage; enqueue { try await e.retryTasks(batchID: b.id,taskIDs: Set(b.activeTasks.map(\.id)),stage: stage) } }
    func reprocessCurrent(from stage: WorkflowStage) {
        guard !hasManualEditing, !isUpdatingReview, let e = executor, let b = batch, let task = currentTask else { return }
        launch { [self] in
            try await e.reprocessTask(batchID: b.id,taskID: task.id,from: stage,expectedVersion: task.finalPSDVersion)
            invalidatePreview(task.id); layouts[task.id] = nil; exportPreviewVersions[task.id] = nil
            await sync(); selectCurrentTaskStage()
        }
    }
    func retryCurrent() { guard let e = executor,let b = batch,let task = currentTask else { return }; let stage = stage; enqueue { try await e.retryTasks(batchID: b.id,taskIDs: [task.id],stage: stage) } }
    func excludeSelected() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.update(batchID: b.id,event: .excludeSpecimens(ids: selectedSpecimens,reason: "用户暂不处理",expectedRevision: b.revision)); try await e.runPending(batchID: b.id) } }
    func pause() { guard let e = executor,let b = batch else { return }; notice = "正在等待当前步骤安全保存并暂停"; Task { await e.pause(batchID: b.id); await sync() } }
    func resume() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.continueAutomatic(batchID: b.id); manualTaskID = nil } }
    private func usesBatchReview(for task: WorkflowSideTask) -> Bool {
        manualTaskID != task.id && isReviewable(task)
    }
    var canOpenPSD: Bool {
        guard let task = currentTask, task.snapshot != nil, currentSpecimen?.isExcluded == false else { return false }
        // 未走完自动阶段的失败面保留单面修补入口。
        if !usesBatchReview(for: task) {
            return !isUpdatingReview && manualReviewSessionID == nil && (manualTaskID == nil || manualTaskID == task.id)
        }
        return !busy && !isUpdatingReview && manualTaskID == nil && canOpenReviewPSD(task)
    }
    func openPSD() {
        guard canOpenPSD,let e = executor,let b = batch,let task = currentTask else { return }
        if usesBatchReview(for: task) {
            openReviewPSDs([task.id])
        } else {
            enqueue { [self] in
                let url = try await e.beginManualEditing(batchID: b.id,taskID: task.id)
                manualTaskID = task.id
                try await openPhotoshopDocument(url)
            }
        }
    }
    // MARK: - 批量精修与按需输出预览

    var trackedReviewCount: Int { batch?.activeTasks.filter { $0.manualEdit != nil }.count ?? 0 }
    private func canOpenReviewPSD(_ task: WorkflowSideTask) -> Bool {
        isReviewable(task) && task.manualEdit?.observedDocumentID == nil
    }
    var selectedReviewTaskIDs: Set<UUID> {
        Set((batch?.activeTasks ?? []).filter { selectedTaskIDs.contains($0.id) && canOpenReviewPSD($0) }.map(\.id))
    }
    var canOpenSelectedPSDs: Bool {
        !busy && !isUpdatingReview && manualTaskID == nil && !selectedReviewTaskIDs.isEmpty
    }
    func openSelectedPSDs() {
        guard canOpenSelectedPSDs else { return }
        openReviewPSDs(selectedReviewTaskIDs)
    }
    private func openReviewPSDs(_ ids: Set<UUID>) {
        updateReview { [self] executor, batchID in
            let urls = try await executor.beginBatchEditing(batchID: batchID, taskIDs: ids)
            await sync()
            let selected = batch?.activeTasks.filter { ids.contains($0.id) } ?? []
            for url in urls {
                guard let id = selected.first(where: { $0.manualEdit?.workingURL == url })?.id else { throw WorkflowStateError.invalidTransition }
                photoshopOpenErrors[id] = nil
                do { try await openPhotoshopDocument(url) }
                catch { photoshopOpenErrors[id] = error.localizedDescription }
            }
        }
    }
    private static func openInPhotoshop(_ url: URL) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") else {
            throw WorkflowBridgeError.photoshop("找不到 Adobe Photoshop")
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
    }
    var canStopTrackingCurrentPSD: Bool {
        guard let edit = currentTask?.manualEdit else { return false }
        return edit.observedDocumentID == nil && !isUpdatingReview
    }
    func stopTrackingCurrentPSD() {
        guard canStopTrackingCurrentPSD, let id = currentTask?.id else { return }
        updateReview { executor, batchID in
            try await executor.cancelClosedBatchEdits(batchID: batchID, taskIDs: [id])
        }
    }

    /// 和轮询串行进入执行器，选择图片和切换面板在等待期间仍然可用。
    private func updateReview(_ action: @escaping (WorkflowExecutor, UUID) async throws -> Void) {
        guard !isUpdatingReview, let executor, let id = batch?.id else { return }
        isUpdatingReview = true; error = nil
        Task { [self] in
            await reviewObservation?.value
            do { try await action(executor, id) }
            catch { self.error = error.localizedDescription }
            await sync()
            await syncReviewLease(executor, batchID: id)
            isUpdatingReview = false
            continueQueuedExports()
        }
    }
    private func syncReviewLease(_ executor: WorkflowExecutor, batchID: UUID) async {
        let session = await executor.manualReviewLeaseID(batchID: batchID)
        guard !Task.isCancelled, self.executor === executor, batch?.id == batchID else { return }
        if manualReviewSessionID != session { manualReviewSessionID = session }
        if session == nil, manualObservationError != nil { manualObservationError = nil }
    }
    /// 仅在 Toolkit 前台核对，避免文档查询打断 Photoshop 画笔；后台保留占用与重试状态。
    func observeManualEdits(sessionID: UUID) async {
        while !Task.isCancelled, let executor, let batch, manualReviewSessionID == sessionID {
            if isApplicationActive() && !isUpdatingReview && reviewObservation == nil {
                let poll = Task { [self] in
                    defer { reviewObservation = nil }
                    do {
                        try await executor.pollManualEdits(batchID: batch.id, canObserve: isApplicationActive)
                        guard !Task.isCancelled else { return }
                        if manualObservationError != nil { manualObservationError = nil }
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        let message = error.localizedDescription
                        if manualObservationError != message { manualObservationError = message }
                    }
                    await sync()
                    await syncReviewLease(executor, batchID: batch.id)
                    continueQueuedExports()
                }
                reviewObservation = poll
                await withTaskCancellationHandler { await poll.value } onCancel: { poll.cancel() }
            }
            try? await Task.sleep(for: .milliseconds(650))
        }
    }
    private func continueQueuedExports() {
        guard !hasManualEditing, !isUpdatingReview, hasQueuedExports, let executor, let batch, !batch.isPaused else { return }
        launch { [self] in
            try await executor.runPending(batchID: batch.id)
            await sync()
            if !hasQueuedExports { notice = "导出任务结束，逐张结果见导出记录" }
        }
    }

    func hasRequestedExportPreview(_ task: WorkflowSideTask) -> Bool {
        guard let version = task.finalPSDVersion else { return false }
        return exportPreviewVersions[task.id] == version
    }
    var canLoadCurrentExportPreview: Bool {
        guard stage == .png4k, currentSpecimen?.isExcluded == false, let task = currentTask,
              !hasManualEditing, !busy, !isUpdatingReview, !loading.contains(task.id),
              task[.geometry].state == .completed, let version = task.finalPSDVersion,
              task[.geometry].confirmedVersion == version else { return false }
        return !hasRequestedExportPreview(task) || displayImage(for: task) == nil || task.finalPreparationError != nil
    }
    func loadCurrentExportPreview() {
        guard canLoadCurrentExportPreview, let task = currentTask, let version = task.finalPSDVersion else { return }
        if task.pendingFinalPSD == nil && task.finalPreparationError == nil && task.roleImages != nil {
            exportPreviewVersions[task.id] = version
            requestPreview(task: task)
            return
        }
        preparingExportPreview = task.id
        updateReview { [self] executor, batchID in
            defer { preparingExportPreview = nil }
            try await executor.prepareFinalPSD(batchID: batchID, taskID: task.id)
            await sync()
            guard batch?.id == batchID, let prepared = batch?.task(id: task.id),
                  prepared.finalPSDVersion == version else { return }
            guard prepared.roleImages != nil else { throw WorkflowBridgeError.invalidImage("没有可用的输出预览") }
            exportPreviewVersions[task.id] = version
            if stage == .png4k { requestPreview(task: prepared) }
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
        guard let e = executor,let b = batch,let taskID = manualTaskID ?? currentTask?.id else { return }
        images[taskID] = nil; gates[taskID] = nil; solutions[taskID] = nil
        launch { [self] in
            if manualTaskID == taskID { try await e.refreshManualPSD(batchID: b.id,taskID: taskID) }
            else { try await e.refreshFinalPSD(batchID: b.id,taskID: taskID) }
            await clearPreviewState(); await sync(); stage = .hd
        }
    }
}
