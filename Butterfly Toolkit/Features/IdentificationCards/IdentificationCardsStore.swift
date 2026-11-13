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
    // 保留点选顺序。第一个选中的标本决定预览、表单和 Shift 连选起点。
    @Published private(set) var selectedIDs: [UUID] = []
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published var error: String?
    @Published private(set) var manualID: UUID?
    @Published private(set) var selectedImage: NSImage?
    @Published var overwrite: CardOverwriteRequest?
    let workspace: CardWorkspace
    private let bridge: any CardPhotoshopServing
    private var exportQueue: [UUID] = []
    private var skippedExports = 0
    private var recoveryFailed = false
    var selectedID: UUID? { selectedIDs.first }
    var selectedCards: [CardRecord] {
        let ids = Set(selectedIDs)
        return session.records.filter { ids.contains($0.id) }
    }
    var current: CardRecord? { session.records.first { $0.id == selectedID } }
    var locked: Bool { busy || manualID != nil || overwrite != nil || recoveryFailed }
    init(workspace:CardWorkspace = .standard,bridge:any CardPhotoshopServing = CardPhotoshopBridge()) {
        self.workspace = workspace; self.bridge = bridge
        do {
            session = try workspace.load()
            reconcileSelection()
        }
        catch { self.error = "无法恢复图鉴清单：\(error.localizedDescription)"; recoveryFailed = true }
    }
    // MARK: - 输入与表单
    func importFiles(_ urls: [URL]) {
        guard !locked else { return }
        run("正在识别正反面…") {
            let previous = self.session.records
            let byInputID = Dictionary(grouping: previous, by: \.input.id)
            let legacyByFile = Dictionary(grouping: previous.filter(\.input.wasRejectedByLegacyParser)) {
                $0.input.files.first?.standardizedFileURL.resolvingSymlinksInPath()
            }
            let inputs = urls + previous.flatMap { $0.input.files }
            let all = try await Task.detached { try CardInputParser.scan(inputs) }.value
            var updated = self.session
            updated.records = try all.map { group in
                let rejected = group.files.flatMap { legacyByFile[$0] ?? [] }
                let edited = rejected.filter { $0.fields != CardRecord(input: $0.input).fields }
                let existing = byInputID[group.id]?.first
                let editedFields = edited.map(\.fields) + [existing?.fields].compactMap { $0 }
                if !edited.isEmpty, let first = editedFields.first, editedFields.contains(where: { $0 != first }) {
                    throw CardError.message("\(group.sourceName) 的旧记录有不同的人工填写内容，请先核对后再合并正反面。")
                }
                guard var old = existing ?? edited.first ?? rejected.first(where: { $0.id == self.selectedID }) ?? rejected.first else {
                    return CardRecord(input: group)
                }
                guard old.input != group else { return old }
                if old.fields.chineseName.isEmpty || old.input.wasRejectedByLegacyParser && old.fields.chineseName == old.input.chineseName {
                    old.fields.chineseName = group.chineseName
                }
                if old.fields.latinName.isEmpty { old.fields.latinName = group.latinName }
                if old.fields.sex == old.input.sex { old.fields.sex = group.sex }
                old.fields.chineseName = old.fields.formattedChineseName
                old.input = group; old.revision += 1; old.issue = nil
                return old
            }
            try self.workspace.save(updated)
            self.session = updated
            self.reconcileSelection()
        }
    }
    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags = []) {
        guard !locked, let target = index(id) else { return }
        let extending = modifiers.contains(.command)
        if modifiers.contains(.shift), let anchor = index(selectedID) {
            let range = session.records[min(anchor, target)...max(anchor, target)].map(\.id)
            let startingIDs = extending ? selectedIDs : Array(selectedIDs.prefix(1))
            let existing = Set(startingIDs)
            setSelection(startingIDs + range.filter { !existing.contains($0) })
        } else if extending {
            setSelection(selectedIDs.contains(id) ? selectedIDs.filter { $0 != id } : selectedIDs + [id])
        } else {
            setSelection([id])
        }
    }

    func selectAll() {
        guard !locked else { return }
        let existing = Set(selectedIDs)
        setSelection(selectedIDs + session.records.map(\.id).filter { !existing.contains($0) })
    }

    private func setSelection(_ ids: [UUID]) {
        guard ids != selectedIDs else { return }
        let previous = selectedID
        selectedIDs = ids
        if previous != selectedID { loadImage() }
    }

    private func reconcileSelection() {
        let available = Set(session.records.map(\.id))
        let surviving = selectedIDs.filter { available.contains($0) }
        selectedIDs = surviving.isEmpty ? Array(session.records.prefix(1).map(\.id)) : surviving
        loadImage()
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
    func composeCollection() {
        guard let collection = current?.fields.collection else { return }
        for (label, value) in [("采集点", collection.locality), ("国家", collection.country), ("日期", collection.date),
                               ("海拔", collection.altitude), ("翅展", collection.wingspan ?? "")] {
            if let message = ToolkitTextInput.singleLineError(value) {
                error = "\(label)：\(message)"
                return
            }
        }
        edit { $0.collectionText = $0.collection.formatted }
    }

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
    func removeCards(_ ids: Set<UUID>) {
        guard !locked else { return }
        let candidates = session.records.filter { ids.contains($0.id) }
        guard !candidates.isEmpty else { return }
        run("正在移除卡片…") {
            var removable: [(card: CardRecord, workingHash: String?)] = []
            var failures: [String] = []
            for card in candidates {
                do {
                    let working = try self.workspace.workingForRemoval(card.id)
                    let workingHash: String?
                    if FileManager.default.fileExists(atPath: working.path) {
                        workingHash = try await Task.detached { try AIFileValidation.hash(working.path) }.value
                        try await self.bridge.close(working, owner: card.id, expectedHash: workingHash)
                    } else {
                        workingHash = nil
                    }
                    removable.append((card, workingHash))
                } catch {
                    failures.append("\(card.title)：\(error.localizedDescription)")
                }
            }
            if !removable.isEmpty {
                let removedIDs = Set(removable.map { $0.card.id })
                var updated = self.session
                updated.records.removeAll { removedIDs.contains($0.id) }
                // 先保存清单，保存失败时仍能恢复工作文件。
                try self.workspace.save(updated)
                self.session = updated
                self.reconcileSelection()
                let workspace = self.workspace
                for (card, workingHash) in removable {
                    do {
                        try await Task.detached {
                            try workspace.cleanRemovedCard(card.id, expectedHash: workingHash)
                        }.value
                    } catch {
                        failures.append("\(card.title)：\(error.localizedDescription)\n\(workspace.working(card.id).path)")
                    }
                }
            }
            if !failures.isEmpty {
                self.error = "部分卡片未能移除或清理。\n" + failures.joined(separator: "\n")
            }
        }
    }
    // MARK: - 预览与人工编辑
    func hasCurrentPreview(_ card: CardRecord) -> Bool {
        card.renderedRevision == card.revision && card.previewHash != nil
            && card.fields.chineseName == card.fields.formattedChineseName
            && FileManager.default.fileExists(atPath: workspace.preview(card.id).path)
    }

    func canExport(_ card: CardRecord) -> Bool {
        card.input.issue == nil && !card.collision && hasCurrentPreview(card)
    }

    func refresh(layout: Bool = false, all: Bool = false) {
        guard !locked else { return }
        if all {
            let pending = session.records.filter { $0.input.issue == nil && !hasCurrentPreview($0) }
            guard !pending.isEmpty else { return }
            run("正在生成图鉴预览…") {
                var failures: [String] = []
                for (offset, card) in pending.enumerated() {
                    let name = card.input.specimenNumber ?? card.title
                    self.activity = "正在预览 \(offset + 1)/\(pending.count) · \(name)"
                    do {
                        try await self.render(card.id)
                    } catch {
                        let reason = error.localizedDescription
                        if let i = self.index(card.id) { self.session.records[i].issue = reason }
                        failures.append("\(name) \(reason)")
                    }
                    if self.selectedID == card.id { self.loadImage() }
                }
                if !failures.isEmpty {
                    try self.persist()
                    self.error = "\(failures.count) 张卡片预览失败。\n" + failures.joined(separator: "\n")
                }
            }
            return
        }
        guard let id = selectedID else { return }
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
        var fields = record.fields
        fields.chineseName = ToolkitTextInput.replacingTabs(fields.chineseName)
        fields.latinName = ToolkitTextInput.replacingTabs(fields.latinName)
        fields.collectionText = ToolkitTextInput.replacingTabs(fields.collectionText)
        for (label, name) in [("中文名", fields.chineseName), ("拉丁名", fields.latinName)] {
            if let message = ToolkitTextInput.singleLineError(name) {
                throw CardError.message("\(label)：\(message)")
            }
        }
        if let message = ToolkitTextInput.multilineError(fields.collectionText) {
            throw CardError.message("最终采集文字：\(message)")
        }
        fields.chineseName = fields.formattedChineseName.trimmingCharacters(in: .whitespacesAndNewlines)
        fields.latinName = fields.latinName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardRenderRequest(working:workspace.working(record.id),template:workspace.template,front:front,back:back,fields:fields,roles:record.roles,layout:layout)
    }
    private func accept(_ result: CardRenderResult,id:UUID,revision:Int) throws {
        guard let i = index(id), session.records[i].revision == revision else { throw CardError.message("卡片已更新，旧预览未采用") }
        guard result.preview.standardizedFileURL == workspace.preview(id).standardizedFileURL else {
            throw CardError.message("预览文件归属不符")
        }
        guard try AIFileValidation.hash(result.preview.path) == result.previewHash,
              try AIFileValidation.hash(workspace.working(id).path) == result.workHash else {
            throw CardError.message("预览或工作 PSD 已变化，请重新预览。")
        }
        var updated = session
        updated.records[i].roles = result.roles
        updated.records[i].fields = result.fields
        updated.records[i].renderedRevision = revision
        updated.records[i].previewHash = result.previewHash
        updated.records[i].collision = result.collision
        updated.records[i].layoutPending = false
        updated.records[i].workHash = result.workHash
        updated.records[i].issue = result.collision ? "图片与文字过近或超出画布，请在 Photoshop 调整" : nil
        try workspace.save(updated)
        session = updated
    }
    // MARK: - 导出队列和逐项覆盖确认
    func export(all: Bool) {
        guard !locked else { return }
        let candidates = all ? session.records : selectedCards
        let ready = candidates.filter { canExport($0) }
        guard !ready.isEmpty else { error = "请先为要导出的卡片生成有效预览。"; return }
        skippedExports = candidates.count - ready.count
        exportQueue = ready.map(\.id)
        let names = ready.map { $0.outputName.lowercased() }
        guard Set(names).count == names.count else { exportQueue = []; error = "批次内有相同输出文件名，请先修改名称"; return }
        exportNext()
    }
    func answerOverwrite(_ allow: Bool) {
        guard let pending = overwrite else { return }; overwrite = nil
        if allow { exportOne(pending.cardID,to:pending.destination,stamp:pending.stamp) }
        else { exportNext() }
    }
    private func exportNext() {
        guard !exportQueue.isEmpty else {
            if skippedExports > 0 { error = "已跳过 \(skippedExports) 张没有有效预览的卡片。"; skippedExports = 0 }
            return
        }
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
            guard let i = self.index(id) else { return }
            let record = self.session.records[i]
            guard self.canExport(record), let previewHash = record.previewHash,
                  let front = record.input.front, let back = record.input.back else {
                throw CardError.message("预览已过期，请重新生成预览。")
            }
            let workspace = self.workspace
            try await Task.detached {
                guard Set(record.sources.keys) == Set([front.path, back.path, workspace.template.path]) else {
                    throw CardError.message("缺少预览来源校验，请重新生成预览。")
                }
                try workspace.verify(record.sources)
                let working = workspace.working(id)
                if record.workHash != nil || FileManager.default.fileExists(atPath: working.path) {
                    guard try AIFileValidation.hash(working.path) == record.workHash else {
                        throw CardError.message("工作 PSD 已变化，请采用人工调整或重新生成预览。")
                    }
                }
                try workspace.publish(workspace.preview(id),to:destination,expected:stamp,previewHash:previewHash)
            }.value
            self.session.records[i].exportedURL = destination
            self.session.records[i].exportedRevision = record.revision
            try self.persist()
            // Photoshop 运行时，用户可能从外部重新打开工作 PSD，无法只凭磁盘哈希确认可清理。
            if let hash = record.workHash,
               NSRunningApplication.runningApplications(withBundleIdentifier: "com.adobe.Photoshop").allSatisfy(\.isTerminated) {
                try workspace.cleanCompleted(id,expectedHash:hash)
                self.session.records[i].roles = nil
                self.session.records[i].workHash = nil
                try self.persist()
            }
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
