// 验证已有 PSD 的配对、来源冻结、受保护接管和跳过景深合成后的流程。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPSDImportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psd-import-\(UUID())")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
    private func write(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
    func testCanonicalSidesAreDAndV() {
        XCTAssertEqual(WorkflowSide.front.fileSuffix,"D")
        XCTAssertEqual(WorkflowSide.back.fileSuffix,"V")
    }
    func testLegacyPhotoManifestKeepsItsSavedPSDPaths() throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.outputDirectory = batch.sourceDirectory.appendingPathComponent("new-batch")
        for side in WorkflowSide.allCases {
            var task = side == .front ? batch.specimens[0].front : batch.specimens[0].back
            let url = batch.sourceDirectory.appendingPathComponent("sample0_\(side.legacyFileSuffix).psd")
            task.stackAttemptURL = url; task.snapshot = ExecutorFixture.snapshot(task.id,url,"old",roles: false)
            if side == .front { batch.specimens[0].front = task } else { batch.specimens[0].back = task }
        }
        let restored = try JSONDecoder().decode(WorkflowBatch.self,from: JSONEncoder().encode(batch))
        try restored.validate()
        for task in restored.activeTasks {
            XCTAssertEqual(task.sources.files.count,3)
            try restored.validateOutputURL(XCTUnwrap(task.snapshot).workingURL)
        }
    }
    func testPSDPairsAreNamedAndFrozenWithoutJPGs() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["SC10_蝶_V.psd","SC2_蝶_d.PSD","SC10_蝶_D.psd","SC2_蝶_v.psd","DSC001.JPG"] { _ = try write(name,in: root) }
        let draft = try WorkflowBatchDraft.scan(directory: root,inputMode: .psd)
        XCTAssertEqual(draft.groups.map(\.suggestedName),["SC2_蝶","SC10_蝶"])
        XCTAssertEqual(draft.groups[0].files.compactMap { $0?.lastPathComponent },["SC2_蝶_d.PSD","SC2_蝶_v.psd"])
        let batch = try draft.freeze(names: "SC2_蝶\nSC10_蝶",output: root.appendingPathComponent("batch"),checkStack: true,checkMatte: true)
        XCTAssertFalse(batch.checkAfterStack)
        XCTAssertTrue(batch.activeTasks.allSatisfy { $0.sources.isPSD && $0.sources.files.count == 1 && $0.stackPNG == nil })
        let restored = try JSONDecoder().decode(WorkflowBatch.self,from: JSONEncoder().encode(batch))
        XCTAssertEqual(restored,batch)
        try restored.validate()
        for task in restored.activeTasks { try restored.validateOutputURL(task.sources.first.url) }
        XCTAssertThrowsError(try restored.validateOutputURL(root.appendingPathComponent("foreign.psd")))
    }
    func testUnpairedAndUnknownPSDRequireExplicitExclusionAndDuplicatesFail() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["pair_D.psd","pair_V.psd","single_D.psd","unknown.psd"] { _ = try write(name,in: root) }
        var draft = try WorkflowBatchDraft.scan(directory: root,inputMode: .psd)
        XCTAssertEqual(Set(draft.remainder.map(\.lastPathComponent)),["single_D.psd","unknown.psd"])
        XCTAssertThrowsError(try draft.freeze(names: "pair",output: root.appendingPathComponent("batch"),checkStack: false,checkMatte: true))
        draft.ignoreRemainder = true
        _ = try draft.freeze(names: "pair",output: root.appendingPathComponent("batch"),checkStack: false,checkMatte: true)
        // 大小写不敏感文件系统不能创建仅大小写不同的双份文件，用显式扫描列表覆盖重复项。
        let file = root.appendingPathComponent("pair_D.psd")
        XCTAssertThrowsError(try WorkflowBatchDraft.psdGroups(files: [file,file]))
    }
    func testModeSwitchReplacesPhotoGroupsAndNames() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...6 { _ = try write("DSC\(index).JPG",in: root) }
        for name in ["蝶_D.psd","蝶_V.psd"] { _ = try write(name,in: root) }
        let store = PhotoWorkflowStore(), oldStackCheck = store.checkAfterStack, oldMatteCheck = store.checkAfterMatte
        defer { store.checkAfterStack = oldStackCheck; store.checkAfterMatte = oldMatteCheck }
        store.scan(root); store.names = "旧照片名"
        XCTAssertEqual(store.draft?.groups.first?.files.count,6)
        store.inputMode = .psd
        XCTAssertEqual(store.draft?.groups.first?.files.count,2)
        XCTAssertEqual(store.names,"蝶")
        store.checkAfterStack = true; store.checkAfterMatte = false; store.checkGeometry = false; store.check4K = false
        XCTAssertFalse(store.needsExportDirectories)
        XCTAssertTrue(store.canStart)
    }
    func testAdoptPreservesOriginalAndSnapshotAndRejectsForeignOwnerOrChangedSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try write("manual_D.psd",in: root)
        let source = try WorkflowSourceFile(url: document,fingerprint: AIFileValidation.hash(document.path)), owner = UUID()
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("work"),scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"manual stack\"}"
        })
        let snapshot = try await bridge.adoptStack(source: source,owner: owner)
        XCTAssertEqual(snapshot.workingURL,document)
        XCTAssertEqual(snapshot.contentVersion,source.fingerprint)
        XCTAssertEqual(try AIFileValidation.hash(snapshot.snapshotURL.path),source.fingerprint)
        let resumed = try await bridge.adoptStack(source: source,owner: owner)
        XCTAssertEqual(resumed,snapshot)
        do { _ = try await bridge.adoptStack(source: source,owner: UUID()); XCTFail("Foreign owner accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.ownershipConflict) }
        try Data("manual edit".utf8).write(to: document)
        do { _ = try await bridge.adoptStack(source: source,owner: owner); XCTFail("Changed source accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.staleSource) }
        XCTAssertEqual(try AIFileValidation.hash(snapshot.snapshotURL.path),source.fingerprint)
    }
    func testDirtyPSDIsNotClaimedOrSaved() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try write("manual_D.psd",in: root)
        let source = try WorkflowSourceFile(url: document,fingerprint: AIFileValidation.hash(document.path))
        let bridge = PhotoshopWorkflowBridge(workspace: root,scriptRunner: { _ in throw WorkflowBridgeError.unsavedDocument })
        do { _ = try await bridge.adoptStack(source: source,owner: UUID()); XCTFail("Dirty document accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.unsavedDocument) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.appendingPathExtension("workflow-owner.json").path))
        XCTAssertEqual(try AIFileValidation.hash(document.path),source.fingerprint)
    }
    func testImportedPSDExportsInputAndContinuesWithoutStackingIncludingReopen() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        for side in WorkflowSide.allCases {
            var task = side == .front ? batch.specimens[0].front : batch.specimens[0].back
            let url = batch.sourceDirectory.appendingPathComponent("manual_\(side.fileSuffix).psd")
            let snapshot = ExecutorFixture.snapshot(task.id,url,"manual",roles: false)
            try JSONEncoder().encode(snapshot).write(to: url)
            task.sources = WorkflowSources(first: try WorkflowSourceFile(url: url,fingerprint: AIFileValidation.hash(url.path)))
            if side == .front { batch.specimens[0].front = task } else { batch.specimens[0].back = task }
        }
        var services = f.services
        services.adoptStack = { source,owner in
            await f.probe.record("import-psd")
            let snapshot = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: source.url))
            XCTAssertEqual(snapshot.taskID,owner)
            return snapshot
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch,manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.stack].state == .completed && $0[.matte].state == .completed && $0[.geometry].state == .waitingReview })
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("stack"))
        for operation in ["import-psd","export-stack","ai","install"] { XCTAssertEqual(calls.filter { $0 == operation }.count,2,operation) }
        let reopened = WorkflowExecutor(services: services)
        let restored = try await reopened.register(manifestURL: f.manifest)
        try await reopened.runPending(batchID: restored)
        let after = await f.probe.values()
        XCTAssertEqual(after.filter { $0 == "import-psd" }.count,2)
    }
    func testRealPSDImportThroughMatteAndGeometryWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["WORKFLOW_IMPORT_REAL_SOURCE"],let evidencePath = env["WORKFLOW_IMPORT_REAL_EVIDENCE"],let enginePath = env["WORKFLOW_IMPORT_REAL_ENGINE"] else {
            throw XCTSkip("Real PSD import is opt-in and uses an isolated copy")
        }
        let source = URL(fileURLWithPath: sourcePath), evidence = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        let sourceHash = try AIFileValidation.hash(source.path), owner = UUID()
        let document = evidence.appendingPathComponent("manual_V.psd")
        try FileManager.default.copyItem(at: source,to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],ofItemAtPath: document.path)
        if env["WORKFLOW_IMPORT_FLATTEN"] == "1" {
            let path = String(decoding: try JSONEncoder().encode(document.path),as: UTF8.self)
            _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
                try await PhotoshopWorkflowBridge.execute("""
                var d=app.open(new File(\(path)));try {d.flatten();var options=new PhotoshopSaveOptions();options.embedColorProfile=true;d.saveAs(new File(\(path)),options,true,Extension.LOWERCASE);}finally{d.close(SaveOptions.DONOTSAVECHANGES);}
                """)
            }
        }
        let originalHash = try AIFileValidation.hash(document.path)
        let workspace = evidence.appendingPathComponent(".work")
        let bridge = PhotoshopWorkflowBridge(workspace: workspace,scriptRunner: { script in
            do { return try await PhotoshopWorkflowBridge.execute(script) }
            catch { print("PSD import Photoshop error: \(error)"); throw error }
        })
        let snapshot = try await bridge.adoptStack(source: WorkflowSourceFile(url: document,fingerprint: originalHash),owner: owner)
        let input = try await bridge.exportStackPNG(snapshot: snapshot)
        let service = WorkflowMatteService(engine: URL(fileURLWithPath: enginePath),workspace: workspace)
        let matte: MatteArtifact
        do { matte = try await service.infer(input: input) } catch { await service.shutdown(); throw error }
        await service.shutdown()
        let installed = try await bridge.installMatte(snapshot: snapshot,matte: matte)
        let roles = try await bridge.extractRoles(snapshot: installed)
        let services = WorkflowExecutor.Services.live(bridge: bridge,matte: service)
        try await services.validateInstalledMatte(roles,input,matte)
        let geometry = try await services.analyze(roles,GeometryRequest())
        var final = installed
        if geometry.isApplicable {
            final = try await bridge.applyGeometry(snapshot: installed,solution: geometry)
            XCTAssertEqual(final.pixelSize,geometry.outputSize)
        } else {
            // 实图可能需要人工检查；无效自动构图不能被强行应用或当作导入失败。
            XCTAssertNotNil(geometry.reason)
            XCTAssertEqual(try AIFileValidation.hash(document.path),installed.contentVersion)
        }
        XCTAssertEqual(try AIFileValidation.hash(snapshot.snapshotURL.path),originalHash)
        XCTAssertEqual(try AIFileValidation.hash(source.path),sourceHash)
        let result: [String:Any] = ["originalUnchanged":true,"originalSnapshot":snapshot.snapshotURL.path,"workingPSD":document.path,"width":final.pixelSize.width,"height":final.pixelSize.height,"flattened":env["WORKFLOW_IMPORT_FLATTEN"] == "1","geometryApplicable":geometry.isApplicable,"geometryReason":geometry.reason ?? ""]
        try JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent("validation.json"))
    }
}
