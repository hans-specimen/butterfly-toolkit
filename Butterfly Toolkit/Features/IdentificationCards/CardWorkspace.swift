// 图鉴工作文件：最小清单、来源校验及经确认的原子发布，清理只限定本工具拥有的目录。
import Foundation
import ImageIO
import Darwin

nonisolated struct CardTargetStamp: Equatable, Sendable {
    var hash: String?
    var modified: Date?
    var fileID: UInt64?
    static func read(_ url: URL) throws -> Self {
        let fm = FileManager.default
        if let values = try? url.resourceValues(forKeys:[.isSymbolicLinkKey]), values.isSymbolicLink == true { throw CardError.message("目标是符号链接，不能覆盖") }
        guard fm.fileExists(atPath:url.path) else { return Self() }
        let values = try fm.attributesOfItem(atPath:url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else { throw CardError.message("输出目标不是普通文件") }
        return Self(hash:try AIFileValidation.hash(url.path),modified:values[.modificationDate] as? Date,fileID:(values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

nonisolated struct CardWorkspace: Sendable {
    let root: URL
    let template: URL
    init(root:URL,template:URL = URL(fileURLWithPath:"/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/_xx_图鉴模版.psd")) {
        self.root=root; self.template=template
    }
    static var standard: Self {
        Self(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Butterfly Toolkit/IdentificationCards"))
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func working(_ id: UUID) -> URL { directory(id).appendingPathComponent("card.psd") }
    func preview(_ id: UUID) -> URL { directory(id).appendingPathComponent("preview.png") }
    // MARK: - 恢复与来源
    func load() throws -> CardSession {
        let url = root.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return CardSession() }
        var session = try JSONDecoder().decode(CardSession.self,from:Data(contentsOf:url))
        guard session.schemaVersion == 1 else { throw CardError.message("图鉴清单版本不支持，已保留原文件") }
        for i in session.records.indices { session.records[i] = try recovering(session.records[i]) }
        return session
    }
    func recovering(_ original:CardRecord) throws -> CardRecord {
        var card=original
        if card.roles == nil,FileManager.default.fileExists(atPath:working(card.id).path),let checkpoint=try prepared(card.id) {
            card.roles=checkpoint.roles;card.workHash=checkpoint.workHash;card.layoutPending=checkpoint.layoutPending
        }
        return card
    }
    func prepared(_ id:UUID) throws -> CardPreparedState? {
        let path=directory(id).appendingPathComponent("prepared.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        return try JSONDecoder().decode(CardPreparedState.self,from:Data(contentsOf:path))
    }
    func save(_ session: CardSession) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(session).write(to:root.appendingPathComponent("session.json"),options:.atomic)
    }
    func fingerprints(_ urls: [URL]) throws -> [String:String] {
        var result: [String:String] = [:]
        for url in urls { result[url.path] = try AIFileValidation.hash(url.path) }
        return result
    }
    func verify(_ hashes: [String:String]) throws {
        for (path, hash) in hashes {
            guard try AIFileValidation.hash(path) == hash else { throw CardError.message("素材或模板发生变化，请移除该条并重新导入；现有工作 PSD 已保留") }
        }
    }
    // MARK: - 发布与清理
    func publish(_ candidate: URL, to target: URL, expected: CardTargetStamp, previewHash: String? = nil) throws {
        guard try CardTargetStamp.read(target) == expected else { throw CardError.message("同名文件在确认后发生变化，请重新确认覆盖") }
        guard let source = CGImageSourceCreateWithURL(candidate as CFURL,nil), CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width == 4000, image.height == 2250 else { throw CardError.message("导出 PNG 不完整或尺寸错误，原成品保持不变") }
        let fm = FileManager.default
        try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".card-\(UUID()).png")
        try fm.copyItem(at:candidate,to:temporary)
        defer { try? fm.removeItem(at:temporary) }
        if let previewHash, try AIFileValidation.hash(temporary.path) != previewHash {
            throw CardError.message("预览文件已变化，请重新生成预览。")
        }
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt:target,options:.forReplacing,error:&coordinationError) { coordinated in
            do {
                guard try CardTargetStamp.read(coordinated) == expected else { throw CardError.message("同名文件已改变，请重新确认覆盖") }
                let result = expected.hash == nil ? renamex_np(temporary.path,coordinated.path,UInt32(RENAME_EXCL)) : rename(temporary.path,coordinated.path)
                if result != 0 { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }; if let operationError { throw operationError }
    }
    func workingForRemoval(_ id: UUID) throws -> URL {
        let folder = try ownedDirectory(id)
        let working = folder.appendingPathComponent("card.psd")
        if let values = try? working.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
           values.isSymbolicLink == true || values.isRegularFile != true {
            throw CardError.message("工作 PSD 不是普通文件，已保留")
        }
        return working
    }

    private func ownedDirectory(_ id: UUID) throws -> URL {
        let folder = directory(id)
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(id.uuidString)
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == expected.standardizedFileURL.path else {
            throw CardError.message("工作目录归属不符，未清理")
        }
        return folder
    }

    func cleanRemovedCard(_ id: UUID, expectedHash: String?) throws {
        let working = try workingForRemoval(id)
        if expectedHash == nil, FileManager.default.fileExists(atPath: working.path) {
            throw CardError.message("移除后出现新的工作 PSD，已保留")
        }
        try cleanCompleted(id, expectedHash: expectedHash)
    }

    func cleanCompleted(_ id: UUID,expectedHash:String? = nil) throws {
        let folder = try ownedDirectory(id)
        // 预览保留用于列表回看；仅删除明确命名的本任务工作文件及渲染目录。
        if FileManager.default.fileExists(atPath:working(id).path) {
            if let expectedHash,try AIFileValidation.hash(working(id).path) != expectedHash { throw CardError.message("工作 PSD 已变化，已保留新的人工版本") }
            try FileManager.default.removeItem(at:working(id))
        }
        let prepared=folder.appendingPathComponent("prepared.json")
        if FileManager.default.fileExists(atPath:prepared.path) { try FileManager.default.removeItem(at:prepared) }
        if let contents = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
            for url in contents where url.lastPathComponent.hasPrefix("render-") { try FileManager.default.removeItem(at:url) }
        }
    }
}
