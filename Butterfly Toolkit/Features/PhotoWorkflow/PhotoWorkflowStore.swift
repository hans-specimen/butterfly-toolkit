import SwiftUI
import Combine
import AppKit

nonisolated struct WorkflowDraftGroup: Identifiable, Sendable {
    var id = UUID()
    var files: [URL?] {
        didSet { for index in files.indices { if let url = files[index] { historicalFiles[index] = url } } }
    }
    private(set) var historicalFiles: [URL]
    var excluded = false
    init(files: [URL?]) {
        precondition(files.count == 6 && files.allSatisfy { $0 != nil })
        self.files = files; historicalFiles = files.map { $0! }
    }
    mutating func swapFaces() {
        let prior = historicalFiles
        files = Array(files[3..<6])+Array(files[0..<3])
        historicalFiles = Array(prior[3..<6])+Array(prior[0..<3])
    }
}

nonisolated struct WorkflowBatchDraft: Sendable {
    var directory: URL
    var groups: [WorkflowDraftGroup]
    var remainder: [URL]
    var otherFiles: [URL]
    var ignoreRemainder = false
    var photoCount: Int { groups.count*6+remainder.count }
    static func scan(directory: URL) throws -> Self {
        let files = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: [.isRegularFileKey],options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let photos = files.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let count = photos.count/6
        return Self(directory: directory,groups: (0..<count).map { WorkflowDraftGroup(files: photos[($0*6)..<($0*6+6)].map { Optional($0) }) },remainder: Array(photos.dropFirst(count*6)),otherFiles: files.filter { !["jpg","jpeg"].contains($0.pathExtension.lowercased()) })
    }
    func freeze(names: String,output: URL,checkStack: Bool,checkMatte: Bool) throws -> WorkflowBatch {
        let names = names.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !groups.isEmpty,names.count == groups.count,names.allSatisfy({ !$0.isEmpty }),Set(names.map { $0.lowercased() }).count == names.count else { throw WorkflowBridgeError.invalidImage("名称必须每组一行，不能空白或重名") }
        guard remainder.isEmpty || ignoreRemainder else { throw WorkflowBridgeError.invalidImage("请明确排除剩余未分组照片") }
        let activeURLs = groups.filter { !$0.excluded }.flatMap(\.files)
        guard activeURLs.allSatisfy({ $0 != nil }),Set(activeURLs.compactMap { $0?.resolvingSymlinksInPath() }).count == activeURLs.count else { throw WorkflowBridgeError.invalidImage("照片缺失或在多个固定位置重复，请补拍替换或排除整组") }
        guard groups.contains(where: { !$0.excluded }) else { throw WorkflowBridgeError.invalidImage("至少保留一只标本") }
        if FileManager.default.fileExists(atPath: output.path),!((try FileManager.default.contentsOfDirectory(atPath: output.path)).isEmpty) { throw WorkflowBridgeError.invalidImage("输出目录非空，请选择新的批次目录；已有批次请打开清单") }
        let specimens = try zip(groups,names).map { group,name -> WorkflowSpecimen in
            let files: [WorkflowSourceFile]
            if group.excluded {
                // Historical references only: excluded slots are never read or represented as content-verified.
                files = group.historicalFiles.map { WorkflowSourceFile(url: $0,fingerprint: "") }
            } else {
                guard group.files.allSatisfy({ $0 != nil }) else { throw WorkflowBridgeError.invalidImage("组 \(name) 的固定映射不完整") }
                files = try group.files.map { url in
                    let url = url!; return try WorkflowSourceFile(url: url.resolvingSymlinksInPath(),fingerprint: AIFileValidation.hash(url.path))
                }
            }
            func side(_ value: WorkflowSide,_ offset: Int) -> WorkflowSideTask {
                var task = WorkflowSideTask(side: value,sources: WorkflowSources(first: files[offset],second: files[offset+1],third: files[offset+2]))
                if group.excluded { for stage in WorkflowStage.allCases { task[stage].state = .excluded; task[stage].exclusionReason = "建批次时排除" } }; return task
            }
            return WorkflowSpecimen(id: group.id,baseName: name,front: side(.front,0),back: side(.back,3),exclusionReason: group.excluded ? "建批次时排除" : nil)
        }
        let batch = WorkflowBatch(sourceDirectory: directory,outputDirectory: output,checkAfterStack: checkStack,checkAfterMatte: checkMatte,specimens: specimens)
        try batch.validate(); return batch
    }
}

@MainActor final class PhotoWorkflowStore: ObservableObject {
    @Published var draft: WorkflowBatchDraft?
    @Published var names = ""
    @Published var outputDirectory: URL?
    @Published var enginePath = UserDefaults.standard.string(forKey: "aiEnginePath") ?? ""
    @Published var checkAfterStack = UserDefaults.standard.object(forKey: "workflowCheckStack") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAfterStack,forKey: "workflowCheckStack") }
    }
    @Published var checkAfterMatte = UserDefaults.standard.object(forKey: "workflowCheckMatte") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checkAfterMatte,forKey: "workflowCheckMatte") }
    }
    @Published var batch: WorkflowBatch?
    @Published var selectedSpecimens: Set<UUID> = []
    @Published var currentSpecimenID: UUID? { didSet { if currentSpecimenID != oldValue { retainCurrentDetailOnly() } } }
    @Published var face: WorkflowSide = .front { didSet { if face != oldValue { retainCurrentDetailOnly() } } }
    @Published var stage: WorkflowStage = .stack { didSet { if stage != oldValue { cancelMove(); prepareSelected() } } }
    @Published var error: String?
    @Published var busy = false
    @Published var exportHD = true
    @Published var selectedDerivatives: Set<WorkflowAssetKind> = [.white1k,.footage]
    @Published var watermarkURL: URL?
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
    private let previews = WorkflowPreviewService()
    private var previewTasks: [UUID: Task<Void,Never>] = [:]
    private var command: Task<Void,Never>?
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
        guard manualTaskID == nil,let task = currentTask else { return }
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
            // A new thumbnail request also fences any in-flight full-detail completion.
            if manualTaskID == nil,let task = batch?.task(id: id) { requestPreview(task: task) }
        }
    }
    func useQuickPreview() {
        guard manualTaskID == nil,let task = currentTask else { return }
        detailRequested.remove(task.id); requestPreview(task: task)
    }
    var canConfirm: Bool {
        guard !isDragging,!busy,manualTaskID == nil,let batch,!batch.isPaused,!selectedSpecimens.isEmpty else { return false }
        let selected = batch.specimens.filter { selectedSpecimens.contains($0.id) && !$0.isExcluded }
        guard selected.count == selectedSpecimens.count else { return false }
        return selected.flatMap { [$0.front,$0.back] }.allSatisfy { task in
            guard displayImage(for: task) != nil,task.roleImages?.snapshotVersion == task.snapshot?.contentVersion,gates[task.id]?.canConfirm == true,solutions[task.id]?.sourceVersion == task.snapshot?.contentVersion else { return false }
            if stage == .png4k { return task[.geometry].state == .completed && task[.hd].state == .completed && squareValid(task: task) }
            return task[.geometry].state == .waitingReview || task[.geometry].state == .completed
        }
    }
    func scan(_ directory: URL) {
        do { draft = try WorkflowBatchDraft.scan(directory: directory); error = nil } catch { self.error = error.localizedDescription }
    }
    func start() {
        guard let draft,let outputDirectory else { error = "请选择输入与输出文件夹"; return }
        let names = names,stack = checkAfterStack,matte = checkAfterMatte
        launch { [self] in
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: enginePath).appendingPathComponent("scripts/toolkit_bridge.py").path) else { throw WorkflowBridgeError.invalidImage("请选择 butterfly-matte 引擎目录；仅本批次使用，不会改变 AI 工作区设置") }
            let frozen = try await Task.detached { try draft.freeze(names: names,output: outputDirectory,checkStack: stack,checkMatte: matte) }.value
            let e = makeExecutor(output: outputDirectory)
            let manifest = outputDirectory.appendingPathComponent("batch.json")
            try await e.register(batch: frozen,manifestURL: manifest)
            executor = e; manifestURL = manifest
            try await e.configureDerivatives(batchID: frozen.id,kinds: Array(selectedDerivatives),watermarkURL: watermarkURL)
            batch = try await e.batch(batchID: frozen.id); currentSpecimenID = frozen.specimens.first { !$0.isExcluded }?.id; selectedSpecimens = Set(frozen.specimens.filter { !$0.isExcluded }.map(\.id))
            try await e.runPending(batchID: frozen.id)
        }
    }
    private var canSwitchBatch: Bool { !busy && manualTaskID == nil }
    func openBatch(_ url: URL) {
        guard canSwitchBatch else { error = "请先结束当前操作，并保存、刷新及明确继续人工 PSD 编辑"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            let e = makeExecutor(output: url.deletingLastPathComponent())
            let id = try await e.register(manifestURL: url)
            let value = try await e.batch(batchID: id)
            clearPreviewState(); executor = e; manifestURL = url; batch = value
            currentSpecimenID = value.specimens.first { !$0.isExcluded }?.id
            selectedSpecimens = Set(value.specimens.filter { !$0.isExcluded }.map(\.id))
            selectedDerivatives = Set(value.selectedDerivativeKinds ?? []); watermarkURL = value.watermarkURL
            stage = value.currentStage ?? .derivatives
        }
    }
    func closeBatch() {
        guard canSwitchBatch else { error = "请先结束当前操作，并保存、刷新及明确继续人工 PSD 编辑"; return }
        launch { [self] in
            try await persistBeforeSwitch()
            clearPreviewState(); executor = nil; manifestURL = nil; batch = nil
            currentSpecimenID = nil; selectedSpecimens = []; draft = nil; names = ""; outputDirectory = nil; stage = .stack
        }
    }
    func configureEngine(_ url: URL) {
        guard canSwitchBatch else { error = "人工 PSD 编辑保留队列期间不能切换引擎或批次"; return }
        launch { [self] in
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/toolkit_bridge.py").path) else { throw WorkflowBridgeError.invalidImage("请选择包含 scripts/toolkit_bridge.py 的引擎目录") }
            if let manifestURL,let batch {
                try await persistBeforeSwitch()
                let replacement = makeExecutor(output: batch.outputDirectory,engine: url)
                let id = try await replacement.register(manifestURL: manifestURL)
                let value = try await replacement.batch(batchID: id)
                executor = replacement; self.batch = value
            }
            enginePath = url.path
        }
    }
    private func persistBeforeSwitch() async throws {
        guard manualTaskID == nil else { throw WorkflowStateError.invalidTransition }
        guard let executor,let batch,let manifestURL else { return }
        await executor.pause(batchID: batch.id)
        let paused = try await executor.batch(batchID: batch.id)
        // pause is intentionally best-effort at executor level; switching requires a successful durable save.
        try await WorkflowBatchStore().save(paused,to: manifestURL)
        self.batch = paused
    }
    private func clearPreviewState() {
        for task in previewTasks.values { task.cancel() }
        previewTasks = [:]; images = [:]; imageIdentities = [:]; requestedImageIdentities = [:]
        gates = [:]; solutions = [:]; requests = [:]; layouts = [:]; loading = []; detailRequested = []; previewInteractionStarted = [:]; warmSources = []; cancelMove()
    }
    private func makeExecutor(output: URL,engine: URL? = nil) -> WorkflowExecutor {
        let workspace = output.appendingPathComponent(".work")
        return WorkflowExecutor(services: .live(bridge: PhotoshopWorkflowBridge(workspace: workspace),matte: WorkflowMatteService(engine: engine ?? URL(fileURLWithPath: enginePath),workspace: workspace.appendingPathComponent("AI"))))
    }
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
    private func sync() async {
        guard let executor,let id = batch?.id else { return }
        do {
            let value = try await executor.batch(batchID: id)
            let previous = batch; batch = value
            if let current = value.currentStage,previous?.currentStage != current { stage = current }
            for task in value.sideTasks where task.roleImages?.snapshotVersion != previous?.task(id: task.id)?.roleImages?.snapshotVersion {
                images[task.id] = nil; solutions[task.id] = nil; requests[task.id] = nil; gates[task.id] = nil
                if task.roleImages != nil { requestPreview(task: task) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func prepareSelected() {
        guard manualTaskID == nil,let batch else { return }
        for task in batch.specimens.filter({ selectedSpecimens.contains($0.id) || $0.id == currentSpecimenID }).flatMap({ [$0.front,$0.back] }) where task.roleImages != nil {
            if gates[task.id] == nil || requestedImageIdentities[task.id] != desiredImageIdentity(task) { requestPreview(task: task) }
        }
    }
    func refreshVisibleImage() {
        guard manualTaskID == nil,let task = currentTask else { return }; requestPreview(task: task)
    }
    func editRequest(_ edit: (inout GeometryRequest) -> Void) {
        guard let task = currentTask,manualTaskID == nil else { return }
        if let version = task.snapshot?.contentVersion,warmSources.contains(version),images[task.id] != nil { previewInteractionStarted[task.id] = ProcessInfo.processInfo.systemUptime }
        var request = currentRequest; edit(&request); requests[task.id] = request
        // Dragging uses the cached full source immediately; exact validation follows asynchronously.
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
        guard manualTaskID == nil,!busy,stage == .geometry || stage == .png4k else { return }
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
    private func requestPreview(task: WorkflowSideTask,request: GeometryRequest? = nil) {
        guard let roles = task.roleImages,let identity = desiredImageIdentity(task) else { return }
        previewTasks[task.id]?.cancel()
        requestedImageIdentities[task.id] = identity
        if imageIdentities[task.id] != identity { images[task.id] = nil; imageIdentities[task.id] = nil }
        var gate = gates[task.id] ?? WorkflowPreviewGate(); let token = gate.begin(sourceVersion: roles.snapshotVersion); gates[task.id] = gate; loading.insert(task.id)
        let request = request ?? requests[task.id] ?? task.geometryRequest
        let saved = task.geometrySolution
        let useSaved = requests[task.id] == nil && (task[.geometry].state == .completed || task.geometryRevalidationRequired)
        previewTasks[task.id] = Task { [self] in
            do {
                let image = try await previews.image(url: identity.url,version: roles.snapshotVersion,maximumPixelSize: identity.maximumPixelSize)
                guard !Task.isCancelled,gates[task.id]?.token == token,desiredImageIdentity(task) == identity else { return }
                imageIdentities[task.id] = identity; images[task.id] = image
                let solution = try await previews.geometry(source: roles,request: request,savedCandidate: useSaved ? saved : nil)
                guard !Task.isCancelled,gates[task.id]?.token == token else { return }
                _ = try await previews.preview(source: roles,solution: solution,maximumPixelSize: 2048)
                guard !Task.isCancelled,gates[task.id]?.accept(token: token,sourceVersion: roles.snapshotVersion,valid: solution.isApplicable) == true else { return }
                solutions[task.id] = solution; loading.remove(task.id); warmSources.insert(roles.snapshotVersion)
            } catch is CancellationError {} catch {
                guard gates[task.id]?.token == token else { return }; loading.remove(task.id); self.error = error.localizedDescription
            }
        }
    }
    func primary() {
        guard let e = executor,let b = batch else { return }
        let selected = b.specimens.filter { selectedSpecimens.contains($0.id) }.flatMap { [$0.front,$0.back] }
        launch { [self] in
            switch stage {
            case .stack,.matte: try await e.continueAfterReview(batchID: b.id,stage: stage,specimenIDs: b.specimens.filter { !$0.isExcluded }.map(\.id))
            case .geometry: try await e.confirmGeometry(batchID: b.id,solutions: Dictionary(uniqueKeysWithValues: selected.compactMap { task in solutions[task.id].map { (task.id,$0) } }),exportHD: exportHD)
            case .png4k:
                try await e.configureDerivatives(batchID: b.id,kinds: Array(selectedDerivatives),watermarkURL: watermarkURL)
                try await e.confirm4K(batchID: b.id,layouts: Dictionary(uniqueKeysWithValues: selected.map { ($0.id,layouts[$0.id] ?? $0.squareLayout) }))
            case .hd,.derivatives: try await e.retry(batchID: b.id,specimenIDs: Array(selectedSpecimens),stage: stage)
            }
        }
    }
    func retry() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.retry(batchID: b.id,specimenIDs: Array(selectedSpecimens),stage: stage) } }
    func excludeSelected() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.update(batchID: b.id,event: .excludeSpecimens(ids: selectedSpecimens,reason: "用户暂不处理",expectedRevision: b.revision)); try await e.runPending(batchID: b.id) } }
    func pause() { guard let e = executor,let b = batch else { return }; Task { await e.pause(batchID: b.id); await sync() } }
    func resume() { guard let e = executor,let b = batch else { return }; launch { [self] in try await e.continueAutomatic(batchID: b.id); manualTaskID = nil } }
    func openPSD() {
        guard let e = executor,let b = batch,let task = currentTask,!busy else { return }
        launch { [self] in let url = try await e.beginManualEditing(batchID: b.id,taskID: task.id); manualTaskID = task.id; NSWorkspace.shared.open(url) }
    }
    func refreshSaved() {
        guard let e = executor,let b = batch,let taskID = manualTaskID else { return }
        images[taskID] = nil; gates[taskID] = nil; solutions[taskID] = nil
        launch { [self] in try await e.refreshSavedPSD(batchID: b.id,taskID: taskID,change: manualChange); await sync(); if let task = batch?.task(id: taskID) { requestPreview(task: task) }; if manualChange != .maskOnly { stage = .geometry } }
    }
}
