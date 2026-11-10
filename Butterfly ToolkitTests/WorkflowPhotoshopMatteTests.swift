// 验证 Photoshop 抠图分流、历史批次兼容及新 PSD 目录。
import XCTest
import JavaScriptCore
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowPhotoshopMatteTests: XCTestCase {
    func testPhotoshopBatchDoesNotInvokeEngine() async throws {
        for scheduling in [WorkflowMatteScheduling.interleaved, .phased] {
            let f = try ExecutorFixture(checks: false)
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.batch)) as? [String: Any])
            object["matteProvider"] = "photoshop"
            let batch = try JSONDecoder().decode(WorkflowBatch.self, from: JSONSerialization.data(withJSONObject: object))
            var services = f.services
            services.selectSubject = { snapshot in
                await f.probe.record("select-subject")
                let result = ExecutorFixture.snapshot(snapshot.taskID, snapshot.workingURL, "photoshop-mask", roles: true)
                try JSONEncoder().encode(result).write(to: snapshot.workingURL)
                return result
            }
            services.stackWithInput = { _,_ in XCTFail("PS must not pre-export AI input"); throw WorkflowStateError.invalidTransition }
            services.applyForFinalization = { _,_ in XCTFail("PS must keep editable mask visible"); throw WorkflowStateError.invalidTransition }
            services.analyze = { roles,_ in
                XCTAssertEqual(roles.snapshotVersion, "photoshop-mask")
                return ExecutorFixture.solution(roles.snapshotVersion)
            }
            var native = batch; native.manualFinalization = true; native.psdSubdirectory = true
            let executor = WorkflowExecutor(services: services, matteScheduling: scheduling)
            try await executor.register(batch: native, manifestURL: f.manifest)
            try await executor.runPending(batchID: batch.id)
            let calls = await f.probe.values()
            XCTAssertFalse(calls.contains("ai"))
            XCTAssertFalse(calls.contains("export-stack"))
            XCTAssertFalse(calls.contains("install"))
            XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 2)
            XCTAssertEqual(calls.filter { $0 == "apply-save" }.count, 2)
            let result = try await executor.batch(batchID: batch.id)
            XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
            XCTAssertTrue(result.activeTasks.allSatisfy { $0.matteArtifact == nil && $0.stackPNG == nil })
            let expectedDirectory = native.sourceDirectory.appendingPathComponent(native.sourceDirectory.lastPathComponent + "_psd")
            XCTAssertTrue(result.activeTasks.allSatisfy { $0.snapshot?.workingURL.deletingLastPathComponent() == expectedDirectory })
            let loaded = try await WorkflowBatchStore().load(from: f.manifest)
            XCTAssertEqual(loaded.effectiveMatteProvider, .photoshop)
            XCTAssertEqual(loaded.generatedPSDDirectory, expectedDirectory)
        }
    }
    func testNewDraftPersistsPhotoshopAndPSDSubdirectoryDefaults() throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "sample", output: f.batch.outputDirectory.appendingPathComponent("new"), checkStack: false, checkMatte: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        XCTAssertEqual(object["matteProvider"] as? String, "photoshop")
        XCTAssertEqual(object["psdSubdirectory"] as? Bool, true)
    }
    func testLegacyBatchKeepsEngineAndOriginalPSDDirectory() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let legacy = try JSONDecoder().decode(WorkflowBatch.self, from: JSONEncoder().encode(f.batch))
        XCTAssertEqual(legacy.effectiveMatteProvider, .aiEngine)
        XCTAssertEqual(legacy.generatedPSDDirectory, legacy.sourceDirectory)
        let executor = WorkflowExecutor(services: f.services)
        try await executor.register(batch: legacy, manifestURL: f.manifest)
        try await executor.runPending(batchID: legacy.id)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "ai" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "install" }.count, 2)
    }
    func testPhotoshopFailureDoesNotFallBackToEngineOrAdvance() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.matteProvider = .photoshop
        var services = f.services
        services.selectSubject = { _ in throw WorkflowBridgeError.invalidImage("没有识别到主体") }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch, manifestURL: f.manifest)
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.matte].state == .failed && $0[.geometry].state == .pending })
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("ai")); XCTAssertFalse(calls.contains("analyze"))
    }
    func testPublishedPhotoshopMaskRecoversAfterManifestWriteWasInterrupted() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.matteProvider = .photoshop
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
        try await reopened.retry(batchID: batch.id, specimenIDs: batch.specimens.map(\.id), stage: .matte)
        let recovered = try await reopened.batch(batchID: batch.id)
        XCTAssertTrue(recovered.activeTasks.allSatisfy { $0[.matte].state == .completed && $0[.geometry].state == .waitingReview })
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 2, "Reuse both saved masks without rerunning subject selection")
        XCTAssertFalse(calls.contains("ai"))
    }
    func testPSDSubdirectoryRejectsSymlinkEscapeAndUnexpectedName() throws {
        let f = try ExecutorFixture(checks: false)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory); try? FileManager.default.removeItem(at: outside) }
        var batch = f.batch; batch.psdSubdirectory = true
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
        // Photoshop 图层属性由宿主提供；执行实际角色校验，保留旧双组兼容并拒绝任意第三层。
        context.evaluateScript("""
        wfHasMask=function(l){return !!l.mask;};wfBounds=function(){return [0,0,100,100];};
        var base={id:1,name:'底图',typename:'ArtLayer'},cutout={id:2,name:'抠图',typename:'ArtLayer',mask:true};
        var original={id:3,name:'原始堆栈',typename:'LayerSet'};
        var adjust={id:4,name:'共同调整',typename:'LayerSet',layers:[cutout,base]};
        var LayerKind={SOLIDFILL:'solidFill',NORMAL:'normal'};
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
