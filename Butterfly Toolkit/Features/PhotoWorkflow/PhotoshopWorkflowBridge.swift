import Foundation
import CoreGraphics

nonisolated enum PhotoshopInstallCheckpoint: Sendable { case prepared, published }

nonisolated struct PhotoshopWorkflowBridge: Sendable {
    typealias ScriptRunner = @Sendable (String) async throws -> String
    let workspace: URL
    private let coordinator: PhotoshopExecutionCoordinator
    private let scriptRunner: ScriptRunner
    private let installCheckpoint: @Sendable (PhotoshopInstallCheckpoint) async throws -> Void
    init(workspace: URL, coordinator: PhotoshopExecutionCoordinator = .shared, scriptRunner: @escaping ScriptRunner = { try await Self.execute($0) }, installCheckpoint: @escaping @Sendable (PhotoshopInstallCheckpoint) async throws -> Void = { _ in }) {
        self.workspace = workspace; self.coordinator = coordinator; self.scriptRunner = scriptRunner; self.installCheckpoint = installCheckpoint
    }
    private struct InstallTransaction: Codable, Sendable {
        var sourceVersion: String
        var result: PSDSnapshot
        var matte: MatteArtifact
    }
    private struct Ownership: Codable, Sendable {
        var owner: UUID
        var roles: PSDRoleIdentifiers?
        var sources: [WorkflowSourceFile]?
        var initialStackVersion: String?
        var pendingInstall: InstallTransaction?
    }
    private struct RoleCache: Codable {
        var snapshot: PSDSnapshot
        var images: RoleImages
        var fingerprints: [String]
    }
    private struct Metadata: Decodable, Sendable {
        var width: Double
        var height: Double
        var profile: String
        var roles: PSDRoleIdentifiers?
        var summary: String
        var originX: Double?
        var originY: Double?
        var extentWidth: Double?
        var extentHeight: Double?
        var wasOpen: Bool?
    }
    func stack(job: FocusStackJob, owner: UUID) async throws -> PSDSnapshot {
        try await coordinator.run(owner: owner) {
            guard !FileManager.default.fileExists(atPath: job.destinationURL.path),
                  !FileManager.default.fileExists(atPath: ownershipURL(job.destinationURL).path), job.sourceFiles.count == 3 else {
                throw WorkflowBridgeError.ownershipConflict
            }
            guard let photoshop = FocusStackProcessor.photoshopApplicationName() else { throw FocusStackError.photoshopNotFound }
            let folder = try outputDirectory("stack/\(UUID())", owner: owner)
            let hashes = try job.sourceFiles.map { try AIFileValidation.hash($0.path) }
            var copiedSources: [URL] = []
            for (index, source) in job.sourceFiles.enumerated() {
                let copy = folder.appendingPathComponent("sources/\(index)/\(source.lastPathComponent)")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: copy)
                guard try AIFileValidation.hash(copy.path) == hashes[index] else { throw WorkflowBridgeError.staleSource }
                copiedSources.append(copy)
            }
            let staged = folder.appendingPathComponent("stack.psd")
            let ownedJob = FocusStackJob(id: job.id, sourceFiles: copiedSources, destinationURL: staged, butterflyName: job.butterflyName, side: job.side)
            try await Task.detached(priority: .userInitiated) {
                try FocusStackProcessor.process(ownedJob, photoshopApplicationName: photoshop)
            }.value
            guard try job.sourceFiles.map({ try AIFileValidation.hash($0.path) }) == hashes else { throw WorkflowBridgeError.staleSource }
            // Move refuses a late same-name collision; the legacy processor's skip behavior cannot adopt an unknown PSD.
            let record = ownershipURL(job.destinationURL)
            try FileManager.default.createDirectory(at: job.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sources = zip(job.sourceFiles, hashes).map { WorkflowSourceFile(url: $0.0.resolvingSymlinksInPath(), fingerprint: $0.1) }
            let ownership = try Ownership(owner: owner, sources: sources, initialStackVersion: AIFileValidation.hash(staged.path))
            try JSONEncoder().encode(ownership).write(to: record, options: .withoutOverwriting)
            do { try FileManager.default.moveItem(at: staged, to: job.destinationURL) }
            catch { try? FileManager.default.removeItem(at: record); throw error }
            return try await capture(document: job.destinationURL, owner: owner)
        }
    }
    func refreshSavedPSD(document: URL, owner: UUID, expectedSources: [WorkflowSourceFile]? = nil) async throws -> PSDSnapshot {
        try await coordinator.readSaved(owner: owner) {
            if FileManager.default.fileExists(atPath: ownershipURL(document).path) {
                _ = try await recoverInstall(document: document, owner: owner, allowPublication: false)
            }
            if let expectedSources {
                let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(document)))
                let canonical = expectedSources.map { WorkflowSourceFile(url: $0.url.resolvingSymlinksInPath(), fingerprint: $0.fingerprint) }
                guard canonical.count == 3, ownership.owner == owner, ownership.sources == canonical, ownership.roles == nil,
                      try AIFileValidation.hash(document.path) == ownership.initialStackVersion else { throw WorkflowBridgeError.staleSource }
                for source in canonical {
                    guard try AIFileValidation.hash(source.url.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                }
            }
            let snapshot = try await capture(document: document, owner: owner)
            if snapshot.roles != nil { _ = try await extractUnlocked(snapshot) }
            return snapshot
        }
    }
    func exportStackPNG(snapshot: PSDSnapshot) async throws -> StackPNG {
        try await coordinator.run(owner: snapshot.taskID) {
            try await verify(snapshot)
            let output = try outputDirectory("data/processed", owner: snapshot.taskID).appendingPathComponent("\(snapshot.contentVersion)-\(UUID()).png")
            let metadata = try await invoke(Self.exportScript(document: snapshot.snapshotURL, output: output, roles: snapshot.roles))
            let raster = try WorkflowRaster.read(output)
            guard raster.size == snapshot.pixelSize, raster.orientation == 1, raster.hasProfile else {
                throw WorkflowBridgeError.invalidImage("堆栈 PNG 尺寸、方向或 ICC 缺失")
            }
            return try StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: output, fingerprint: AIFileValidation.hash(output.path),
                pixelSize: raster.size, orientation: raster.orientation, colorProfile: raster.profileName ?? metadata.profile, validBackgroundAlphaURL: output)
        }
    }
    func installMatte(snapshot: PSDSnapshot, matte: MatteArtifact) async throws -> PSDSnapshot {
        try await coordinator.run(owner: snapshot.taskID) {
            let record = ownershipURL(snapshot.workingURL)
            var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
            if let pending = ownership.pendingInstall {
                guard ownership.owner == snapshot.taskID, pending.sourceVersion == snapshot.contentVersion,
                      pending.matte == matte else { throw WorkflowBridgeError.staleSource }
                _ = try await recoverInstall(document: snapshot.workingURL, owner: snapshot.taskID, allowPublication: true)
                return try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
            }
            try await verify(snapshot)
            guard snapshot.roles == nil, matte.pixelSize == snapshot.pixelSize, matte.orientation == 1,
                  try AIFileValidation.hash(matte.alphaURL.path) == matte.alphaFingerprint,
                  try AIFileValidation.hash(matte.cutoutURL.path) == matte.cutoutFingerprint else { throw WorkflowBridgeError.staleSource }
            let inputDirectory = workspace.appendingPathComponent("data/processed/\(snapshot.taskID.uuidString)")
            let inputs = (try? FileManager.default.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil)) ?? []
            guard let inputURL = inputs.first(where: { $0.lastPathComponent.hasPrefix(snapshot.contentVersion) && (try? AIFileValidation.hash($0.path)) == matte.inputPNGFingerprint }) else {
                throw WorkflowBridgeError.staleSource
            }
            try WorkflowRaster.validateMatte(original: WorkflowRaster.read(inputURL), alpha: WorkflowRaster.read(matte.alphaURL), cutout: WorkflowRaster.read(matte.cutoutURL))
            // Prepare and validate off to the side; a failure here leaves the working PSD and its ownership unchanged.
            let staged = try outputDirectory("install/\(UUID())", owner: snapshot.taskID).appendingPathComponent("result.psd")
            try FileManager.default.copyItem(at: snapshot.snapshotURL, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
            try JSONEncoder().encode(ownership).write(to: ownershipURL(staged), options: .withoutOverwriting)
            let metadata = try await invoke(Self.installScript(document: staged, alpha: matte.alphaURL))
            guard let roles = metadata.roles, roles.isValid else { throw WorkflowBridgeError.invalidStructure }
            var stagedOwnership = ownership; stagedOwnership.roles = roles
            try JSONEncoder().encode(stagedOwnership).write(to: ownershipURL(staged), options: .atomic)
            let prepared = try await capture(document: staged, owner: snapshot.taskID)
            try await validateInstalledMask(prepared, matte: matte)
            try await verify(snapshot)
            ownership.pendingInstall = InstallTransaction(sourceVersion: snapshot.contentVersion, result: prepared, matte: matte)
            try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
            try await installCheckpoint(.prepared)
            _ = try await recoverInstall(document: snapshot.workingURL, owner: snapshot.taskID, allowPublication: true)
            return try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
        }
    }
    /// Only a persisted, fully validated result may bridge the PSD/ownership publication boundary.
    private func recoverInstall(document: URL, owner: UUID, allowPublication: Bool) async throws -> Bool {
        let record = ownershipURL(document)
        var ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: record))
        guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
        guard let pending = ownership.pendingInstall else { return false }
        guard ownership.roles == nil, pending.result.taskID == owner, pending.result.roles?.isValid == true,
              pending.result.pixelSize == pending.matte.pixelSize,
              try AIFileValidation.hash(pending.result.snapshotURL.path) == pending.result.contentVersion,
              (try AIFileValidation.hash(pending.matte.alphaURL.path)) == pending.matte.alphaFingerprint,
              (try AIFileValidation.hash(pending.matte.cutoutURL.path)) == pending.matte.cutoutFingerprint else { throw WorkflowBridgeError.staleSource }
        let current = try AIFileValidation.hash(document.path)
        if current == pending.sourceVersion {
            // Saved readback during manual editing must never publish an automatic PSD write.
            guard allowPublication else { return false }
            let closed = try await invoke(Self.closeForPublicationScript(document: document))
            guard closed.roles == nil, try AIFileValidation.hash(document.path) == pending.sourceVersion else { throw WorkflowBridgeError.staleSource }
            do {
                try Data(contentsOf: pending.result.snapshotURL, options: .mappedIfSafe).write(to: document, options: .atomic)
            } catch {
                if closed.wasOpen == true { _ = try? await invoke(Self.reopenScript(document: document)) }
                throw error
            }
            if closed.wasOpen == true { _ = try await invoke(Self.reopenScript(document: document)) }
            try await installCheckpoint(.published)
        } else if current != pending.result.contentVersion { throw WorkflowBridgeError.staleSource }
        let metadata = try await invoke(Self.inspectScript(document: document))
        guard metadata.roles == pending.result.roles, metadata.summary == pending.result.structureSummary,
              metadata.width == pending.result.pixelSize.width, metadata.height == pending.result.pixelSize.height,
              try AIFileValidation.hash(document.path) == pending.result.contentVersion else { throw WorkflowBridgeError.invalidStructure }
        var published = pending.result; published.workingURL = document
        try await validateInstalledMask(published, matte: pending.matte)
        guard try AIFileValidation.hash(document.path) == pending.result.contentVersion else { throw WorkflowBridgeError.staleSource }
        ownership.roles = pending.result.roles; ownership.pendingInstall = nil
        try JSONEncoder().encode(ownership).write(to: record, options: .atomic)
        return true
    }
    private func validateInstalledMask(_ snapshot: PSDSnapshot, matte: MatteArtifact) async throws {
        let extracted = try await extractUnlocked(snapshot)
        let actual = try WorkflowRaster.read(extracted.maskPNG), expected = try WorkflowRaster.read(matte.alphaURL)
        guard actual.size == expected.size else { throw WorkflowBridgeError.invalidImage("回写蒙版尺寸改变") }
        for i in stride(from: 0, to: actual.pixels.count, by: 4) where abs(Int(actual.pixels[i]) - Int(expected.pixels[i])) > 1 {
            throw WorkflowBridgeError.invalidImage("PSD 保存后的蒙版与 AI Alpha 不一致")
        }
    }
    func extractRoles(snapshot: PSDSnapshot) async throws -> RoleImages {
        try await coordinator.readSaved(owner: snapshot.taskID) {
            try await verify(snapshot)
            return try await extractUnlocked(snapshot)
        }
    }
    func applyGeometry(snapshot: PSDSnapshot, solution: GeometrySolution) async throws -> PSDSnapshot {
        try await coordinator.run(owner: snapshot.taskID) {
            try await verify(snapshot)
            guard solution.sourceVersion == snapshot.contentVersion, solution.isApplicable,
                  solution.angleDegrees.isFinite, solution.sourceCropRect.width > 0, solution.sourceCropRect.height > 0,
                  solution.sourceCropRect.size == solution.outputSize, snapshot.roles != nil else { throw WorkflowBridgeError.staleSource }
            _ = try await invoke(Self.geometryScript(document: snapshot.workingURL, solution: solution))
            let saved = try await capture(document: snapshot.workingURL, owner: snapshot.taskID)
            guard saved.pixelSize == solution.outputSize else { throw WorkflowBridgeError.invalidImage("裁切读回尺寸不一致") }
            _ = try await extractUnlocked(saved)
            return saved
        }
    }
    private func extractUnlocked(_ snapshot: PSDSnapshot) async throws -> RoleImages {
        guard snapshot.roles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
        // Callers have already checked the saved PSD. Reuse only the exact validated pixels.
        let receipt = workspace.appendingPathComponent("role-cache/\(snapshot.taskID)/\(snapshot.contentVersion).json")
        if let cache = try? JSONDecoder().decode(RoleCache.self, from: Data(contentsOf: receipt)),
           cache.snapshot == snapshot, cache.images.snapshotVersion == snapshot.contentVersion,
           (try? roleFingerprints(cache.images)) == cache.fingerprints {
            return cache.images
        }
        let folder = try outputDirectory("roles/\(snapshot.contentVersion)/\(UUID())", owner: snapshot.taskID)
        let metadata = try await invoke(Self.rolesScript(document: snapshot.snapshotURL, folder: folder))
        let base = folder.appendingPathComponent("base.png"), cutout = folder.appendingPathComponent("cutout.png"), mask = folder.appendingPathComponent("mask.png")
        let size = CGSize(width: metadata.extentWidth ?? 0, height: metadata.extentHeight ?? 0)
        guard size.width > 0, size.height > 0 else { throw WorkflowBridgeError.invalidStructure }
        let origin = CGPoint(x: metadata.originX ?? 0, y: metadata.originY ?? 0)
        let images = RoleImages(snapshotVersion: snapshot.contentVersion, basePNG: base, cutoutPNG: cutout, maskPNG: mask,
            pixelSize: size, coordinateOrigin: origin, editableExtent: CGRect(origin: origin, size: size),
            cropViewport: CGRect(origin: .zero, size: snapshot.pixelSize))
        let fingerprints = try roleFingerprints(images)
        let baseRaster = try WorkflowRaster.read(base), cutoutRaster = try WorkflowRaster.read(cutout), maskRaster = try WorkflowRaster.read(mask)
        guard [baseRaster, cutoutRaster, maskRaster].allSatisfy({ $0.size == size }) else { throw WorkflowBridgeError.invalidImage("角色提取范围不一致") }
        do { try WorkflowRaster.validateMatte(original: baseRaster, alpha: maskRaster, cutout: cutoutRaster, respectSourceAlpha: true) }
        catch { throw WorkflowBridgeError.invalidStructure }
        guard try roleFingerprints(images) == fingerprints else { throw WorkflowBridgeError.staleSource }
        // Cache publication is optional; a missing or damaged receipt simply triggers extraction.
        if let data = try? JSONEncoder().encode(RoleCache(snapshot: snapshot, images: images, fingerprints: fingerprints)) {
            try? FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: receipt, options: .atomic)
        }
        return images
    }
    private func roleFingerprints(_ images: RoleImages) throws -> [String] {
        try [images.basePNG, images.cutoutPNG, images.maskPNG].map { try AIFileValidation.hash($0.path) }
    }
    private func capture(document: URL, owner: UUID) async throws -> PSDSnapshot {
        let metadata = try await invoke(Self.inspectScript(document: document))
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(document)))
        guard ownership.owner == owner else { throw WorkflowBridgeError.ownershipConflict }
        guard ownership.roles == metadata.roles, metadata.roles == nil || metadata.roles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
        let before = try AIFileValidation.hash(document.path)
        let folder = try outputDirectory("snapshots", owner: owner)
        let temporary = folder.appendingPathComponent("\(UUID()).psd")
        let immutable = folder.appendingPathComponent("\(before).psd")
        let existing = FileManager.default.fileExists(atPath: immutable.path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !existing { try FileManager.default.copyItem(at: document, to: temporary) }
        guard try AIFileValidation.hash((existing ? immutable : temporary).path) == before,
              (try AIFileValidation.hash(document.path)) == before else { throw WorkflowBridgeError.staleSource }
        let second = try await invoke(Self.inspectScript(document: document))
        guard metadata.summary == second.summary, metadata.width == second.width, metadata.height == second.height,
              try AIFileValidation.hash(document.path) == before else { throw WorkflowBridgeError.staleSource }
        if !existing {
            try FileManager.default.moveItem(at: temporary, to: immutable)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: immutable.path)
        }
        return PSDSnapshot(taskID: owner, workingURL: document, snapshotURL: immutable, contentVersion: before,
            pixelSize: CGSize(width: metadata.width, height: metadata.height), roles: metadata.roles, structureSummary: metadata.summary)
    }
    private func verify(_ snapshot: PSDSnapshot) async throws {
        let saved = try await invoke(Self.inspectScript(document: snapshot.workingURL))
        guard saved.roles == snapshot.roles, saved.width == snapshot.pixelSize.width,
              saved.height == snapshot.pixelSize.height, saved.summary == snapshot.structureSummary else { throw WorkflowBridgeError.invalidStructure }
        let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: ownershipURL(snapshot.workingURL)))
        guard ownership.owner == snapshot.taskID, ownership.roles == snapshot.roles,
              try AIFileValidation.hash(snapshot.workingURL.path) == snapshot.contentVersion,
              (try AIFileValidation.hash(snapshot.snapshotURL.path)) == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
    }
    private func outputDirectory(_ component: String, owner: UUID) throws -> URL {
        let directory = workspace.appendingPathComponent(component).appendingPathComponent(owner.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    private func ownershipURL(_ document: URL) -> URL { document.appendingPathExtension("workflow-owner.json") }
    private func invoke(_ body: String) async throws -> Metadata {
        let result = try await scriptRunner(Self.commonScript + "\n(function(){" + body + "}());")
        guard let data = result.data(using: .utf8) else { throw WorkflowBridgeError.photoshop("无法读取脚本结果") }
        return try JSONDecoder().decode(Metadata.self, from: data)
    }
    static func execute(_ script: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let application = FocusStackProcessor.photoshopApplicationName() else { throw FocusStackError.photoshopNotFound }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID()).jsx")
            defer { try? FileManager.default.removeItem(at: url) }
            // ExtendScript otherwise guesses legacy encoding when Chinese text occurs late in a long script.
            try ("\u{FEFF}" + script).write(to: url, atomically: true, encoding: .utf8)
            let process = Process(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \(quote(application)) to do javascript file (POSIX file \(quote(url.path)))"]
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: diagnostic, as: UTF8.self)
                if message.contains("WORKFLOW_UNSAVED") { throw WorkflowBridgeError.unsavedDocument }
                if message.contains("WORKFLOW_STRUCTURE") { throw WorkflowBridgeError.invalidStructure }
                throw WorkflowBridgeError.photoshop(message)
            }
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
    private static func quote(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }
}

extension PhotoshopWorkflowBridge {
    private static let commonScript = #"""
    #target photoshop
    function wfJSON(v) {
        if (v === null || v === undefined) return "null";
        if (typeof v === "string") return '"' + v.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\r/g,'\\r').replace(/\n/g,'\\n') + '"';
        if (typeof v === "number" || typeof v === "boolean") return String(v);
        var parts = [], k;
        for (k in v) if (v.hasOwnProperty(k)) parts.push(wfJSON(k)+':'+wfJSON(v[k]));
        return '{'+parts.join(',')+'}';
    }
    function wfOpen(path) {
        var file = new File(path), existingIDs=[];
        for (var i=0;i<app.documents.length;i++) {
            var d=app.documents[i];existingIDs.push(d.id);
            try { if (d.fullName.fsName === file.fsName) {
                if (!d.saved) throw new Error('WORKFLOW_UNSAVED');
                app.activeDocument=d; return {doc:d,owned:false};
            }} catch(e) { if (String(e).indexOf('WORKFLOW_UNSAVED')>=0) throw e; }
        }
        var opened=app.open(file),owned=true;
        for(var j=0;j<existingIDs.length;j++)if(existingIDs[j]===opened.id)owned=false;
        if(!opened.saved)throw new Error('WORKFLOW_UNSAVED');
        return {doc:opened,owned:owned};
    }
    function wfClose(opened) { if(opened.owned) opened.doc.close(SaveOptions.DONOTSAVECHANGES); }
    function wfDescriptor(layer) {
        var r=new ActionReference(); r.putIdentifier(charIDToTypeID('Lyr '),layer.id); return executeActionGet(r);
    }
    function wfHasMask(layer) { var d=wfDescriptor(layer); return d.hasKey(stringIDToTypeID('hasUserMask')) && d.getBoolean(stringIDToTypeID('hasUserMask')); }
    function wfBounds(layer) {
        var d=wfDescriptor(layer),key=stringIDToTypeID('boundsNoMask');
        if (!d.hasKey(key)) key=stringIDToTypeID('bounds');
        var b=d.getObjectValue(key);return [b.getUnitDoubleValue(stringIDToTypeID('left')),b.getUnitDoubleValue(stringIDToTypeID('top')),b.getUnitDoubleValue(stringIDToTypeID('right')),b.getUnitDoubleValue(stringIDToTypeID('bottom'))];
    }
    function wfRoles(doc) {
        var original=null,adjust=null,base=null,cutout=null,count=0;
        for(var i=0;i<doc.layers.length;i++) {
            var l=doc.layers[i];
            if(l.name==='原始堆栈' && l.typename==='LayerSet') { original=l;count++; }
            if(l.name==='共同调整' && l.typename==='LayerSet') { adjust=l;count++; }
        }
        if(count===0) return null;
        if(count!==2 || !original || !adjust || doc.layers.length!==2 || adjust.layers.length!==2) throw new Error('WORKFLOW_STRUCTURE');
        for(var j=0;j<adjust.layers.length;j++) {
            var a=adjust.layers[j]; if(a.name==='底图' && a.typename==='ArtLayer') base=a;
            if(a.name==='抠图' && a.typename==='ArtLayer') cutout=a;
        }
        if(!base || !cutout || wfHasMask(base) || !wfHasMask(cutout)) throw new Error('WORKFLOW_STRUCTURE');
        var b=wfBounds(base),c=wfBounds(cutout);
        for(var k=0;k<4;k++) if(Math.abs(b[k]-c[k])>0.1) throw new Error('WORKFLOW_STRUCTURE');
        return {original:original,adjust:adjust,base:base,cutout:cutout,ids:{originalStackGroup:String(original.id),adjustmentGroup:String(adjust.id),baseLayer:String(base.id),cutoutLayer:String(cutout.id),mask:String(cutout.id)+':userMask'}};
    }
    function wfMetadata(doc) {
        var roles=wfRoles(doc),summary='';
        function visit(parent) { for(var i=0;i<parent.layers.length;i++) {
            var l=parent.layers[i];summary+=l.id+':'+l.name+':'+l.typename+':'+wfHasMask(l)+';';if(l.typename==='LayerSet')visit(l);
        }} visit(doc);
        return {width:doc.width.as('px'),height:doc.height.as('px'),profile:doc.colorProfileName,roles:roles?roles.ids:null,summary:summary};
    }
    function wfPNG(doc,path) { var p=new ExportOptionsSaveForWeb();p.format=SaveDocumentType.PNG;p.PNG8=false;p.transparency=true;p.interlaced=false;p.includeProfile=true;doc.exportDocument(new File(path),ExportType.SAVEFORWEB,p); }
    // Role PNGs need fast lossless encoding and ICC; PNGSaveOptions omits the profile.
    function wfRolePNG(doc,path) {
        if(doc.bitsPerChannel!==BitsPerChannelType.EIGHT || doc.mode!==DocumentMode.RGB){wfPNG(doc,path);return;}
        app.activeDocument=doc;var s=stringIDToTypeID,p=new ActionDescriptor(),d=new ActionDescriptor();
        p.putEnumerated(s('method'),s('PNGMethod'),s('quick'));p.putInteger(s('compression'),1);
        p.putEnumerated(s('PNGInterlaceType'),s('PNGInterlaceType'),s('PNGInterlaceNone'));
        p.putEnumerated(s('PNGFilter'),s('PNGFilter'),s('PNGFilterAdaptive'));
        p.putEnumerated(s('embedIccProfileLastState'),s('embedOff'),s('embedOn'));
        d.putObject(s('as'),s('PNGFormat'),p);d.putPath(s('in'),new File(path));
        d.putBoolean(s('copy'),true);d.putBoolean(s('lowerCase'),true);d.putBoolean(s('embedProfiles'),true);
        executeAction(s('save'),d,DialogModes.NO);
    }
    function wfSave(doc) { var p=new PhotoshopSaveOptions();p.layers=true;p.embedColorProfile=true;p.maximizeCompatibility=true;doc.saveAs(doc.fullName,p,false,Extension.LOWERCASE); }
    function wfSelectMask(layer) {
        app.activeDocument.activeLayer=layer;
        var d=new ActionDescriptor(),r=new ActionReference();r.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));d.putReference(charIDToTypeID('null'),r);d.putBoolean(charIDToTypeID('MkVs'),false);executeAction(charIDToTypeID('slct'),d,DialogModes.NO);
    }
    function wfSelectRGB() { var d=new ActionDescriptor(),r=new ActionReference();r.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('RGB '));d.putReference(charIDToTypeID('null'),r);executeAction(charIDToTypeID('slct'),d,DialogModes.NO); }
    function wfMaskToSelection(layer) {
        app.activeDocument.activeLayer=layer;var d=new ActionDescriptor(),to=new ActionReference(),from=new ActionReference();
        to.putProperty(charIDToTypeID('Chnl'),charIDToTypeID('fsel'));d.putReference(charIDToTypeID('null'),to);
        from.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));d.putReference(charIDToTypeID('T   '),from);executeAction(charIDToTypeID('setd'),d,DialogModes.NO);
    }
    function wfHideAll(doc) {for(var i=0;i<doc.layers.length;i++)doc.layers[i].visible=false;}
    """#
    private static func inspectScript(document: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path)));try{return wfJSON(wfMetadata(o.doc));}finally{wfClose(o);}
        """
    }
    private static func closeForPublicationScript(document: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),meta=wfMetadata(o.doc);
        meta.wasOpen=!o.owned;o.doc.close(SaveOptions.DONOTSAVECHANGES);return wfJSON(meta);
        """
    }
    private static func reopenScript(document: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path)));return wfJSON(wfMetadata(o.doc));
        """
    }
    private static func exportScript(document: URL, output: URL, roles: PSDRoleIdentifiers?) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null;
        try {copy=o.doc.duplicate();app.activeDocument=copy;var r=wfRoles(copy);
            if(r){wfHideAll(copy);r.adjust.visible=true;r.base.visible=true;r.cutout.visible=false;}
            else {for(var i=0;i<copy.layers.length;i++) if(copy.layers[i].name==='Background #74BFFF')copy.layers[i].visible=false;}
            wfPNG(copy,\(quote(output.path)));return wfJSON(wfMetadata(copy));
        }finally{if(copy)copy.close(SaveOptions.DONOTSAVECHANGES);wfClose(o);}
        """
    }
    private static func installScript(document: URL, alpha: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null,maskDoc=null,doc=o.doc;
        var dialogs=app.displayDialogs;app.displayDialogs=DialogModes.NO;
        try {
            if(wfRoles(doc))throw new Error('WORKFLOW_STRUCTURE');
            copy=doc.duplicate();app.activeDocument=copy;
            for(var i=0;i<copy.layers.length;i++)if(copy.layers[i].name==='Background #74BFFF')copy.layers[i].remove();
            copy.mergeVisibleLayers();var merged=copy.activeLayer;
            app.activeDocument=doc;var old=[];for(var j=0;j<doc.layers.length;j++)old.push(doc.layers[j]);
            var original=doc.layerSets.add();original.name='原始堆栈';
            for(var k=old.length-1;k>=0;k--)old[k].move(original,ElementPlacement.INSIDE);
            original.visible=false;
            var adjust=doc.layerSets.add();adjust.name='共同调整';
            app.activeDocument=copy;merged.duplicate(doc,ElementPlacement.PLACEATBEGINNING);
            app.activeDocument=doc;var base=doc.activeLayer;base.name='底图';base.move(adjust,ElementPlacement.INSIDE);
            var cutout=base.duplicate();cutout.name='抠图';base.visible=false;cutout.visible=true;doc.activeLayer=cutout;
            maskDoc=app.open(new File(\(quote(alpha.path))));var imported=maskDoc.channels[0].duplicate(doc);
            maskDoc.close(SaveOptions.DONOTSAVECHANGES);maskDoc=null;
            app.activeDocument=doc;doc.activeLayer=cutout;doc.selection.load(imported);
            var make=new ActionDescriptor(),ref=new ActionReference();make.putClass(charIDToTypeID('Nw  '),charIDToTypeID('Chnl'));
            ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));make.putReference(charIDToTypeID('At  '),ref);
            make.putEnumerated(charIDToTypeID('Usng'),charIDToTypeID('UsrM'),charIDToTypeID('RvlS'));executeAction(charIDToTypeID('Mk  '),make,DialogModes.NO);
            doc.selection.deselect();imported.remove();wfSelectRGB();
            wfSave(doc);return wfJSON(wfMetadata(doc));
        }finally{if(maskDoc)maskDoc.close(SaveOptions.DONOTSAVECHANGES);if(copy)copy.close(SaveOptions.DONOTSAVECHANGES);app.displayDialogs=dialogs;wfClose(o);}
        """
    }
    private static func rolesScript(document: URL, folder: URL) -> String {
        """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),copy=null,mask=null;
        try {
            var meta=wfMetadata(o.doc);if(!meta.roles)throw new Error('WORKFLOW_STRUCTURE');
            copy=o.doc.duplicate();app.activeDocument=copy;var r=wfRoles(copy),b=wfBounds(r.base);
            var left=Math.min(0,Math.floor(b[0])),top=Math.min(0,Math.floor(b[1]));
            var right=Math.max(meta.width,Math.ceil(b[2])),bottom=Math.max(meta.height,Math.ceil(b[3]));
            // Reveal hidden pixels only on a disposable duplicate, never crop the task PSD.
            copy.resizeCanvas(UnitValue(right-left,'px'),UnitValue(bottom-top,'px'),AnchorPosition.TOPLEFT);
            r.adjust.translate(UnitValue(-left,'px'),UnitValue(-top,'px'));
            wfHideAll(copy);r.adjust.visible=true;r.base.visible=true;r.cutout.visible=false;
            wfRolePNG(copy,\(quote(folder.appendingPathComponent("base.png").path)));
            r.base.visible=false;r.cutout.visible=true;wfRolePNG(copy,\(quote(folder.appendingPathComponent("cutout.png").path)));
            wfMaskToSelection(r.cutout);
            mask=app.documents.add(copy.width,copy.height,copy.resolution,'Workflow mask',NewDocumentMode.RGB,DocumentFill.WHITE);
            var black=new SolidColor();black.rgb.red=0;black.rgb.green=0;black.rgb.blue=0;mask.selection.selectAll();mask.selection.fill(black);mask.selection.deselect();
            app.activeDocument=copy;copy.selection.store(copy.channels.add());var channel=copy.channels[copy.channels.length-1];
            channel.duplicate(mask);app.activeDocument=mask;mask.selection.load(mask.channels[mask.channels.length-1]);
            var white=new SolidColor();white.rgb.red=255;white.rgb.green=255;white.rgb.blue=255;
            wfSelectRGB();mask.selection.fill(white,ColorBlendMode.NORMAL,100,false);mask.selection.deselect();
            wfRolePNG(mask,\(quote(folder.appendingPathComponent("mask.png").path)));
            meta.originX=left;meta.originY=top;meta.extentWidth=right-left;meta.extentHeight=bottom-top;return wfJSON(meta);
        }finally{if(mask)mask.close(SaveOptions.DONOTSAVECHANGES);if(copy)copy.close(SaveOptions.DONOTSAVECHANGES);wfClose(o);}
        """
    }
    private static func geometryScript(document: URL, solution: GeometrySolution) -> String {
        let rect = solution.sourceCropRect
        return """
        var o=wfOpen(\(quote(document.resolvingSymlinksInPath().path))),doc=o.doc;
        try {
            var roles=wfRoles(doc);if(!roles)throw new Error('WORKFLOW_STRUCTURE');
            var bounds=wfBounds(roles.base),cx=(bounds[0]+bounds[2])/2,cy=(bounds[1]+bounds[3])/2;
            var px=\(solution.rotationPivot.x),py=\(solution.rotationPivot.y),angle=\(solution.angleDegrees),radians=angle*Math.PI/180;
            if(angle!==0){
                roles.adjust.rotate(angle,AnchorPosition.MIDDLECENTER);
                var dx=px+(cx-px)*Math.cos(radians)-(cy-py)*Math.sin(radians)-cx;
                var dy=py+(cx-px)*Math.sin(radians)+(cy-py)*Math.cos(radians)-cy;
                roles.adjust.translate(UnitValue(dx,'px'),UnitValue(dy,'px'));
            }
            var d=new ActionDescriptor(),r=new ActionDescriptor();
            r.putUnitDouble(charIDToTypeID('Top '),charIDToTypeID('#Pxl'),\(rect.minY));r.putUnitDouble(charIDToTypeID('Left'),charIDToTypeID('#Pxl'),\(rect.minX));
            r.putUnitDouble(charIDToTypeID('Btom'),charIDToTypeID('#Pxl'),\(rect.maxY));r.putUnitDouble(charIDToTypeID('Rght'),charIDToTypeID('#Pxl'),\(rect.maxX));
            d.putObject(charIDToTypeID('T   '),charIDToTypeID('Rctn'),r);d.putUnitDouble(charIDToTypeID('Angl'),charIDToTypeID('#Ang'),0);
            d.putBoolean(charIDToTypeID('Dlt '),false);executeAction(charIDToTypeID('Crop'),d,DialogModes.NO);
            wfSave(doc);return wfJSON(wfMetadata(doc));
        }finally{wfClose(o);}
        """
    }
}
