// 验证 Photoshop 原生抠图、旧清单拒绝和独立 PSD 目录。
import XCTest
import JavaScriptCore
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowPhotoshopMatteTests: XCTestCase {
    func testNativeBatchUsesSavedSubjectMaskForGeometry() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var native = f.batch
        var services = f.services
        services.selectSubject = { snapshot in
            await f.probe.record("select-subject")
            let result = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "photoshop-mask", roles: true)
            try JSONEncoder().encode(result).write(to: snapshot.workingURL)
            return result
        }
        services.analyze = { roles,_ in
            XCTAssertEqual(roles.snapshotVersion, "photoshop-mask")
            return ExecutorFixture.solution(roles.snapshotVersion)
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: native, manifestURL: f.manifest)
        try await executor.runPending(batchID: native.id)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "apply-save" }.count, 2)
        let result = try await executor.batch(batchID: native.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.snapshot?.roles?.isValid == true })
        let expectedDirectory = native.sourceDirectory.resolvingSymlinksInPath().appendingPathComponent(native.sourceDirectory.lastPathComponent + "_psd",isDirectory: true)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0.snapshot?.workingURL.deletingLastPathComponent().path == expectedDirectory.path })
        let loaded = try await WorkflowBatchStore().load(from: f.manifest)
        XCTAssertEqual(loaded.generatedPSDDirectory, expectedDirectory)
    }
    func testDraftPersistsNewSchemaAndSourcePSDSubdirectory() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let workspace = f.batch.outputDirectory.appendingPathComponent("new")
        let batch = try draft.freeze(names: "sample", output: workspace)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, WorkflowBatch.currentSchemaVersion)
        XCTAssertNil(object["manualFinalization"])
        XCTAssertEqual(batch.generatedPSDDirectory.path, batch.sourceDirectory.resolvingSymlinksInPath().appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd").path)
    }
    func testOldSchemaIsRejectedWithoutRewritingManifest() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var old = f.batch; old.schemaVersion = 1
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: f.manifest)
        let executor = WorkflowExecutor(services: f.services)
        do {
            _ = try await executor.register(manifestURL: f.manifest)
            XCTFail("Old workflow manifest accepted")
        } catch WorkflowStateError.invalidManifest(let reason) {
            XCTAssertTrue(reason.contains("旧流程"))
        }
        XCTAssertEqual(try Data(contentsOf: f.manifest), bytes)
    }
    func testPhotoshopFailureStopsTheFacesBeforeGeometry() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = f.services
        services.selectSubject = { _ in throw WorkflowBridgeError.invalidImage("没有识别到主体") }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.matte].state == .failed && $0[.geometry].state == .pending })
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("analyze"))
    }
    func testPublishedPhotoshopMaskRecoversAfterManifestWriteWasInterrupted() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        var services = f.services
        services.selectSubject = { snapshot in
            let current = try JSONDecoder().decode(PSDSnapshot.self, from: Data(contentsOf: snapshot.workingURL))
            XCTAssertEqual(snapshot.contentVersion, "stack", "Retry keeps the durable source version for bridge receipt matching")
            if current.contentVersion == "published-native" { return current }
            await f.probe.record("select-subject")
            guard current.contentVersion == snapshot.contentVersion else { throw WorkflowBridgeError.staleSource }
            let saved = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "published-native", roles: true)
            try JSONEncoder().encode(saved).write(to: snapshot.workingURL)
            throw WorkflowBridgeError.photoshop("interrupted after publishing")
        }
        let first = WorkflowExecutor(services: services)
        try await first.register(batch: batch, manifestURL: f.manifest)
        try await first.runPending(batchID: batch.id)
        let failed = try await first.batch(batchID: batch.id)
        XCTAssertTrue(failed.activeTasks.allSatisfy { $0[.matte].state == .failed && $0.snapshot?.roles == nil })
        let reopened = WorkflowExecutor(services: services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.retryTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), stage: .matte)
        let recovered = try await reopened.batch(batchID: batch.id)
        XCTAssertTrue(recovered.activeTasks.allSatisfy { $0[.matte].state == .completed && $0[.geometry].state == .waitingReview })
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 2, "Reuse both saved masks without rerunning subject selection")
    }
    func testPSDSubdirectoryRejectsSymlinkEscapeAndUnexpectedName() throws {
        let f = try ExecutorFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); try? FileManager.default.removeItem(at: outside) }
        var batch = f.batch
        // Keep internal records elsewhere so the source cannot pass as the workspace.
        batch.outputDirectory = batch.sourceDirectory.appendingPathComponent("records")
        let allowed = batch.generatedPSDDirectory.appendingPathComponent("sample0_D.psd")
        XCTAssertNoThrow(try batch.validateOutputURL(allowed))
        XCTAssertThrowsError(try batch.validateOutputURL(batch.generatedPSDDirectory.appendingPathComponent("foreign.psd")))
        XCTAssertThrowsError(try batch.validateOutputURL(batch.sourceDirectory.appendingPathComponent("sample0_D.psd")))
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: batch.generatedPSDDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(try batch.validateOutputURL(allowed))
    }
    func testRoleValidationAcceptsOnlyOptionalBottomPreviewBackground() throws {
        let context = try XCTUnwrap(JSContext())
        let script = PhotoshopWorkflowBridge.stackInputExportScript(output: URL(fileURLWithPath: "/tmp/unused.png"))
        let invocation = try XCTUnwrap(script.range(of: "\ntry{(function(){"))
        context.evaluateScript(String(script[..<invocation.lowerBound]))
        XCTAssertNil(context.exception)
        // Photoshop 图层属性由宿主提供；执行实际角色校验，只允许独立底层 BG。
        context.evaluateScript("""
        wfHasMask=function(l){return !!l.mask;};wfBounds=function(){return [0,0,100,100];};
        var LayerKind={SOLIDFILL:'solidFill',NORMAL:'normal'};
        var base={id:1,name:'Stack',typename:'ArtLayer',kind:LayerKind.NORMAL};
        var cutout={id:2,name:'Keying_Level',typename:'ArtLayer',kind:LayerKind.NORMAL,mask:true};
        var origin={id:6,name:'Keying_Origin',typename:'ArtLayer',kind:LayerKind.NORMAL,mask:true};
        var original={id:3,name:'原始堆栈',typename:'LayerSet'};
        var adjust={id:4,name:'共同调整',typename:'LayerSet',opacity:100,layers:[cutout,origin,base]};
        var bg={id:5,name:'BG',typename:'ArtLayer',kind:LayerKind.SOLIDFILL};
        var doc={layers:[adjust,original]};
        """)
        XCTAssertFalse(context.evaluateScript("wfIsPreviewBackground({name:'BG',typename:'ArtLayer',kind:LayerKind.NORMAL})")?.toBool() ?? true,
            "Imported PSD content may legitimately be a normal pixel layer named BG")
        XCTAssertEqual(context.evaluateScript("wfRoles(doc).ids.cutoutLayer")?.toString(), "2")
        context.evaluateScript("doc.layers=[adjust,original,bg];")
        XCTAssertEqual(context.evaluateScript("wfRoles(doc).ids.cutoutLayer")?.toString(), "2")
        XCTAssertNil(context.exception)
        for layers in ["[bg,adjust,original]", "[adjust,original,{name:'Unexpected',typename:'ArtLayer'}]", "[adjust,original,bg,bg]"] {
            context.exception = nil
            context.evaluateScript("doc.layers=\(layers);wfRoles(doc);")
            XCTAssertTrue(context.exception?.toString()?.contains("WORKFLOW_STRUCTURE") == true)
        }
        for layers in ["[cutout,base]", "[origin,cutout,base]", "[cutout,origin,base,cutout]"] {
            context.exception = nil
            context.evaluateScript("doc.layers=[adjust,original];adjust.layers=\(layers);wfRoles(doc);")
            XCTAssertTrue(context.exception?.toString()?.contains("WORKFLOW_STRUCTURE") == true)
        }
    }
    func testSelectSubjectUsesOnlyActiveLayerAndRejectsEmptySelection() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var events=[],doc={selection:{deselect:function(){events.push('deselect');},bounds:[1,1,9,9]}};
        function wfSelectRGB(){events.push('rgb');}
        function ActionDescriptor(){this.values={};this.putBoolean=function(k,v){this.values[k]=v;};}
        function stringIDToTypeID(v){return v;}var DialogModes={NO:0};
        function executeAction(name,descriptor,mode){events.push(name);if(descriptor.values.sampleAllLayers!==false)throw new Error('wrong sampling');}
        """)
        context.evaluateScript(PhotoshopWorkflowBridge.selectSubjectSelectionScript)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("events")?.toArray() as? [String], ["rgb","deselect","autoCutout"])
        context.evaluateScript("Object.defineProperty(doc.selection,'bounds',{get:function(){throw new Error('empty');}});")
        context.evaluateScript(PhotoshopWorkflowBridge.selectSubjectSelectionScript)
        XCTAssertTrue(context.exception?.toString()?.contains("未识别到主体") == true)
    }

}
