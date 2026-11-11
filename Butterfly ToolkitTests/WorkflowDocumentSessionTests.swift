// 单面作用域跨服务保留同一 Photoshop 文档，保护人工未保存内容和租约边界。
import XCTest
import JavaScriptCore
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowDocumentSessionTests: XCTestCase {
    private final class Runtime {
        let context = JSContext()!
        init() {
            context.evaluateScript("""
            var events=[],nextID=1,customOptions={},app={documents:[]},SaveOptions={DONOTSAVECHANGES:0};
            function File(path){this.fsName=path;}
            function openFile(path){var d={id:nextID++,fullName:new File(path),saved:true};
                d.close=function(){events.push('close:'+d.fullName.fsName);app.documents=app.documents.filter(function(x){return x!==d;});};
                app.documents.push(d);app.activeDocument=d;events.push('open:'+path);return d;}
            app.open=function(file){return openFile(file.fsName);};
            function ActionDescriptor(){this.values={};}
            ['Integer','String','Boolean'].forEach(function(t){ActionDescriptor.prototype['put'+t]=function(k,v){this.values[k]=v;};ActionDescriptor.prototype['get'+t]=function(k){return this.values[k];};});
            function stringIDToTypeID(x){return x;}
            app.putCustomOptions=function(k,v){customOptions[k]=v;};
            app.getCustomOptions=function(k){if(!customOptions[k])throw new Error('missing');return customOptions[k];};
            app.eraseCustomOptions=function(k){delete customOptions[k];};
            """)
        }
        func run(_ script: String) throws -> String {
            context.exception = nil
            let anchor = "function wfHideAll(doc) {for(var i=0;i<doc.layers.length;i++)doc.layers[i].visible=false;}"
            let result = context.evaluateScript(script.replacingOccurrences(of: "#target photoshop", with: "")
                .replacingOccurrences(of: anchor, with: anchor + "\nwfMetadata=function(doc){return {width:2,height:2,profile:'sRGB',summary:'stack'};};"))
            if let error = context.exception?.toString() {
                if error.contains("WORKFLOW_UNSAVED") { throw WorkflowBridgeError.unsavedDocument }
                if error.contains("WORKFLOW_STALE_DOCUMENT") { throw WorkflowBridgeError.staleSource }
                throw WorkflowBridgeError.photoshop(error)
            }
            return result?.toString() ?? ""
        }
        var events: [String] { context.objectForKeyedSubscript("events")?.toArray() as? [String] ?? [] }
    }
    private func fixture() throws -> (URL, URL, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SessionTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("work.psd"), owner = UUID()
        try Data("saved stack".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString])
            .write(to: document.appendingPathExtension("workflow-owner.json"))
        return (folder, document, owner)
    }
    func testTwoServicesShareWorkingDocumentButIndependentlyReadSavedSnapshots() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        try await bridge.withTaskDocument(owner: owner, document: document) {
            let first = try await bridge.refreshSavedPSD(document: document, owner: owner)
            let second = try await bridge.refreshSavedPSD(document: document, owner: owner)
            XCTAssertEqual(first, second)
        }
        XCTAssertEqual(runtime.events.filter { $0 == "open:" + document.path }.count, 1)
        XCTAssertEqual(runtime.events.filter { $0 == "close:" + document.path }.count, 1)
        XCTAssertEqual(runtime.events.filter { $0.hasPrefix("open:") }.count, 3, "Both captures must read back immutable disk copies")
    }
    func testDirtyDocumentIsNeverClosedDuringScopeCleanup() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        do {
            try await bridge.withTaskDocument(owner: owner, document: document) {
                _ = try await bridge.refreshSavedPSD(document: document, owner: owner)
                await MainActor.run { _ = runtime.context.evaluateScript("app.documents[0].saved=false;") }
            }
            XCTFail("Unsaved scope completion accepted")
        } catch WorkflowBridgeError.unsavedDocument {}
        XCTAssertFalse(runtime.events.contains("close:" + document.path))
    }
    func testUnresolvedWriteIntentNeverRepeatsSubjectSelectionOrGeometry() async throws {
        for operation in ["subject", "geometry"] {
            let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            let runtime = Runtime()
            let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
            let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
            let record = document.appendingPathExtension("workflow-owner.json")
            try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,
                "pendingMutation":["sourceVersion":snapshot.contentVersion,"operation":operation]])
                .write(to: record, options: .atomic)
            do {
                if operation == "subject" { _ = try await bridge.selectSubject(snapshot: snapshot) }
                else { _ = try await bridge.applyGeometry(snapshot: snapshot, solution: ExecutorFixture.solution(snapshot.contentVersion)) }
                XCTFail("Unresolved write intent was repeated")
            } catch WorkflowBridgeError.interruptedWrite {}
            XCTAssertEqual(try AIFileValidation.hash(document.path), snapshot.contentVersion)
            let ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
            XCTAssertNotNil(ownership["pendingMutation"], "Keep intent and immutable checkpoint available for manual recovery")
        }
    }
    func testManualAcknowledgementRejectsChangedSavedVersionAndKeepsWriteIntent() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
        let record = document.appendingPathExtension("workflow-owner.json")
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,
            "pendingMutation":["sourceVersion":snapshot.contentVersion,"operation":"geometry"]])
            .write(to: record, options: .atomic)
        try Data("changed human save".utf8).write(to: document)
        do { try await bridge.acknowledgeManualResult(snapshot: snapshot); XCTFail("Changed manual version accepted") }
        catch WorkflowBridgeError.staleSource {}
        let ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertNotNil(ownership["pendingMutation"])
    }
    func testFailureBeforeAnyWorkingDocumentChangeCanReleaseTheFaceSafely() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { script in
            if script.contains("copy.mergeVisibleLayers()") { throw WorkflowBridgeError.invalidImage("未识别到主体") }
            return try await runtime.run(script)
        })
        let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
        do {
            _ = try await bridge.withTaskDocument(owner: owner, document: document) {
                try await bridge.selectSubject(snapshot: snapshot)
            }
            XCTFail("Missing subject accepted")
        } catch WorkflowBridgeError.invalidImage {}
        let record = document.appendingPathExtension("workflow-owner.json")
        let ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertNil(ownership["pendingMutation"])
        XCTAssertEqual(try AIFileValidation.hash(document.path), snapshot.contentVersion)
    }
    func testRestoreCheckpointUsesImmutableBytesAndNeverTouchesOriginalUserDocument() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        let checkpoint = try await bridge.refreshSavedPSD(document: document, owner: owner)
        try Data("later human save".utf8).write(to: document)
        let path = String(decoding: try JSONEncoder().encode(document.path), as: UTF8.self)
        runtime.context.evaluateScript("var userDoc=openFile(\(path));userDoc.saved=false;events=[];")
        let destination = folder.appendingPathComponent("rerun.psd")
        let restored = try await bridge.restoreCheckpoint(snapshot: checkpoint, destination: destination)
        XCTAssertEqual(restored.contentVersion, checkpoint.contentVersion)
        XCTAssertEqual(restored.workingURL, destination)
        XCTAssertEqual(try Data(contentsOf: document), Data("later human save".utf8))
        XCTAssertFalse(runtime.events.contains("close:" + document.path))
        let repeated = try await bridge.restoreCheckpoint(snapshot: checkpoint, destination: destination)
        XCTAssertEqual(restored, repeated)
        let foreign = folder.appendingPathComponent("foreign.psd")
        try Data(contentsOf: checkpoint.snapshotURL).write(to: foreign)
        do { _ = try await bridge.restoreCheckpoint(snapshot: checkpoint, destination: foreign); XCTFail("Foreign identical bytes claimed") }
        catch WorkflowBridgeError.ownershipConflict {}
    }
    func testManualMaskAdoptionCannotResolveAnUncertainAutomaticWrite() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,
            "pendingMutation":["sourceVersion":"initial","operation":"subject"]])
                .write(to: document.appendingPathExtension("workflow-owner.json"), options: .atomic)
        do { _ = try await bridge.adoptManualMask(document: document, owner: owner); XCTFail("Uncertain automatic write was implicitly accepted") }
        catch WorkflowBridgeError.interruptedWrite {}
        XCTAssertTrue(runtime.events.isEmpty)
    }
    func testScopeRejectsDifferentOwnerAndPathWithoutRequestingAnotherLease() async throws {
        let (folder, document, owner) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = Runtime()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { try await runtime.run($0) })
        try await bridge.withTaskDocument(owner: owner, document: document) {
            for (requestedOwner, requestedDocument) in [(UUID(), document), (owner, folder.appendingPathComponent("other.psd"))] {
                do { _ = try await bridge.refreshSavedPSD(document: requestedDocument, owner: requestedOwner); XCTFail("Scope identity crossed") }
                catch WorkflowBridgeError.ownershipConflict {}
            }
        }
    }
}
