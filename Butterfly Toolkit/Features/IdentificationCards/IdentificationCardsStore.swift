// 图鉴卡片状态：逐只编辑、预览、人工调整、覆盖确认及恢复；旧任务结果不能覆盖新修订。
import AppKit
import Combine

struct CardOverwriteRequest: Identifiable {
    var id = UUID()
    var cardID: UUID
    var destination: URL
    var stamp: CardTargetStamp
}

@MainActor final class IdentificationCardsStore: ObservableObject {
    @Published private(set) var session = CardSession()
    @Published var selectedID: UUID?
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published var error: String?
    @Published private(set) var manualID: UUID?
    @Published private(set) var selectedImage: NSImage?
    @Published var overwrite: CardOverwriteRequest?
    let workspace: CardWorkspace
    private let bridge: any CardPhotoshopServing
    private var exportQueue: [UUID] = []
    private var recoveryFailed = false
    var current: CardRecord? { session.records.first { $0.id == selectedID } }
    var locked: Bool { busy || manualID != nil || overwrite != nil || recoveryFailed }
    init(workspace:CardWorkspace = .standard,bridge:any CardPhotoshopServing = CardPhotoshopBridge()) {
        self.workspace = workspace; self.bridge = bridge
        do { session = try workspace.load(); selectedID = session.records.first?.id; loadImage() }
        catch { self.error = "无法恢复图鉴清单：\(error.localizedDescription)"; recoveryFailed = true }
    }
    // MARK: - 输入与表单
    func importFiles(_ urls: [URL]) {
        guard !locked else { return }
        run("正在识别正反面…") {
            let inputs = urls + self.session.records.flatMap { $0.input.files }
            let all = try await Task.detached { try CardInputParser.scan(inputs) }.value
            self.session.records = all.map { group in
                if var old = self.session.records.first(where:{ $0.input.id == group.id }) {
                    if old.input != group { old.input = group; old.revision += 1; old.issue = nil }
                    return old
                }
                return CardRecord(input:group)
            }
            if self.selectedID == nil { self.selectedID = self.session.records.first?.id }
            try self.persist(); self.loadImage()
        } completion: {
            if self.current?.input.issue == nil { self.refresh() }
        }
    }
    func select(_ id: UUID) {
        guard !locked else { return }
        selectedID = id; loadImage()
        if let card = current, card.input.issue == nil, card.renderedRevision != card.revision { refresh() }
    }
    func edit(_ update: (inout CardFields)->Void) {
        guard !locked, let index = index(selectedID) else { return }
        update(&session.records[index].fields); session.records[index].revision += 1
        session.records[index].issue = nil
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func organizeCollection() {
        guard let record = current else { return }
        do {
            let parsed = try CardCollectionInfo.parse(record.fields.rawCollection)
            edit { $0.collection = parsed; $0.collectionText = parsed.formatted }
        } catch { self.error = error.localizedDescription }
    }
    func composeCollection() { edit { $0.collectionText = $0.collection.formatted } }

    func applyCollectionBatch(_ rows: [CardCollectionInfo.Row], to reviewedIDs: [UUID]) throws {
        guard !locked, reviewedIDs == session.records.map(\.id) else {
            throw CardError.message("标本列表当前不可编辑或顺序已变，请重新核对。")
        }
        guard !rows.isEmpty, rows.count == reviewedIDs.count else {
            throw CardError.message("采集信息行数必须与标本数量一致。")
        }
        var updated = session
        for (index, row) in rows.enumerated() {
            var fields = updated.records[index].fields
            fields.rawCollection = row.source
            fields.collection = row.info
            fields.collectionText = row.info.formatted
            guard fields != updated.records[index].fields else { continue }
            updated.records[index].fields = fields
            updated.records[index].revision += 1
            updated.records[index].issue = nil
        }
        try workspace.save(updated)
        session = updated
    }

    func setOutput(_ url: URL) {
        guard !locked else { return }; session.outputDirectory = url
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func removeCurrent() {
        guard !locked, let id = selectedID else { return }
        run("正在移除卡片…") {
            try await self.bridge.close(self.workspace.working(id),owner:id)
            // 用户明确移除才丢弃对应工作文档，不清理其他记录。
            try self.workspace.cleanCompleted(id)
            self.session.records.removeAll { $0.id == id }; self.selectedID = self.session.records.first?.id
            try self.persist(); self.loadImage()
        }
    }
    // MARK: - 预览与人工编辑
    func refresh(layout: Bool = false) {
        guard !locked, let id = selectedID else { return }
        run("正在生成 Photoshop 预览…") { try await self.render(id,forceLayout:layout); self.loadImage() }
    }
    func openPhotoshop() {
        guard !locked, let id = selectedID else { return }
        run("正在打开 Photoshop…") {
            if let i=self.index(id) { self.session.records[i] = try self.workspace.recovering(self.session.records[i]) }
            if let card=self.current, card.roles != nil, FileManager.default.fileExists(atPath:self.workspace.working(id).path),
               try card.renderedRevision == card.revision || AIFileValidation.hash(self.workspace.working(id).path) != card.workHash {
                // 外部保存的修改先交回人工模式读取，不能用旧表单覆盖。
                try self.workspace.verify(card.sources)
            } else { try await self.render(id) }
            try await self.bridge.beginManual(self.workspace.working(id),owner:id)
            self.manualID = id
        }
    }
    func finishManual() {
        guard !busy, let id = manualID, let record = session.records.first(where:{ $0.id == id }) else { return }
        run("正在读取已保存的调整…") {
            try self.workspace.verify(record.sources)
            let request = try self.request(record,layout:false)
            let result = try await self.bridge.finishManual(request,owner:id)
            self.manualID = nil
            guard let i = self.index(id) else { return }
            self.session.records[i].revision += 1
            self.session.records[i].manualAdjusted = true
            try self.accept(result,id:id,revision:self.session.records[i].revision)
            self.loadImage()
        }
    }
    private func render(_ id: UUID, forceLayout: Bool = false) async throws {
        guard let i = index(id) else { return }
        var record = try workspace.recovering(session.records[i])
        session.records[i] = record
        if let issue = record.input.issue { throw CardError.message(issue) }
        let work = workspace.working(id)
        if record.roles != nil, !FileManager.default.fileExists(atPath:work.path), record.exportedURL != nil {
            record.roles = nil; record.workHash = nil; record.renderedRevision = nil
        }
        let request = try self.request(record,layout:forceLayout || record.roles == nil || record.layoutPending == true)
        let ws = workspace
        let hashes = try await Task.detached { try ws.fingerprints([request.front,request.back,request.template]) }.value
        if !record.sources.isEmpty, record.sources != hashes { throw CardError.message("素材或模板已改变，请移除该条后重新导入。临时 PSD 保留。") }
        if let hash = record.workHash, FileManager.default.fileExists(atPath:work.path), try AIFileValidation.hash(work.path) != hash {
            throw CardError.message("工作 PSD 有新的外部修改，请使用“在 Photoshop 中调整”后完成刷新")
        }
        session.records[i].sources = hashes
        // 首次置入后立即持久化来源；失败仍可识别所属素材。
        try persist()
        let result = try await bridge.render(request,owner:id)
        try await Task.detached { try ws.verify(hashes) }.value
        if forceLayout { session.records[i].manualAdjusted = false }
        try accept(result,id:id,revision:record.revision)
    }
    private func request(_ record: CardRecord,layout: Bool) throws -> CardRenderRequest {
        guard let front = record.input.front, let back = record.input.back else { throw CardError.message("请补齐正反面") }
        return CardRenderRequest(working:workspace.working(record.id),template:workspace.template,front:front,back:back,fields:record.fields,roles:record.roles,layout:layout)
    }
    private func accept(_ result: CardRenderResult,id:UUID,revision:Int) throws {
        guard let i = index(id), session.records[i].revision == revision else { throw CardError.message("卡片已更新，旧预览未采用") }
        session.records[i].roles = result.roles; session.records[i].fields = result.fields
        session.records[i].renderedRevision = revision; session.records[i].collision = result.collision
        session.records[i].layoutPending = false
        session.records[i].workHash = try AIFileValidation.hash(workspace.working(id).path)
        session.records[i].issue = result.collision ? "图片与文字过近或超出画布，请在 Photoshop 调整" : nil
        try persist()
    }
    // MARK: - 导出队列和逐项覆盖确认
    func export(all: Bool) {
        guard !locked else { return }
        exportQueue = all ? session.records.filter { $0.input.issue == nil }.map(\.id) : [selectedID].compactMap { $0 }
        let names = session.records.filter { exportQueue.contains($0.id) }.map { $0.outputName.lowercased() }
        guard Set(names).count == names.count else { exportQueue = []; error = "批次内有相同输出文件名，请先修改名称"; return }
        exportNext()
    }
    func answerOverwrite(_ allow: Bool) {
        guard let pending = overwrite else { return }; overwrite = nil
        if allow { exportOne(pending.cardID,to:pending.destination,stamp:pending.stamp) }
        else { exportNext() }
    }
    private func exportNext() {
        guard !exportQueue.isEmpty else { return }
        let id = exportQueue.removeFirst()
        guard let card = session.records.first(where:{ $0.id == id }) else { exportNext(); return }
        let destination = session.outputDirectory.appendingPathComponent(card.outputName)
        do {
            let stamp = try CardTargetStamp.read(destination)
            if stamp.hash != nil { overwrite = CardOverwriteRequest(cardID:id,destination:destination,stamp:stamp) }
            else { exportOne(id,to:destination,stamp:stamp) }
        } catch { self.error = error.localizedDescription; exportQueue = [] }
    }
    private func exportOne(_ id:UUID,to destination:URL,stamp:CardTargetStamp) {
        run("正在导出图鉴 PNG…") {
            try await self.render(id)
            guard let i = self.index(id), !self.session.records[i].collision else { throw CardError.message("图片与文字重合或超出画布，未导出") }
            let record = self.session.records[i]
            try self.workspace.verify(record.sources)
            guard record.renderedRevision == record.revision, try AIFileValidation.hash(self.workspace.working(id).path) == record.workHash else { throw CardError.message("预览已过期，请重新刷新") }
            try self.workspace.publish(self.workspace.preview(id),to:destination,expected:stamp)
            self.session.records[i].exportedURL = destination
            self.session.records[i].exportedRevision = record.revision
            try self.persist()
            try await self.bridge.close(self.workspace.working(id),owner:id,expectedHash:record.workHash)
            try self.workspace.cleanCompleted(id,expectedHash:record.workHash)
            self.session.records[i].roles = nil; self.session.records[i].workHash = nil
            try self.persist(); self.loadImage()
        } completion: { self.exportNext() }
    }
    // MARK: - 生命周期
    private func index(_ id:UUID?) -> Int? { session.records.firstIndex { $0.id == id } }
    private func persist() throws { try workspace.save(session) }
    private func loadImage() { selectedImage = selectedID.flatMap { NSImage(contentsOf:workspace.preview($0)) } }
    private func run(_ title:String,operation:@escaping @MainActor () async throws -> Void,completion:(@MainActor ()->Void)? = nil) {
        guard !busy else { return }; busy = true; activity = title; error = nil
        Task {
            do { try await operation(); busy = false; activity = ""; completion?() }
            catch { busy = false; activity = ""; self.error = error.localizedDescription; exportQueue = [] }
        }
    }
}
