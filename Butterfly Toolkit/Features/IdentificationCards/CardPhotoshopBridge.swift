// 图鉴 Photoshop 桥接：所有操作经过共享协调器，快速导出完成后才交付预览文件。
import Foundation
import ImageIO
import CryptoKit

nonisolated struct CardRenderRequest: Sendable {
    var working: URL
    var template: URL
    var front: URL
    var back: URL
    var fields: CardFields
    var roles: [String:Int]?
    var layout: Bool
}
nonisolated struct CardRenderResult: Sendable {
    var roles: [String:Int]
    var fields: CardFields
    var preview: URL
    var width: Int
    var height: Int
    var collision: Bool
    var workHash: String
    var previewHash: String
}
nonisolated protocol CardPhotoshopServing: Sendable {
    func render(_ request: CardRenderRequest, owner: UUID) async throws -> CardRenderResult
    func beginManual(_ url: URL, owner: UUID) async throws
    func finishManual(_ request: CardRenderRequest, owner: UUID) async throws -> CardRenderResult
    func close(_ url: URL, owner: UUID, expectedHash:String?) async throws
}
extension CardPhotoshopServing {
    func close(_ url:URL,owner:UUID) async throws { try await close(url,owner:owner,expectedHash:nil) }
}

nonisolated final class CardPhotoshopBridge: CardPhotoshopServing, @unchecked Sendable {
    private let coordinator = PhotoshopExecutionCoordinator.shared
    // MARK: - 串行操作和人工占用
    func render(_ request: CardRenderRequest, owner: UUID) async throws -> CardRenderResult {
        try await coordinator.run(owner: owner) { try await self.renderUnlocked(request, inspectOnly:false) }
    }
    func beginManual(_ url: URL, owner: UUID) async throws {
        try await coordinator.beginManualEditing(owner:owner)
        do { _ = try await coordinator.readSaved(owner:owner) { try await self.invoke(["operation":"activate", "working":url.resolvingSymlinksInPath().path]) } }
        catch { await coordinator.endManualEditing(owner:owner); throw error }
    }
    func finishManual(_ request: CardRenderRequest, owner: UUID) async throws -> CardRenderResult {
        let result = try await coordinator.readSaved(owner:owner) { try await self.renderUnlocked(request,inspectOnly:true) }
        await coordinator.endManualEditing(owner:owner)
        return result
    }
    func close(_ url: URL, owner: UUID,expectedHash:String?) async throws {
        try await coordinator.run(owner:owner) {
            if let expectedHash,try AIFileValidation.hash(url.path) != expectedHash { throw CardError.message("PSD 在导出后又有修改，已保留新的人工版本") }
            try await self.closeWorking(url)
        }
    }
    // MARK: - 真实模板与渲染
    private struct Metadata: Decodable {
        var roles: [String:Int] = [:]
        var chineseName: String = ""
        var latinName: String = ""
        var collectionText: String = ""
        var sex: CardSex = .unknown
        var width: Int = 0
        var height: Int = 0
        var collision: Bool = false
        var frontSize: [Double] = []
        var backSize: [Double] = []
        var documentID: Int?
        var nativePath: String?
        var owned: Bool?
    }
    private func invoke(_ payload: [String:Any]) async throws -> Metadata {
        let data = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
        let script = CardPhotoshopScript.source + "\ncardRun(" + String(decoding:data,as:UTF8.self) + ");"
        let output = try await PhotoshopWorkflowBridge.execute(script)
        do { return try JSONDecoder().decode(Metadata.self,from:Data(output.utf8)) }
        catch {
            let operation = payload["operation"] as? String ?? "预览"
            throw CardError.message("Photoshop 未返回有效的图鉴结果（\(operation)）。\(error.localizedDescription)")
        }
    }
    private func closeWorking(_ url: URL, documentID: Int? = nil, nativePath: String? = nil) async throws {
        var payload: [String:Any] = ["operation":"close", "working":url.resolvingSymlinksInPath().path]
        if let documentID { payload["documentID"] = documentID }
        if let nativePath { payload["nativePath"] = nativePath }
        _ = try await invoke(payload)
    }
    private func renderUnlocked(_ original: CardRenderRequest, inspectOnly: Bool) async throws -> CardRenderResult {
        var request=original
        let fm = FileManager.default
        let folder = request.working.deletingLastPathComponent()
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let newDocument = !fm.fileExists(atPath:request.working.path)
        let checkpointURL=folder.appendingPathComponent("prepared.json")
        if !newDocument,request.roles == nil {
            if fm.fileExists(atPath:checkpointURL.path) {
                let saved=try JSONDecoder().decode(CardPreparedState.self,from:Data(contentsOf:checkpointURL))
                guard try AIFileValidation.hash(request.working.path) == saved.workHash else { throw CardError.message("工作 PSD 已有人工修改，请进入 Photoshop 调整后刷新") }
                request.roles=saved.roles;request.layout=saved.layoutPending
            } else {
                guard try AIFileValidation.hash(request.working.path) == AIFileValidation.hash(request.template.path) else { throw CardError.message("已有工作 PSD 缺少角色记录，已保留文件；不能重新初始化覆盖") }
            }
        }
        if newDocument {
            guard !inspectOnly, request.roles == nil else { throw CardError.message("工作 PSD 已丢失，不能丢弃人工状态后自动重建") }
            try fm.copyItem(at:request.template,to:request.working)
        }
        let opened = try await invoke(["operation":"acquire", "working":request.working.resolvingSymlinksInPath().path])
        guard let documentID = opened.documentID, let nativePath = opened.nativePath, let owned = opened.owned else {
            throw CardError.message("无法确认 Photoshop 工作 PSD 的归属")
        }
        let result: CardRenderResult
        do {
            result = try await renderOpened(request, inspectOnly:inspectOnly, documentID:documentID, nativePath:nativePath)
        } catch {
            // 只关闭本次打开且仍为已保存状态的同一个文档。失败时保留脏文档。
            if owned { try? await closeWorking(request.working, documentID:documentID, nativePath:nativePath) }
            throw error
        }
        if owned { try await closeWorking(request.working, documentID:documentID, nativePath:nativePath) }
        return result
    }

    private func renderOpened(_ request: CardRenderRequest, inspectOnly: Bool, documentID: Int, nativePath: String) async throws -> CardRenderResult {
        let fm = FileManager.default
        let folder = request.working.deletingLastPathComponent()
        let checkpointURL = folder.appendingPathComponent("prepared.json")
        let working = request.working.resolvingSymlinksInPath().path
        let stage = folder.appendingPathComponent("render-\(UUID())")
        try fm.createDirectory(at:stage,withIntermediateDirectories:true)
        // 独立副本可直接关闭；不会打开或关闭用户正在查看的原 PNG。
        let document: [String:Any] = ["working":working, "documentID":documentID, "nativePath":nativePath]
        var payload = document
        payload["operation"] = inspectOnly ? "inspect" : "prepare"
        if let roles = request.roles { payload["roles"] = roles }
        if !inspectOnly {
            payload["fields"] = ["chineseName":request.fields.chineseName,"latinName":request.fields.latinName,"sex":request.fields.sex.rawValue,"collectionText":request.fields.collectionText]
            if request.roles == nil {
                for (key, source) in [("front", request.front),("back",request.back)] {
                    let copy = stage.appendingPathComponent(key + ".png"); try fm.copyItem(at:source,to:copy)
                    payload[key] = copy.resolvingSymlinksInPath().path
                }
            }
        }
        var metadata = try await invoke(payload)
        func checkpoint(_ metadata:Metadata,pending:Bool) throws {
            let state=CardPreparedState(roles:metadata.roles,workHash:try AIFileValidation.hash(request.working.path),layoutPending:pending)
            try JSONEncoder().encode(state).write(to:checkpointURL,options:.atomic)
        }
        try checkpoint(metadata,pending:request.layout && !inspectOnly)
        if request.layout && !inspectOnly {
            guard metadata.frontSize.count == 2, metadata.backSize.count == 2 else { throw CardError.message("无法读取蝴蝶可见轮廓") }
            let frames = CardLayout.frames(front:CGSize(width:metadata.frontSize[0],height:metadata.frontSize[1]),back:CGSize(width:metadata.backSize[0],height:metadata.backSize[1]))
            payload = document
            payload["operation"] = "layout"
            payload["roles"] = metadata.roles
            payload["frames"] = frames.map { [$0.minX,$0.minY,$0.width,$0.height] }
            metadata = try await invoke(payload)
            try checkpoint(metadata,pending:false)
        }
        let before = try AIFileValidation.hash(request.working.path)
        payload = document
        payload["operation"] = "export"
        payload["roles"] = metadata.roles
        payload["destination"] = stage.resolvingSymlinksInPath().path
        _ = try await invoke(payload)
        let candidate = stage.appendingPathComponent(request.working.deletingPathExtension().lastPathComponent + ".png")
        var ready = false
        var lastSize: Int64 = -1
        for _ in 0..<600 {
            try Task.checkCancellation()
            if let attributes = try? fm.attributesOfItem(atPath:candidate.path), let size = attributes[.size] as? NSNumber, size.int64Value > 0 {
                if size.int64Value == lastSize, let source = CGImageSourceCreateWithURL(candidate as CFURL,nil), CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceCreateImageAtIndex(source,0,nil) != nil { ready = true; break }
                lastSize = size.int64Value
            }
            try await Task.sleep(for:.milliseconds(250))
        }
        guard ready else { throw CardError.message("Photoshop 快速导出未完成，请检查 Photoshop 后重试；临时 PSD 已保留") }
        payload = document
        payload["operation"] = "check"
        _ = try await invoke(payload)
        guard try AIFileValidation.hash(request.working.path) == before else { throw CardError.message("导出期间工作文档发生变化，请刷新后重试") }
        let preview = folder.appendingPathComponent("preview.png")
        let png = try Data(contentsOf:candidate)
        let previewHash = SHA256.hash(data: png).map { String(format:"%02x", $0) }.joined()
        try png.write(to:preview,options:.atomic)
        try fm.removeItem(at:stage)
        var fields = request.fields
        fields.chineseName = metadata.chineseName; fields.latinName = metadata.latinName
        fields.sex = metadata.sex; fields.collectionText = metadata.collectionText
        return CardRenderResult(roles:metadata.roles,fields:fields,preview:preview,width:metadata.width,height:metadata.height,
                                collision:metadata.collision,workHash:before,previewHash:previewHash)
    }
}
