import XCTest
import Darwin
import JavaScriptCore
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowBridgeTests: XCTestCase {
    private final class DocumentRuntime {
        let context = JSContext()!
        let metadata: String
        init(metadata: String, nativePathPrefix: String = "") {
            self.metadata = metadata
            context.evaluateScript("""
            var $={global:{}},events=[],nextID=1,customOptions={},app={documents:[]},SaveOptions={DONOTSAVECHANGES:0};
            function File(path){this.fsName=path;}
            function openFile(path){var d={id:nextID++,fullName:new File("\(nativePathPrefix)"+path),saved:true};
                d.close=function(){events.push('close:'+d.id);app.documents=app.documents.filter(function(x){return x!==d;});};
                app.documents.push(d);app.activeDocument=d;events.push('open:'+d.id);return d;}
            app.open=function(file){return openFile(file.fsName);};
            function ActionDescriptor(){this.values={};};['putUnitDouble','putObject'].forEach(function(k){ActionDescriptor.prototype[k]=function(){};});
            ['Integer','String','Boolean'].forEach(function(type){ActionDescriptor.prototype['put'+type]=function(k,v){this.values[k]=v;};ActionDescriptor.prototype['get'+type]=function(k){return this.values[k];};});
            function stringIDToTypeID(x){return x;}
            app.putCustomOptions=function(k,v,persistent){if(persistent)throw new Error('must not persist');customOptions[k]=v;};
            app.getCustomOptions=function(k){if(!customOptions[k])throw new Error('missing');return customOptions[k];};
            app.eraseCustomOptions=function(k){delete customOptions[k];};
            function charIDToTypeID(x){return x;}function executeAction(){};
            var DialogModes={NO:0};function UnitValue(x){return x;}
            """)
        }
        func run(_ script: String) throws -> String {
            context.exception = nil
            context.evaluateScript("$.global={};") // Photoshop resets globals between do-javascript-file calls.
            let anchor = "function wfHideAll(doc) {for(var i=0;i<doc.layers.length;i++)doc.layers[i].visible=false;}"
            let overrides = """
            wfMetadata=function(doc){events.push('inspect:'+doc.fullName.fsName);return \(metadata);};
            wfRoles=function(doc){return {base:{},adjust:{rotate:function(){},translate:function(){}}};};
            wfBounds=function(){return [0,0,2,2];};
            wfSave=function(doc){events.push('save:'+doc.id);};
            """
            let result = context.evaluateScript(script.replacingOccurrences(of: "#target photoshop", with: "").replacingOccurrences(of: anchor, with: anchor + overrides))
            if let error = context.exception?.toString() {
                if error.contains("WORKFLOW_UNSAVED") { throw WorkflowBridgeError.unsavedDocument }
                if error.contains("WORKFLOW_STALE_DOCUMENT") { throw WorkflowBridgeError.staleSource }
                throw WorkflowBridgeError.photoshop(error)
            }
            return result?.toString() ?? ""
        }
        func events() -> [String] { context.objectForKeyedSubscript("events")?.toArray() as? [String] ?? [] }
    }
    func testApplyKeepsDocumentOpenThroughSaveAndCapture() async throws {
        for (reuse,nativePrefix) in [(false,""),(true,""),(true,"/native")] {
            let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
            let runtime = DocumentRuntime(metadata: try await f.runner("metadata"),nativePathPrefix: nativePrefix)
            let bridge = PhotoshopWorkflowBridge(workspace: f.directory,coordinator: PhotoshopExecutionCoordinator(),scriptRunner: { try await runtime.run($0) },reuseDocumentsWithinOperation: reuse)
            var solution = ExecutorFixture.solution(saved.contentVersion)
            solution.angleDegrees = 0; solution.sourceCropRect = CGRect(x: 0,y: 0,width: 2,height: 2); solution.outputSize = CGSize(width: 2,height: 2)
            let result = try await bridge.applyGeometry(snapshot: saved,solution: solution)
            XCTAssertEqual(result,saved)
            let events = runtime.events()
            XCTAssertEqual(events.filter { $0.hasPrefix("open:") }.count,reuse ? 2 : 4)
            XCTAssertEqual(events.filter { $0.hasPrefix("close:") }.count,reuse ? 2 : 4)
            XCTAssertEqual(events.filter { $0.hasPrefix("inspect:") }.count,4,"Keep verify, save metadata and both capture inspections")
            if reuse { XCTAssertTrue(events.contains("inspect:" + nativePrefix + saved.snapshotURL.path),"Capture must independently inspect saved disk content") }
            XCTAssertEqual(runtime.context.objectForKeyedSubscript("app")?.forProperty("documents")?.toArray()?.count,0)
        }
    }
    func testDirtyBorrowedDocumentIsNotSavedOrClosed() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata"))
        let path = String(decoding:try JSONEncoder().encode(f.document.path),as:UTF8.self)
        runtime.context.evaluateScript("var userDoc=openFile(\(path));userDoc.saved=false;events=[];")
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { try await runtime.run($0) },reuseDocumentsWithinOperation: true)
        do { _ = try await bridge.applyGeometry(snapshot: saved,solution: ExecutorFixture.solution(saved.contentVersion)); XCTFail("Dirty borrowed document accepted") }
        catch WorkflowBridgeError.unsavedDocument {}
        XCTAssertTrue(runtime.events().isEmpty)
    }
    func testPhotoshopRestartDoesNotReuseOldDocumentID() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata"))
        let path = String(decoding:try JSONEncoder().encode(f.document.path),as:UTF8.self)
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            let result = try await runtime.run(script)
            if script.contains("app.putCustomOptions(") {
                await MainActor.run { _ = runtime.context.evaluateScript("$.global={};customOptions={};app.documents=[];nextID=1;openFile(\(path));events=[];") }
            }
            return result
        },reuseDocumentsWithinOperation: true)
        do { _ = try await bridge.applyGeometry(snapshot: saved,solution: ExecutorFixture.solution(saved.contentVersion)); XCTFail("Restarted Photoshop reused old ID") }
        catch WorkflowBridgeError.staleSource {}
        XCTAssertTrue(runtime.events().isEmpty,"Never save/close the replacement document")
        XCTAssertEqual(runtime.context.objectForKeyedSubscript("app")?.forProperty("documents")?.toArray()?.count,1)
    }
    func testOwnedDocumentBecomingDirtyIsNotDiscardedDuringCleanup() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata"))
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            let result = try await runtime.run(script)
            if script.contains("wfSave(doc);return") {
                await MainActor.run { _ = runtime.context.evaluateScript("app.activeDocument.saved=false;") }
            }
            return result
        },reuseDocumentsWithinOperation: true)
        var solution = ExecutorFixture.solution(saved.contentVersion)
        solution.sourceCropRect = CGRect(x:0,y:0,width:2,height:2); solution.outputSize = CGSize(width:2,height:2)
        do { _ = try await bridge.applyGeometry(snapshot: saved,solution: solution); XCTFail("Dirty document discarded") }
        catch WorkflowBridgeError.unsavedDocument {}
        XCTAssertFalse(runtime.events().contains { $0.hasPrefix("close:") })
    }
    func testPauseWaitsForDocumentCleanupBeforeManualLease() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata")), gate = Gate(), lease = PhotoshopExecutionCoordinator()
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,coordinator: lease,scriptRunner: { script in
            if script.contains("finally{app.eraseCustomOptions(") { await gate.suspend() }
            return try await runtime.run(script)
        },reuseDocumentsWithinOperation: true)
        var solution = ExecutorFixture.solution(saved.contentVersion)
        solution.sourceCropRect = CGRect(x:0,y:0,width:2,height:2); solution.outputSize = CGSize(width:2,height:2)
        let work = Task { try await bridge.applyGeometry(snapshot: saved,solution: solution) }
        while await gate.values().isEmpty { await Task.yield() }
        work.cancel()
        let manual = Task { try await lease.beginManualEditing(owner: f.owner); await gate.append(2) }
        for _ in 0..<100 { await Task.yield() }
        let waiting = await gate.values(); XCTAssertEqual(waiting,[1])
        await gate.finish(); _ = try await work.value; try await manual.value
        await lease.endManualEditing(owner: f.owner)
        let done = await gate.values(); XCTAssertEqual(done,[1,2])
        XCTAssertEqual(runtime.context.objectForKeyedSubscript("app")?.forProperty("documents")?.toArray()?.count,0)
    }
    func testCleanBorrowedDocumentRemainsOpenAfterGeometry() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata")), log = PerformanceLog()
        let path = String(decoding:try JSONEncoder().encode(f.document.path),as:UTF8.self)
        runtime.context.evaluateScript("var userDoc=openFile(\(path));events=[];")
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { try await runtime.run($0) },performanceObserver: { log.append($0) },reuseDocumentsWithinOperation: true)
        var solution = ExecutorFixture.solution(saved.contentVersion)
        solution.sourceCropRect = CGRect(x:0,y:0,width:2,height:2); solution.outputSize = CGSize(width:2,height:2)
        _ = try await bridge.applyGeometry(snapshot: saved,solution: solution)
        XCTAssertFalse(runtime.events().contains("close:1"))
        XCTAssertEqual(runtime.context.objectForKeyedSubscript("app")?.forProperty("documents")?.toArray()?.count,1)
        XCTAssertTrue(log.values().allSatisfy { $0.taskID == f.owner },"Detached cleanup retains observation attribution")
    }
    func testInvalidAcquisitionResponseStillClosesOwnedDocument() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let saved = try await PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner).refreshSavedPSD(document: f.document,owner: f.owner)
        let runtime = DocumentRuntime(metadata: try await f.runner("metadata"))
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            let result = try await runtime.run(script)
            return script.contains("app.putCustomOptions(") ? "invalid response" : result
        },reuseDocumentsWithinOperation: true)
        do { _ = try await bridge.applyGeometry(snapshot: saved,solution: ExecutorFixture.solution(saved.contentVersion)); XCTFail("Invalid acquisition response accepted") }
        catch is DecodingError {}
        XCTAssertEqual(runtime.events(),["open:1","close:1"])
        XCTAssertEqual(runtime.context.objectForKeyedSubscript("app")?.forProperty("documents")?.toArray()?.count,0)
    }
    private actor ReuseFaults {
        var checkpoints: [String] = []
        var geometrySaved = false
        var geometryInterrupted = false
        func checkpoint(_ point: PhotoshopInstallCheckpoint, enabled: Bool) throws {
            let name = point == .prepared ? "prepared" : "published"
            let first = !checkpoints.contains(name); checkpoints.append(name)
            if enabled && first { throw WorkflowBridgeError.photoshop("injected after " + name) }
        }
        func afterScript(_ script: String) throws {
            if script.contains("d.putBoolean(charIDToTypeID('Dlt '),false)") { geometrySaved = true }
            if geometrySaved && !geometryInterrupted && script.contains("finally{app.eraseCustomOptions(") {
                geometryInterrupted = true
                throw WorkflowBridgeError.photoshop("injected after geometry cleanup")
            }
        }
    }
    func testInstallReusesOnlyLeaseOwnedDocumentsAndPublicationReplacesHandleWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        if let retained = env["WORKFLOW_REUSE_COMPARE"] {
            try verifyReusePixels(in: WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(retained),python: XCTUnwrap(env["WORKFLOW_PNG_PYTHON"]))
            return
        }
        guard let destination = env["WORKFLOW_REUSE_EVIDENCE"] else { throw XCTSkip("Real document reuse comparison is opt-in") }
        let root = try WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(destination), fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        let fixture = try JSONDecoder().decode([String:String].self,from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["WORKFLOW_REUSE_FIXTURE"]))))
        try fm.createDirectory(at: root,withIntermediateDirectories: true)
        func quote(_ url: URL) throws -> String {
            // Foundation can preserve /tmp while PS fullName uses /private/tmp.
            let path = try XCTUnwrap(realpath(url.path,nil)); defer { free(path) }
            return String(decoding:try JSONEncoder().encode(String(cString:path)),as:UTF8.self)
        }
        func cleanup() async {
            _ = try? await PhotoshopWorkflowBridge.execute("""
            (function(){for(var i=app.documents.length-1;i>=0;i--){var d=app.documents[i];try{
                if(d.fullName.fsName.indexOf(\(try quote(root))+'/')===0 && d.saved)d.close(SaveOptions.DONOTSAVECHANGES);
            }catch(e){}}return 'cleaned';}());
            """)
        }
        var variants: [(String,RoleImages,URL,URL,URL)] = []
        var firstSolution: GeometrySolution?
        do {
            for reuse in [false,true] {
                if !reuse, let previous = env["WORKFLOW_REUSE_BASELINE"] {
                    let folder = try WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(previous)
                    let snapshot = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: folder.appendingPathComponent("final-snapshot.json")))
                    struct CachedRoles: Decodable { let snapshot: PSDSnapshot; let images: RoleImages }
                    let cache = folder.appendingPathComponent("role-cache/\(snapshot.taskID)")
                    let entries = try fm.contentsOfDirectory(at: cache,includingPropertiesForKeys: nil).map {
                        try JSONDecoder().decode(CachedRoles.self,from: Data(contentsOf: $0))
                    }
                    let finalRoles = try XCTUnwrap(entries.first { $0.snapshot.contentVersion == snapshot.contentVersion }).images
                    let installedRoles = try XCTUnwrap(entries.first { $0.snapshot.contentVersion != snapshot.contentVersion }).images
                    firstSolution = try await WorkflowGeometryCache().geometry(source: installedRoles,request: GeometryRequest())
                    let inputs = folder.appendingPathComponent("data/processed/\(snapshot.taskID)")
                    let input = try XCTUnwrap(fm.contentsOfDirectory(at: inputs,includingPropertiesForKeys: nil).first { $0.pathExtension == "png" })
                    variants.append(("original",finalRoles,input,folder.appendingPathComponent("final.jpg"),folder.appendingPathComponent("final.png")))
                    continue
                }
                let label = reuse ? "reuse" : "original", folder = root.appendingPathComponent(label), owner = UUID()
                try fm.createDirectory(at: folder,withIntermediateDirectories: true)
                let document = folder.appendingPathComponent("stack.psd"), alpha = folder.appendingPathComponent("alpha.png"), cutout = folder.appendingPathComponent("cutout.png")
                for (key, target) in [("stack",document),("alpha",alpha),("cutout",cutout)] {
                    try WorkflowPipelinePerformanceTests.copyFixture(URL(fileURLWithPath: XCTUnwrap(fixture[key])),to: target,in: root)
                }
                try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath: document.path)
                try JSONSerialization.data(withJSONObject:["owner":owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
                let samples = PerformanceLog(), faults = ReuseFaults()
                defer { try? JSONEncoder().encode(samples.values()).write(to: folder.appendingPathComponent("operations.json")) }
                let bridge = PhotoshopWorkflowBridge(workspace: folder,coordinator: PhotoshopExecutionCoordinator(),scriptRunner: { script in
                    let result: String
                    do { result = try await PhotoshopWorkflowBridge.execute(script) }
                    catch {
                        try? script.write(to: folder.appendingPathComponent("failed-script.jsx"),atomically: true,encoding: .utf8)
                        throw error
                    }
                    if reuse { try await faults.afterScript(script) }
                    return result
                },installCheckpoint: { try await faults.checkpoint($0,enabled: reuse) },performanceObserver: { samples.append($0) },reuseDocumentsWithinOperation: reuse)
                let snapshot = try await bridge.refreshSavedPSD(document: document,owner: owner)
                let input = try await bridge.exportStackPNG(snapshot: snapshot)
                let matte = try MatteArtifact(inputPNGFingerprint: input.fingerprint,alphaURL: alpha,alphaFingerprint: AIFileValidation.hash(alpha.path),cutoutURL: cutout,cutoutFingerprint: AIFileValidation.hash(cutout.path),orientation: 1,pixelSize: snapshot.pixelSize)
                var borrowedID: Int?
                if reuse {
                    let result = try await PhotoshopWorkflowBridge.execute("var task3Borrowed=app.open(new File(\(try quote(document))));String(task3Borrowed.id);")
                    borrowedID = try XCTUnwrap(Int(result))
                    try result.write(to: folder.appendingPathComponent("borrowed-before-id.txt"),atomically: true,encoding: .utf8)
                }
                let start = ProcessInfo.processInfo.systemUptime
                if reuse {
                    for checkpoint in ["prepared","published"] {
                        do { _ = try await bridge.installMatte(snapshot: snapshot,matte: matte); XCTFail("Expected interruption at \(checkpoint)") }
                        catch WorkflowBridgeError.photoshop(let message) { XCTAssertTrue(message.contains("injected after " + checkpoint)) }
                    }
                }
                let installed = try await bridge.installMatte(snapshot: snapshot,matte: matte)
                let installSeconds = ProcessInfo.processInfo.systemUptime - start
                if let borrowedID {
                    let result = try await PhotoshopWorkflowBridge.execute("""
                    (function(){for(var i=0;i<app.documents.length;i++){var d=app.documents[i];try{
                        if(d.fullName.fsName===\(try quote(document))){var id=d.id;if(!d.saved)throw new Error('dirty fixture');d.close(SaveOptions.DONOTSAVECHANGES);return String(id);}
                    }catch(e){throw e;}}return 'missing';}());
                    """)
                    let newID = try XCTUnwrap(Int(result),"The borrowed published document must remain open after service cleanup")
                    XCTAssertNotEqual(newID,borrowedID,"Publication must replace the old document handle")
                    try result.write(to: folder.appendingPathComponent("borrowed-after-id.txt"),atomically: true,encoding: .utf8)
                }
                let roles = try await bridge.extractRoles(snapshot: installed)
                let solution = try await WorkflowGeometryCache().geometry(source: roles,request: GeometryRequest())
                XCTAssertTrue(solution.isApplicable)
                if var expected = firstSolution { expected.sourceVersion = solution.sourceVersion; XCTAssertEqual(solution,expected) }
                else { firstSolution = solution }
                let geometryStart = ProcessInfo.processInfo.systemUptime
                let transformed: PSDSnapshot
                if reuse {
                    do { _ = try await bridge.applyGeometry(snapshot: installed,solution: solution); XCTFail("Geometry interruption missing") }
                    catch WorkflowBridgeError.photoshop(let message) { XCTAssertTrue(message.contains("injected after geometry cleanup")) }
                    do { _ = try await bridge.applyGeometry(snapshot: installed,solution: solution); XCTFail("Old snapshot rotated twice") }
                    catch WorkflowBridgeError.staleSource {} catch WorkflowBridgeError.invalidStructure {}
                    transformed = try await bridge.refreshSavedPSD(document: document,owner: owner)
                } else { transformed = try await bridge.applyGeometry(snapshot: installed,solution: solution) }
                let geometrySeconds = ProcessInfo.processInfo.systemUptime - geometryStart
                let resultRoles = try await bridge.extractRoles(snapshot: transformed)
                let hd = folder.appendingPathComponent("final.jpg"), png4k = folder.appendingPathComponent("final.png")
                let renderStart = ProcessInfo.processInfo.systemUptime
                let renderer = WorkflowAssetRenderer()
                try renderer.renderHD(roles: resultRoles,destination: hd)
                try renderer.render4K(roles: resultRoles,layout: .png4k,destination: png4k)
                let record: [String:Any] = ["installIncludingInjectedRecoverySeconds":installSeconds,"geometryIncludingInjectedRecoverySeconds":geometrySeconds,"renderSeconds":ProcessInfo.processInfo.systemUptime-renderStart,"injectedRecovery":reuse]
                try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timing.json"))
                try JSONEncoder().encode(samples.values()).write(to: folder.appendingPathComponent("operations.json"))
                try JSONEncoder().encode(transformed).write(to: folder.appendingPathComponent("final-snapshot.json"))
                variants.append((label,resultRoles,input.pngURL,hd,png4k))
            }
            let a = variants[0], b = variants[1]
            for (name,left,right) in [("input",a.2,b.2),("base",a.1.basePNG,b.1.basePNG),("mask",a.1.maskPNG,b.1.maskPNG),("cutout",a.1.cutoutPNG,b.1.cutoutPNG),("4k",a.4,b.4)] {
                let folder = root.appendingPathComponent(name); try fm.createDirectory(at: folder,withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject:["legacy":["png":left.path],"fast":["png":right.path]]).write(to: folder.appendingPathComponent("run-1.json"))
            }
            let left = try WorkflowRaster.read(a.3), right = try WorkflowRaster.read(b.3)
            XCTAssertEqual(left.pixels,right.pixels); XCTAssertEqual(left.profileData,right.profileData); XCTAssertEqual(left.size,right.size)
            try verifyReusePixels(in: root,python: XCTUnwrap(env["WORKFLOW_PNG_PYTHON"]))
            await cleanup()
        } catch { await cleanup(); throw error }
    }
    private func verifyReusePixels(in root: URL, python: String) throws {
        let verifier = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/verify_workflow_png_pairs.py")
        let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: python)
        // Inputs/roles require ICC. Existing final 4K output uses the PNG sRGB chunk;
        // both paths must still match every raw pixel, color tag, orientation and bit depth.
        let comparison = """
        import json,runpy,sys
        from pathlib import Path
        read=runpy.run_path(sys.argv[1])['read_png']
        checks=[]
        for record in sorted(Path(sys.argv[2]).glob('*/run-*.json')):
            pair=json.loads(record.read_text())
            before,after=(read(pair[k]['png']) for k in ('legacy','fast'))
            differences=[k for k in before if before[k]!=after[k]]
            if record.parent.name=='4k':
                if not after['icc'] and after['srgb'] is None: differences.append('missingColorSpace')
            elif not after['icc']: differences.append('missingICC')
            checks.append({'record':str(record),'differences':differences})
        passed=len(checks)==5 and all(not c['differences'] for c in checks)
        print(json.dumps({'passed':passed,'checks':checks},indent=2))
        sys.exit(0 if passed else 1)
        """
        process.arguments = ["-c",comparison,verifier.path,root.path]; process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try data.write(to: root.appendingPathComponent("raw-pixel-final-comparison.json"))
        XCTAssertEqual(process.terminationStatus,0,String(decoding:data,as:UTF8.self))
    }
    private nonisolated final class PerformanceLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [WorkflowPerformanceSample] = []
        func append(_ sample: WorkflowPerformanceSample) { lock.withLock { stored.append(sample) } }
        func values() -> [WorkflowPerformanceSample] { lock.withLock { stored } }
    }
    func testPerformanceObserverIsOptInAndPreservesResults() async throws {
        let f = try roleCacheFixture(), log = PerformanceLog()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let baseline = PhotoshopWorkflowBridge(workspace: f.directory, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: f.runner)
        let before = try await baseline.refreshSavedPSD(document: f.document, owner: f.owner)
        XCTAssertTrue(log.values().isEmpty)
        let observed = PhotoshopWorkflowBridge(workspace: f.directory, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: f.runner, performanceObserver: { log.append($0) })
        let after = try await observed.refreshSavedPSD(document: f.document, owner: f.owner)
        XCTAssertEqual(before, after)
        let samples = log.values()
        XCTAssertEqual(samples.first?.operation, "lease.wait.refresh")
        XCTAssertEqual(samples.last?.operation, "service.refresh")
        XCTAssertEqual(samples.filter { $0.operation == "ps.invoke" }.count, 2)
        XCTAssertTrue(samples.contains { $0.operation == "capture" })
        XCTAssertTrue(samples.contains { $0.operation == "hash" })
        XCTAssertTrue(samples.allSatisfy { $0.taskID == f.owner && $0.seconds >= 0 && $0.seconds.isFinite })
        let calls = await f.calls.values(); XCTAssertEqual(calls, [1], "Observation must preserve the validated role cache")
    }
    func testLeaseWaitIsSeparateFromOperationTime() async throws {
        let f = try roleCacheFixture(), log = PerformanceLog(), lease = PhotoshopExecutionCoordinator(), gate = Gate()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let held = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory, coordinator: lease, scriptRunner: f.runner, performanceObserver: { log.append($0) })
        let start = ProcessInfo.processInfo.systemUptime
        let queued = Task { try await bridge.refreshSavedPSD(document: f.document, owner: f.owner) }
        // The lease is gated, so this delay is known waiting, never Photoshop execution.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(log.values().isEmpty)
        let released = ProcessInfo.processInfo.systemUptime
        await gate.finish(); try await held.value; _ = try await queued.value
        let ended = ProcessInfo.processInfo.systemUptime, samples = log.values()
        let wait = try XCTUnwrap(samples.first { $0.operation == "lease.wait.refresh" })
        let execution = try XCTUnwrap(samples.first { $0.operation == "service.refresh" })
        XCTAssertGreaterThanOrEqual(wait.seconds, 0.12)
        XCTAssertLessThanOrEqual(execution.seconds, ended - released)
        XCTAssertLessThanOrEqual(wait.seconds + execution.seconds, ended - start)
        XCTAssertEqual(samples.first?.operation, wait.operation)
        XCTAssertEqual(samples.last?.operation, execution.operation)
    }
    func testManifestObservationPreservesBytesAndRecovery() async throws {
        let directory = try temporaryDirectory(), log = PerformanceLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("batch.json"), observedURL = directory.appendingPathComponent("observed.json")
        let original = WorkflowBatch(sourceDirectory: directory, outputDirectory: directory, specimens: [])
        try await WorkflowBatchStore().save(original, to: url)
        let store = WorkflowBatchStore(performanceObserver: { log.append($0) })
        try await store.save(original, to: observedURL)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: observedURL))
        var revised = original; revised.revision += 1
        try await store.save(revised, to: observedURL)
        try Data("broken".utf8).write(to: observedURL)
        let recovered = try await store.load(from: observedURL)
        XCTAssertEqual(recovered, original)
        XCTAssertEqual(log.values().map(\.operation), ["manifest.save", "manifest.save"])
    }
    func testScriptObservationIncludesFinallyCloseAndPreservesErrors() async throws {
        let directory = try temporaryDirectory(), document = directory.appendingPathComponent("plain.psd"), owner = UUID(), log = PerformanceLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("plain-psd".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner": owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
            let context = JSContext()!
            context.evaluateScript("""
                var events=[],SaveOptions={DONOTSAVECHANGES:0};
                function File(path){this.fsName=path;}
                var app={documents:[],open:function(file){
                    events.push('open');
                    var doc={id:1,saved:true,fullName:file,layers:[],colorProfileName:'sRGB',
                        width:{as:function(){return 2;}},height:{as:function(){return 2;}},
                        close:function(){events.push('close');app.documents=[];}};
                    app.documents.push(doc);return doc;
                }};
                """)
            let result = context.evaluateScript(script.replacingOccurrences(of: "#target photoshop", with: ""))
            if let exception = context.exception { throw WorkflowBridgeError.photoshop(exception.toString()) }
            XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "open,close")
            return try XCTUnwrap(result?.toString())
        }
        let plain = PhotoshopWorkflowBridge(workspace: directory, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: runner)
        let first = try await plain.refreshSavedPSD(document: document, owner: owner)
        let observed = PhotoshopWorkflowBridge(workspace: directory, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: runner, performanceObserver: { log.append($0) })
        let second = try await observed.refreshSavedPSD(document: document, owner: owner)
        XCTAssertEqual(first, second)
        XCTAssertEqual(log.values().filter { $0.operation == "ps.open" }.count, 2)
        XCTAssertEqual(log.values().filter { $0.operation == "ps.close" }.count, 2)
        XCTAssertEqual(log.values().filter { $0.operation == "ps.documents.peak.1" }.count, 2)
        let failing = PhotoshopWorkflowBridge(workspace: directory, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { _ in throw WorkflowBridgeError.unsavedDocument }, performanceObserver: { log.append($0) })
        do { _ = try await failing.refreshSavedPSD(document: document, owner: owner); XCTFail("Script errors must propagate") }
        catch WorkflowBridgeError.unsavedDocument {}
        XCTAssertEqual(log.values().last?.operation, "service.refresh")
    }
    actor Gate {
        var entered: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        func suspend() async { entered.append(1); await withCheckedContinuation { release = $0 } }
        func finish() { release?.resume(); release = nil }
        func append(_ value: Int) { entered.append(value) }
        func values() -> [Int] { entered }
    }
    func testPhotoshopLeaseSurvivesAwait() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate()
        let first = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let second = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertEqual(before, [1])
        await gate.finish(); try await first.value; try await second.value
        let after = await gate.values(); XCTAssertEqual(after, [1, 2])
    }
    func testManualEditingBlocksAutomaticWrites() async throws {
        let lease = PhotoshopExecutionCoordinator(), owner = UUID(), gate = Gate()
        try await lease.beginManualEditing(owner: owner)
        let automatic = Task { try await lease.run(owner: owner) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertTrue(before.isEmpty)
        await lease.endManualEditing(owner: UUID())
        let stillBlocked = await gate.values(); XCTAssertTrue(stillBlocked.isEmpty)
        await lease.endManualEditing(owner: owner); try await automatic.value
        let after = await gate.values(); XCTAssertEqual(after, [2])
    }
    func testManualRequestTakesPriorityAfterCurrentOperation() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate(), owner = UUID()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let queued = Task { await gate.append(9); try await lease.run(owner: UUID()) { await gate.append(2) } }
        while !(await gate.values()).contains(9) { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        let manual = Task { await gate.append(8); try await lease.beginManualEditing(owner: owner); await gate.append(3) }
        while !(await gate.values()).contains(8) { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        await gate.finish(); try await current.value; try await manual.value
        let before = await gate.values(); XCTAssertFalse(before.contains(2))
        await lease.endManualEditing(owner: owner); try await queued.value
    }
    func testCancelledQueuedOperationNeverWritesAndReleasesLease() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let cancelled = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        cancelled.cancel(); await gate.finish(); try await current.value
        do { try await cancelled.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        try await lease.run(owner: UUID()) { await gate.append(3) }
        let values = await gate.values(); XCTAssertEqual(values, [1,3])
    }
    func testCancelledWriterFinishesBeforeManualContinueWithoutReleasingReservation() async throws {
        let lease = PhotoshopExecutionCoordinator(),owner = UUID(),gate = Gate()
        try await lease.beginManualEditing(owner: owner)
        let finished = expectation(description: "Cancelled queued writer finishes while editing remains reserved")
        let cancelled = Task {
            do { try await lease.run(owner: owner) { await gate.append(99) }; XCTFail("Cancelled write ran") }
            catch is CancellationError { finished.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        for _ in 0..<100 { await Task.yield() }
        cancelled.cancel()
        await fulfillment(of: [finished], timeout: 1.0)
        let next = Task { try await lease.run(owner: owner) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertTrue(before.isEmpty,"Cancellation must not release manual reservation")
        await lease.endManualEditing(owner: owner); await cancelled.value; try await next.value
    }
    func testCancelledInFlightOperationRetainsLeaseUntilItActuallyFinishes() async throws {
        let lease = PhotoshopExecutionCoordinator(),gate = Gate()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        current.cancel()
        let next = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertEqual(before,[1])
        await gate.finish(); try await current.value; try await next.value
    }
    func testStackRefusesUnknownExistingPSDWithoutChangingIt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("unknown.psd")
        try Data("user-edited".utf8).write(to: document)
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in XCTFail("Existing PSD must not open"); return "" })
        let job = FocusStackJob(id: 0,sourceFiles: [document,document,document],destinationURL: document,butterflyName: "sample",side: "D")
        do { _ = try await bridge.stack(job: job,owner: UUID()); XCTFail("Unknown PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.ownershipConflict) }
        XCTAssertEqual(try Data(contentsOf: document),Data("user-edited".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.appendingPathExtension("workflow-owner.json").path))
    }
    func testUnsavedPSDRejectsRefresh() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID()
        try Data("saved".utf8).write(to: document)
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            throw WorkflowBridgeError.unsavedDocument
        })
        do { _ = try await bridge.refreshSavedPSD(document: document, owner: owner); XCTFail("Unsaved accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError, .unsavedDocument) }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["owned.psd"], "No snapshot may be created during an unsaved edit")
    }
    func testInferenceClearsRemoteFaintAlphaAndCutoutBeforeWriteback() async throws {
        try await assertResidueCleanup(standardSRGB: false)
    }
    func testStandardSRGBMatteCleanupPreservesEmbeddedICC() async throws {
        try await assertResidueCleanup(standardSRGB: true)
    }
    private func assertResidueCleanup(standardSRGB: Bool) async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.png"),alpha = directory.appendingPathComponent("alpha.png"),cutout = directory.appendingPathComponent("cutout.png")
        var values = [UInt8](repeating: 0,count: 10000)
        for y in 30..<70 { for x in 30..<70 { values[y*100+x] = 255 } }
        for y in 20..<30 { values[y*100+50] = 1 }
        for x in 0..<100 { values[95*100+x] = 2 }
        if standardSRGB {
            // 固定白色夹具只含标准 sRGB ICC，无用户照片；ImageIO 再编码会将该 ICC 简写为 sRGB 块。
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/srgb-matte-input.png")
            try FileManager.default.copyItem(at: fixture,to: source)
        } else {
            try png(source,width: 100,height: 100,pixels: Array(repeating: [UInt8](repeating: 255,count: 4),count: 10000).flatMap { $0 })
        }
        try png(alpha,width: 100,height: 100,pixels: values.flatMap { [$0,$0,$0,255] },colorSpaceName: CGColorSpace.sRGB)
        try png(cutout,width: 100,height: 100,pixels: values.flatMap { [255,255,255,$0] },colorSpaceName: standardSRGB ? CGColorSpace.sRGB : CGColorSpace.adobeRGB1998)
        if standardSRGB { try WorkflowRaster.preservePNGColorMetadata(from: source,to: cutout) }
        let input = StackPNG(snapshotVersion: "saved",pngURL: source,fingerprint: try AIFileValidation.hash(source.path),pixelSize: CGSize(width: 100,height: 100),orientation: 1,colorProfile: "Adobe RGB")
        let rawAlpha = try Data(contentsOf: alpha),rawCutout = try Data(contentsOf: cutout)
        try JSONSerialization.data(withJSONObject: ["inputSha256":input.fingerprint]).write(to: directory.appendingPathComponent("result.json"))
        let event = AIEvent(event: "completed",input: source.path,prediction: cutout.path,predictionAlpha: alpha.path)
        let result = try await WorkflowMatteService(engine: directory,workspace: directory,run: { _ in event }).infer(input: input)
        let a = try WorkflowRaster.read(result.alphaURL),c = try WorkflowRaster.read(result.cutoutURL)
        XCTAssertEqual(a.pixels[9500*4],0); XCTAssertEqual(c.pixels[9500*4+3],0)
        XCTAssertTrue(c.hasProfile); XCTAssertEqual(c.profileData,try WorkflowRaster.read(source).profileData)
        XCTAssertEqual(a.pixels[2050*4],1); XCTAssertEqual(c.pixels[2050*4+3],1)
        try WorkflowRaster.validateMatte(original: WorkflowRaster.readMatteInput(source),alpha: a,cutout: c)
        XCTAssertEqual(try Data(contentsOf: alpha),rawAlpha); XCTAssertEqual(try Data(contentsOf: cutout),rawCutout)
        XCTAssertEqual(try AIFileValidation.hash(result.alphaURL.path),result.alphaFingerprint)
        XCTAssertEqual(try AIFileValidation.hash(result.cutoutURL.path),result.cutoutFingerprint)
    }
    func testInvalidMatteResultsCannotSucceed() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.png")
        try png(inputURL, width: 2, height: 2, pixels: [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255])
        let input = StackPNG(snapshotVersion: "saved", pngURL: inputURL, fingerprint: try AIFileValidation.hash(inputURL.path), pixelSize: CGSize(width: 2,height: 2), orientation: 1, colorProfile: "sRGB")
        let alpha = directory.appendingPathComponent("alpha.png"), cutout = directory.appendingPathComponent("cutout.png")
        try png(alpha, width: 2, height: 2, pixels: [255,255,255,255, 0,0,0,255, 255,255,255,255, 0,0,0,255])
        try png(cutout, width: 2, height: 2, pixels: [255,0,0,255, 0,0,0,0, 0,0,255,255, 0,0,0,0])
        let record = directory.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: ["inputSha256": input.fingerprint]).write(to: record)
        let event = AIEvent(event: "completed", input: inputURL.path, prediction: cutout.path, predictionAlpha: alpha.path)
        let service = WorkflowMatteService(engine: directory, workspace: directory, device: "cpu", run: { request in
            XCTAssertEqual(request.engine, directory)
            XCTAssertEqual(request.workspace, directory)
            XCTAssertEqual(request.input, inputURL)
            XCTAssertEqual(request.device, "cpu")
            return event
        })
        _ = try await service.infer(input: input)
        let wrongInputEvent = AIEvent(event: "completed",input: "/other-source.png",prediction: cutout.path,predictionAlpha: alpha.path)
        let wrongInput = WorkflowMatteService(engine: directory,workspace: directory,run: { _ in wrongInputEvent })
        await rejects { _ = try await wrongInput.infer(input: input) }
        let missingAlphaEvent = AIEvent(event: "completed",input: inputURL.path,prediction: cutout.path)
        let missingAlpha = WorkflowMatteService(engine: directory,workspace: directory,run: { _ in missingAlphaEvent })
        await rejects { _ = try await missingAlpha.infer(input: input) }
        try JSONSerialization.data(withJSONObject: ["inputSha256": "other-input"]).write(to: record)
        await rejects { _ = try await service.infer(input: input) }
        try JSONSerialization.data(withJSONObject: ["inputSha256": input.fingerprint]).write(to: record)
        // The alpha is flipped but the cutout remains at its original coordinates.
        try png(alpha, width: 2, height: 2, pixels: [0,0,0,255,255,255,255,255,0,0,0,255,255,255,255,255])
        await rejects { _ = try await service.infer(input: input) }
        try png(alpha, width: 1, height: 1, pixels: [255,255,255,255])
        await rejects { _ = try await service.infer(input: input) }
        try Data("unreadable".utf8).write(to: alpha)
        await rejects { _ = try await service.infer(input: input) }
        try FileManager.default.removeItem(at: alpha)
        await rejects { _ = try await service.infer(input: input) }
    }
    func testMatteAcceptsWhiteCompositedEdgesButRejectsChangedPixels() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.png")
        let alpha = directory.appendingPathComponent("alpha.png"), cutout = directory.appendingPathComponent("cutout.png")
        // 使用 Adobe RGB，确保先在输入色彩空间铺白底，再转换到校验用的 sRGB。
        try png(source, width: 4, height: 1, pixels: [23,45,67,0, 0,255,0,128, 255,0,0,255, 0,0,255,255])
        try png(alpha, width: 4, height: 1, pixels: [7,7,7,255, 128,128,128,255, 255,255,255,255, 0,0,0,255], colorSpaceName: CGColorSpace.sRGB)
        let expected: [UInt8] = [255,255,255,7, 127,255,127,128, 255,0,0,255, 0,0,255,0]
        try png(cutout, width: 4, height: 1, pixels: expected)
        let input = StackPNG(snapshotVersion: "saved",pngURL: source,fingerprint: try AIFileValidation.hash(source.path),pixelSize: CGSize(width: 4,height: 1),orientation: 1,colorProfile: "Adobe RGB")
        try JSONSerialization.data(withJSONObject: ["inputSha256":input.fingerprint]).write(to: directory.appendingPathComponent("result.json"))
        let event = AIEvent(event: "completed",input: source.path,prediction: cutout.path,predictionAlpha: alpha.path)
        let service = WorkflowMatteService(engine: directory,workspace: directory,run: { _ in event })
        let result = try await service.infer(input: input)
        XCTAssertEqual(result.inputPNGFingerprint,input.fingerprint)
        for (channel,value) in [(0,UInt8(0)),(5,UInt8(0)),(9,UInt8(255)),(7,UInt8(64))] {
            var corrupt = expected; corrupt[channel] = value
            try png(cutout, width: 4, height: 1, pixels: corrupt)
            do { _ = try await service.infer(input: input); XCTFail("Accepted changed channel \(channel)") }
            catch { XCTAssertTrue(error is WorkflowBridgeError) }
        }
        try png(cutout, width: 4, height: 1, pixels: expected, colorSpaceName: CGColorSpace.sRGB)
        await rejects { _ = try await service.infer(input: input) }
        // PSD 回写继续使用原始 Alpha，不能套用 AI 的白底参照。
        try png(cutout, width: 4, height: 1, pixels: [0,0,0,0, 0,255,0,64, 255,0,0,255, 0,0,0,0])
        try WorkflowRaster.validateMatte(original: WorkflowRaster.read(source),alpha: WorkflowRaster.read(alpha),cutout: WorkflowRaster.read(cutout),respectSourceAlpha: true)
        try png(cutout, width: 4, height: 1, pixels: expected)
        XCTAssertThrowsError(try WorkflowRaster.validateMatte(original: WorkflowRaster.read(source),alpha: WorkflowRaster.read(alpha),cutout: WorkflowRaster.read(cutout),respectSourceAlpha: true))
        let installed = directory.appendingPathComponent("installed.png")
        try png(installed, width: 4, height: 1, pixels: [0,0,0,0, 0,255,0,64, 255,0,0,255, 0,0,0,0])
        let roles = RoleImages(snapshotVersion: "installed",basePNG: source,cutoutPNG: installed,maskPNG: result.alphaURL,pixelSize: input.pixelSize,coordinateOrigin: .zero,editableExtent: CGRect(origin: .zero,size: input.pixelSize),cropViewport: CGRect(origin: .zero,size: input.pixelSize))
        let services = WorkflowExecutor.Services.live(bridge: PhotoshopWorkflowBridge(workspace: directory),matte: service)
        // 中断恢复须分别验证 AI 白底结果和保留源 Alpha 的 PSD，不能要求两者透明边缘相等。
        try await services.validateInstalledMatte(roles,input,result)
        try png(installed, width: 4, height: 1, pixels: [0,0,0,0, 255,0,0,64, 255,0,0,255, 0,0,0,0])
        await rejects { try await services.validateInstalledMatte(roles,input,result) }
        XCTAssertEqual(try AIFileValidation.hash(source.path),input.fingerprint)
    }
    func testSavedRefreshCanReadWithinManualLeaseWithoutReleasingIt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID(), lease = PhotoshopExecutionCoordinator(), gate = Gate()
        try Data("saved".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner": owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, coordinator: lease, scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        try await lease.beginManualEditing(owner: owner)
        let writer = Task { try await lease.run(owner: UUID()) { await gate.append(1) } }
        let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
        XCTAssertEqual(try Data(contentsOf: snapshot.snapshotURL), Data("saved".utf8))
        let before = await gate.values(); XCTAssertTrue(before.isEmpty)
        await lease.endManualEditing(owner: owner); try await writer.value
        let after = await gate.values(); XCTAssertEqual(after, [1])
    }
    func testRefreshRejectsAFileChangingDuringSavedRead() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID(), count = Gate()
        try Data("saved".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner": owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            await count.append(1)
            if await count.values().count == 2 { try Data("being-saved".utf8).write(to: document) }
            return "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        await rejects { _ = try await bridge.refreshSavedPSD(document: document, owner: owner) }
        let files = FileManager.default.enumerator(atPath: directory.path)!.allObjects as! [String]
        XCTAssertFalse(files.contains { $0.hasPrefix("snapshots/") && $0.hasSuffix(".psd") })
    }
    func testSavedRefreshRejectsDeletedRoleIdentity() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID()
        try Data("saved".utf8).write(to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup: "1",adjustmentGroup: "2",baseLayer: "3",cutoutLayer: "4",mask: "4:mask")
        var ownership = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roles)) as! [String: Any]
        ownership = ["owner":owner.uuidString,"roles":ownership]
        try JSONSerialization.data(withJSONObject: ownership).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"deleted-role\"}"
        })
        do { _ = try await bridge.refreshSavedPSD(document: document,owner: owner); XCTFail("Deleted role accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.invalidStructure) }
    }
    func testCrashAdoptionRequiresOrderedSourcesAndInitialContentHash() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"),owner = UUID()
        try Data("initial-stack".utf8).write(to: document)
        let initialHash = try AIFileValidation.hash(document.path)
        var sources: [WorkflowSourceFile] = []
        for index in 0..<3 {
            let source = directory.appendingPathComponent("source-\(index).jpg")
            try Data("source-\(index)".utf8).write(to: source)
            sources.append(try WorkflowSourceFile(url: source.resolvingSymlinksInPath(),fingerprint: AIFileValidation.hash(source.path)))
        }
        let sourceRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sources))
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,"sources":sourceRecord,"initialStackVersion":initialHash]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory,scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        let snapshot = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: sources)
        XCTAssertEqual(snapshot.contentVersion,initialHash)
        await rejects { _ = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: Array(sources.reversed())) }
        try Data("foreign-file-at-same-path".utf8).write(to: document)
        await rejects { _ = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: sources) }
        // Legitimate later saved edits use normal refresh, not initial-stack crash adoption.
        let human = try await bridge.refreshSavedPSD(document: document,owner: owner)
        XCTAssertNotEqual(human.contentVersion,initialHash)
        XCTAssertEqual(try Data(contentsOf: snapshot.snapshotURL),Data("initial-stack".utf8))
    }
    func testRecordedMattePublicationRecoversAfterPSDWasSavedBeforeOwnershipFinalization() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"),source = directory.appendingPathComponent("source.psd"),owner = UUID()
        let version = "9d022835c729988271c49048470eb33895c616efa58078153841079ae5f24fb3"
        let result = directory.appendingPathComponent("snapshots/\(owner)/\(version).psd")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(),withIntermediateDirectories: true)
        try Data("old-stack".utf8).write(to: source);try Data("installed-matte".utf8).write(to: result)
        try FileManager.default.copyItem(at: result,to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup:"1",adjustmentGroup:"2",baseLayer:"3",cutoutLayer:"4",mask:"4:userMask")
        let prepared = try PSDSnapshot(taskID:owner,workingURL:result,snapshotURL:result,contentVersion:AIFileValidation.hash(result.path),pixelSize:CGSize(width:2,height:2),roles:roles,structureSummary:"roles")
        let fixtures = directory.appendingPathComponent("fixtures");try FileManager.default.createDirectory(at: fixtures,withIntermediateDirectories:true)
        let base = fixtures.appendingPathComponent("base.png"),mask = fixtures.appendingPathComponent("mask.png"),cutout = fixtures.appendingPathComponent("cutout.png")
        try png(base,width:2,height:2,pixels:[255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255])
        try png(mask,width:2,height:2,pixels:[255,255,255,255,0,0,0,255,255,255,255,255,0,0,0,255])
        try png(cutout,width:2,height:2,pixels:[255,0,0,255,0,0,0,0,0,0,255,255,0,0,0,0])
        let matte = try MatteArtifact(inputPNGFingerprint:"input",alphaURL:mask,alphaFingerprint:AIFileValidation.hash(mask.path),cutoutURL:cutout,cutoutFingerprint:AIFileValidation.hash(cutout.path),orientation:1,pixelSize:CGSize(width:2,height:2))
        let transaction: [String: Any] = ["sourceVersion":try AIFileValidation.hash(source.path),"result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(prepared)),"matte":try JSONSerialization.jsonObject(with:JSONEncoder().encode(matte))]
        let ownership: [String: Any] = ["owner":owner.uuidString,"pendingInstall":transaction]
        let record = document.appendingPathExtension("workflow-owner.json")
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        let encodedRoles = String(decoding:try JSONEncoder().encode(roles),as:UTF8.self)
        let metadata = "{\"width\":2,\"height\":2,\"profile\":\"AdobeRGB\",\"summary\":\"roles\",\"roles\":\(encodedRoles),\"originX\":0,\"originY\":0,\"extentWidth\":2,\"extentHeight\":2}"
        let lease = PhotoshopExecutionCoordinator(),calls = Gate()
        let resultOwnership: [String:Any] = ["owner":owner.uuidString,"roles":try JSONSerialization.jsonObject(with:JSONEncoder().encode(roles))]
        try JSONSerialization.data(withJSONObject:resultOwnership).write(to:result.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace:directory,coordinator:lease,scriptRunner:{ script in
            if script.contains("copy.mergeVisibleLayers()") { await calls.append(2) }
            if script.contains("base.png") {
                await calls.append(1)
                let regex = try NSRegularExpression(pattern:#"wfRolePNG\(copy,("[^"]*/base\.png")\)"#)
                guard let match=regex.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range=Range(match.range(at:1),in:script) else { throw WorkflowBridgeError.invalidStructure }
                let destination = try JSONDecoder().decode(String.self,from:Data(script[range].utf8))
                let folder=URL(fileURLWithPath:destination).deletingLastPathComponent()
                for name in ["base.png","mask.png","cutout.png"] { try FileManager.default.copyItem(at:fixtures.appendingPathComponent(name),to:folder.appendingPathComponent(name)) }
            }
            if !script.contains("base.png"),try Data(contentsOf:document) == Data("old-stack".utf8) {
                return "{\"width\":2,\"height\":2,\"profile\":\"AdobeRGB\",\"summary\":\"stack\"}"
            }
            return metadata
        })
        _ = try await bridge.extractRoles(snapshot:prepared)
        let recovered = try await bridge.refreshSavedPSD(document:document,owner:owner)
        XCTAssertEqual(recovered.roles,roles);XCTAssertEqual(recovered.contentVersion,prepared.contentVersion)
        let finalized = try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        XCTAssertNotNil(finalized["roles"]);XCTAssertNil(finalized["pendingInstall"])
        XCTAssertEqual(try Data(contentsOf:source),Data("old-stack".utf8))
        // A foreign changed file cannot be recovered from even a genuine pending result record.
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        try Data("foreign-unrecorded-result".utf8).write(to:document)
        await rejects { _ = try await bridge.refreshSavedPSD(document:document,owner:owner) }
        // Removing the transaction must not relax normal role validation.
        try JSONSerialization.data(withJSONObject:["owner":owner.uuidString]).write(to:record)
        try Data("installed-matte".utf8).write(to:document)
        await rejects { _ = try await bridge.refreshSavedPSD(document:document,owner:owner) }
        // A prepared but unpublished result cannot write through a manual saved-read lease.
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        try Data("old-stack".utf8).write(to:document)
        try await lease.beginManualEditing(owner:owner)
        let unchanged = try await bridge.refreshSavedPSD(document:document,owner:owner)
        XCTAssertNil(unchanged.roles);XCTAssertEqual(try Data(contentsOf:document),Data("old-stack".utf8))
        let stillPending = try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        XCTAssertNotNil(stillPending["pendingInstall"])
        await lease.endManualEditing(owner:owner)
        let resumed = try await bridge.installMatte(snapshot:unchanged,matte:matte)
        XCTAssertEqual(resumed.roles,roles);XCTAssertEqual(resumed.contentVersion,prepared.contentVersion)
        _ = try await bridge.extractRoles(snapshot:resumed)
        let operations = await calls.values()
        XCTAssertEqual(operations,[1],"Both publication checkpoints reuse the prepared extraction and never reinstall")
    }
    func testGeometryRequiresExplicitPivotInSavedSourceFrame() throws {
        let solution = GeometrySolution(sourceVersion: "current-saved", angleDegrees: 7, rotationPivot: CGPoint(x: 17,y: 31),
            leftWingTip: CGPoint(x: 1,y: 2), rightWingTip: CGPoint(x: 5,y: 4), subjectBounds: CGRect(x: -8,y: -3,width: 40,height: 20),
            sourceCropRect: CGRect(x: -9,y: -4,width: 50,height: 30), outputSize: CGSize(width: 50,height: 30),
            actualMargins: WorkflowMargins(left: 0.1,top: 0.1,right: 0.1,bottom: 0.1), isApplicable: true)
        let encoded = try JSONEncoder().encode(solution)
        XCTAssertEqual(try JSONDecoder().decode(GeometrySolution.self, from: encoded), solution)
        var missing = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        missing.removeValue(forKey: "rotationPivot")
        XCTAssertThrowsError(try JSONDecoder().decode(GeometrySolution.self, from: JSONSerialization.data(withJSONObject: missing)))
    }
    func testSavedRefreshAndRepeatedExtractionReuseVerifiedRolesAcrossBridgeInstances() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: saved)
        let reopened = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let refreshed = try await reopened.refreshSavedPSD(document: f.document,owner: f.owner)
        let second = try await reopened.extractRoles(snapshot: refreshed)
        XCTAssertEqual(first,second)
        let extractions = await f.calls.values()
        XCTAssertEqual(extractions.count,1,"Refreshing and exporting an unchanged PSD must not re-export intermediate PNGs")
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
    }
    func testCachedExtractionInspectsOnceAndRejectsDeletedRolesOrSavingSource() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let expected = try await bridge.extractRoles(snapshot: saved), calls = Gate()
        let reopened = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            await calls.append(1)
            return try await f.runner(script)
        })
        let actual = try await reopened.extractRoles(snapshot: saved)
        XCTAssertEqual(actual,expected)
        let inspections = await calls.values(), exports = await f.calls.values()
        XCTAssertEqual(inspections,[1],"A warm confirmation read needs exactly one Photoshop inspection")
        XCTAssertEqual(exports,[1],"The initial cache population is the only role export")
        let deleted = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            let result = try await f.runner(script)
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String:Any])
            metadata.removeValue(forKey: "roles")
            return String(decoding: try JSONSerialization.data(withJSONObject: metadata),as: UTF8.self)
        })
        do { _ = try await deleted.extractRoles(snapshot: saved); XCTFail("Deleted role accepted on cache hit") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.invalidStructure) }
        let saving = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { script in
            let result = try await f.runner(script)
            try Data("save-in-progress".utf8).write(to: f.document)
            return result
        })
        do { _ = try await saving.extractRoles(snapshot: saved); XCTFail("Concurrent save accepted on cache hit") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.staleSource) }
        let finalExports = await f.calls.values(); XCTAssertEqual(finalExports,[1])
    }
    func testPublishedCopyReusesRoleExtractionWithoutTrustingWorkingPath() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let staged = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: staged)
        let publishedURL = f.directory.appendingPathComponent("published.psd")
        try FileManager.default.copyItem(at: f.document,to: publishedURL)
        try FileManager.default.copyItem(at: f.document.appendingPathExtension("workflow-owner.json"),to: publishedURL.appendingPathExtension("workflow-owner.json"))
        let reopened = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let published = try await reopened.refreshSavedPSD(document: publishedURL,owner: f.owner)
        let second = try await reopened.extractRoles(snapshot: published)
        XCTAssertNotEqual(staged,published,"Global snapshot identity still includes the working path")
        XCTAssertEqual(first,second,"Publication must reuse the same verified role files")
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,1)
        // A cache hit must still inspect and hash the current published document.
        try Data("changed-published-psd".utf8).write(to: publishedURL)
        await rejects { _ = try await reopened.extractRoles(snapshot: published) }
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
    }
    func testRoleReuseRejectsChangedOwnerRolesAndImmutableSnapshot() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let receipt = f.directory.appendingPathComponent("role-cache/\(f.owner)/\(saved.contentVersion).json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String:Any])
        // A readable receipt from a different extraction identity must never be accepted.
        var variants: [PSDSnapshot] = []
        var changed = saved; changed.taskID = UUID(); variants.append(changed)
        changed = saved; changed.contentVersion = "other-version"; variants.append(changed)
        changed = saved; changed.snapshotURL = f.directory.appendingPathComponent("other.psd"); variants.append(changed)
        changed = saved; changed.pixelSize.width += 1; variants.append(changed)
        changed = saved; changed.roles?.baseLayer = "99"; variants.append(changed)
        changed = saved; changed.structureSummary = "other-structure"; variants.append(changed)
        for variant in variants {
            var mismatched = original
            mismatched["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(variant))
            try JSONSerialization.data(withJSONObject: mismatched).write(to: receipt)
            let extracted = try await bridge.extractRoles(snapshot: saved)
            XCTAssertEqual(extracted.snapshotVersion,saved.contentVersion)
        }
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,7)
        // Identical PSD bytes and a copied receipt do not authorize a different owner.
        var foreign = saved; foreign.taskID = UUID()
        await rejects { _ = try await bridge.extractRoles(snapshot: foreign) }
        for variant in variants.dropFirst(3) {
            await rejects { _ = try await bridge.extractRoles(snapshot: variant) }
        }
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath: saved.snapshotURL.path)
        try Data("changed-immutable-copy".utf8).write(to: saved.snapshotURL)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        let finalExtractions = await f.calls.values(); XCTAssertEqual(finalExtractions.count,7)
    }
    func testMissingOrChangedRoleCacheIsReextracted() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: saved)
        let expectedMask = try Data(contentsOf: first.maskPNG)
        try Data("damaged-mask".utf8).write(to: first.maskPNG)
        let repaired = try await bridge.extractRoles(snapshot: saved)
        XCTAssertEqual(try Data(contentsOf: repaired.maskPNG),expectedMask)
        try FileManager.default.removeItem(at: repaired.cutoutPNG)
        let recovered = try await bridge.extractRoles(snapshot: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.cutoutPNG.path))
        let receipt = f.directory.appendingPathComponent("role-cache/\(f.owner)/\(saved.contentVersion).json")
        try Data("incomplete-receipt".utf8).write(to: receipt)
        _ = try await bridge.extractRoles(snapshot: saved)
        let extractions = await f.calls.values()
        XCTAssertEqual(extractions.count,4,"One initial extraction plus one per damaged image or receipt")
    }
    func testRoleCacheCannotBypassOwnershipOrSnapshotIntegrity() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let record = f.document.appendingPathExtension("workflow-owner.json"),original = try Data(contentsOf: record)
        var ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String:Any])
        ownership["owner"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ownership).write(to: record)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        try original.write(to: record)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath: saved.snapshotURL.path)
        try Data("changed-immutable-copy".utf8).write(to: saved.snapshotURL)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        await rejects { _ = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner) }
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,1)
    }
    func testRoleReuseStillRejectsUnsavedAndChangedPSD() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        _ = try await bridge.extractRoles(snapshot: saved)
        let unsaved = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { _ in throw WorkflowBridgeError.unsavedDocument })
        do { _ = try await unsaved.extractRoles(snapshot: saved); XCTFail("Unsaved PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.unsavedDocument) }
        try Data("new-saved-role-psd".utf8).write(to: f.document)
        do { _ = try await bridge.extractRoles(snapshot: saved); XCTFail("Stale snapshot accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.staleSource) }
        let changed = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let images = try await bridge.extractRoles(snapshot: changed)
        XCTAssertEqual(images.snapshotVersion,changed.contentVersion)
        XCTAssertNotEqual(changed.contentVersion,saved.contentVersion)
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,2)
    }
    // Opt-in Photoshop verification. All outputs go to a new evidence directory; source PSDs are read only.
    func testReal4KExportReuseAndPixelsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let batchPath = environment["WORKFLOW_EXPORT_BATCH"],let evidencePath = environment["WORKFLOW_EXPORT_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop export verification is opt-in")
        }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        for (index,task) in batch.activeTasks.enumerated() {
            let source = try XCTUnwrap(task.snapshot),reference = try XCTUnwrap(task.roleImages)
            let folder = evidence.appendingPathComponent(source.workingURL.deletingPathExtension().lastPathComponent)
            let calls = Gate()
            let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                if script.contains("base.png") { await calls.append(1) }
                return try await PhotoshopWorkflowBridge.execute(script)
            }
            let bridge = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
            let before = try AIFileValidation.hash(source.workingURL.path)
            let started = Date()
            let saved = try await bridge.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
            let images = try await bridge.extractRoles(snapshot: saved)
            let coldSeconds = Date().timeIntervalSince(started)
            try JSONEncoder().encode(images).write(to: folder.appendingPathComponent("roles.json"))
            try JSONEncoder().encode(reference).write(to: folder.appendingPathComponent("reference-roles.json"))
            let warmStart = Date()
            let reopened = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
            let refreshed = try await reopened.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
            let cached = try await reopened.extractRoles(snapshot: refreshed)
            let warmSeconds = Date().timeIntervalSince(warmStart)
            XCTAssertEqual(cached,images)
            let extractions = await calls.values(); XCTAssertEqual(extractions.count,1)
            XCTAssertEqual(images.pixelSize,reference.pixelSize)
            XCTAssertEqual(images.coordinateOrigin,reference.coordinateOrigin)
            for (actualURL,expectedURL) in zip([images.basePNG,images.cutoutPNG,images.maskPNG],[reference.basePNG,reference.cutoutPNG,reference.maskPNG]) {
                let actual = try WorkflowRaster.read(actualURL),expected = try WorkflowRaster.read(expectedURL)
                XCTAssertEqual(actual.size,expected.size)
                XCTAssertEqual(actual.profileName,expected.profileName)
                XCTAssertEqual(actual.profileData,expected.profileData)
                XCTAssertTrue(actual.pixels == expected.pixels,"Changed pixels: \(actualURL.lastPathComponent)")
            }
            let output = folder.appendingPathComponent("4k.png"),renderStart = Date()
            try WorkflowAssetRenderer().render4K(roles: images,layout: task.squareLayout,destination: output)
            let renderSeconds = Date().timeIntervalSince(renderStart)
            let published = try XCTUnwrap(task.artifacts.last { $0.kind == .png4k && $0.state == .completed })
            XCTAssertTrue(try WorkflowRaster.read(output).pixels == WorkflowRaster.read(published.url).pixels,"Final 4K pixels changed")
            XCTAssertEqual(try AIFileValidation.hash(source.workingURL.path),before)
            var summary: [String:Any] = ["coldRefreshAndExtractSeconds":coldSeconds,"cachedRefreshAndExtractSeconds":warmSeconds,
                "render4KSeconds":renderSeconds,"roleExtractions":extractions.count,"publishedReference":published.url.path]
            if index == 0 {
                let legacy = PhotoshopWorkflowBridge(workspace: folder.appendingPathComponent("legacy"),scriptRunner: { script in
                    let old = script.replacingOccurrences(of: "wfRolePNG(copy,",with: "wfPNG(copy,")
                        .replacingOccurrences(of: "wfRolePNG(mask,",with: "wfPNG(mask,")
                    return try await PhotoshopWorkflowBridge.execute(old)
                })
                let baselineStart = Date()
                let baseline = try await legacy.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
                let legacyImages = try await legacy.extractRoles(snapshot: baseline)
                summary["saveForWebRefreshAndExtractSeconds"] = Date().timeIntervalSince(baselineStart)
                try JSONEncoder().encode(legacyImages).write(to: folder.appendingPathComponent("legacy-roles.json"))
            }
            try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
        }
    }
    // Exercise only disposable PSD copies; the supplied batch and its original assets remain read-only.
    func testRealPublishedCopyRoleReuseWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let batchPath = environment["WORKFLOW_ROLE_PUBLICATION_BATCH"],
              let evidencePath = environment["WORKFLOW_ROLE_PUBLICATION_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop publication reuse verification is opt-in")
        }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        for repetition in 1...3 {
            for task in batch.activeTasks {
                let source = try XCTUnwrap(task.snapshot)
                let folder = evidence.appendingPathComponent("run-\(repetition)/\(source.workingURL.deletingPathExtension().lastPathComponent)")
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                let stagedURL = folder.appendingPathComponent("staged.psd"),publishedURL = folder.appendingPathComponent("published.psd")
                XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
                try FileManager.default.copyItem(at: source.snapshotURL,to: stagedURL)
                let ownership: [String:Any] = ["owner":source.taskID.uuidString,
                    "roles":try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(source.roles)))]
                let record = try JSONSerialization.data(withJSONObject: ownership)
                try record.write(to: stagedURL.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
                let calls = Gate()
                let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                    if script.contains("wfRolePNG(copy,") { await calls.append(1) }
                    return try await PhotoshopWorkflowBridge.execute(script)
                }
                let bridge = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                let started = Date()
                let staged = try await bridge.refreshSavedPSD(document: stagedURL,owner: source.taskID)
                let first = try await bridge.extractRoles(snapshot: staged)
                let firstSeconds = Date().timeIntervalSince(started)
                try FileManager.default.copyItem(at: stagedURL,to: publishedURL)
                try record.write(to: publishedURL.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
                let publishedStart = Date()
                let reopened = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                let published = try await reopened.refreshSavedPSD(document: publishedURL,owner: source.taskID)
                let second = try await reopened.extractRoles(snapshot: published)
                let publishedSeconds = Date().timeIntervalSince(publishedStart)
                let count = await calls.values().count
                try JSONEncoder().encode(first).write(to: folder.appendingPathComponent("staged-roles.json"))
                try JSONEncoder().encode(second).write(to: folder.appendingPathComponent("published-roles.json"))
                let summary: [String:Any] = ["firstRefreshAndExtractSeconds":firstSeconds,
                    "publishedRefreshAndExtractSeconds":publishedSeconds,"roleExtractions":count,
                    "sourceVersion":source.contentVersion]
                try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
                XCTAssertEqual(count,1)
                XCTAssertEqual(first,second)
                XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
                XCTAssertEqual(try AIFileValidation.hash(publishedURL.path),source.contentVersion)
            }
        }
    }
    // Measure the confirmation read separately from the older refresh + extract benchmark.
    func testRealConfirmationRoleReadWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let batchPath = environment["WORKFLOW_CONFIRMATION_BATCH"],let evidencePath = environment["WORKFLOW_CONFIRMATION_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop confirmation read verification is opt-in")
        }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        for task in batch.activeTasks {
            let source = try XCTUnwrap(task.snapshot)
            let folder = evidence.appendingPathComponent(source.workingURL.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let document = folder.appendingPathComponent("fixture.psd")
            XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
            try FileManager.default.copyItem(at: source.snapshotURL,to: document)
            let ownership: [String:Any] = ["owner":source.taskID.uuidString,
                "roles":try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(source.roles)))]
            try JSONSerialization.data(withJSONObject: ownership).write(to: document.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
            let calls = Gate()
            let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                await calls.append(script.contains("wfRolePNG(copy,") ? 2 : 1)
                return try await PhotoshopWorkflowBridge.execute(script)
            }
            let bridge = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
            let coldStart = Date()
            let saved = try await bridge.refreshSavedPSD(document: document,owner: source.taskID)
            let initial = try await bridge.extractRoles(snapshot: saved)
            let coldSeconds = Date().timeIntervalSince(coldStart)
            let urls = [initial.basePNG,initial.cutoutPNG,initial.maskPNG]
            let hashes = try urls.map { try AIFileValidation.hash($0.path) }
            try JSONEncoder().encode(initial).write(to: folder.appendingPathComponent("roles.json"))
            try JSONEncoder().encode(XCTUnwrap(task.roleImages)).write(to: folder.appendingPathComponent("reference-roles.json"))
            var runs: [[String:Any]] = []
            for repetition in 1...3 {
                var row: [String:Any] = ["repetition":repetition]
                for legacy in (repetition % 2 == 1 ? [true,false] : [false,true]) {
                    let startCalls = await calls.values().count, start = Date()
                    let reopened = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                    let current: RoleImages
                    if legacy {
                        let refreshed = try await reopened.refreshSavedPSD(document: document,owner: source.taskID)
                        XCTAssertEqual(refreshed,saved)
                        current = try await reopened.extractRoles(snapshot: refreshed)
                    } else {
                        current = try await reopened.extractRoles(snapshot: saved)
                    }
                    let seconds = Date().timeIntervalSince(start)
                    let operations = Array((await calls.values()).dropFirst(startCalls))
                    let key = legacy ? "cachedRefreshAndExtract" : "confirmationSingleExtract"
                    row[key + "Seconds"] = seconds
                    row[key + "Inspections"] = operations.filter { $0 == 1 }.count
                    row[key + "RoleExports"] = operations.filter { $0 == 2 }.count
                    XCTAssertEqual(operations,Array(repeating: 1,count: legacy ? 3 : 1))
                    XCTAssertEqual(current,initial)
                    XCTAssertEqual(try urls.map { try AIFileValidation.hash($0.path) },hashes,"Raw PNG bytes, including ICC and transparent RGB, must remain identical")
                }
                runs.append(row)
            }
            let summary: [String:Any] = ["coldRefreshAndExtractSeconds":coldSeconds,"runs":runs,"roleHashes":hashes,"sourceVersion":source.contentVersion]
            try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
            XCTAssertEqual(try AIFileValidation.hash(document.path),source.contentVersion)
            XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
        }
    }
    // Opt-in: un-matted stacks, including a soft-alpha foreground over a blue preview-only layer.
    func testRealStackInputFastPNGPreservesPixelsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let evidencePath = environment["WORKFLOW_PNG_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop stack PNG verification is opt-in")
        }
        let evidence = URL(fileURLWithPath: evidencePath)
        let python = try XCTUnwrap(environment["WORKFLOW_PNG_PYTHON"],"Set WORKFLOW_PNG_PYTHON to the AI project's Python with Pillow")
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        func quoted(_ url: URL) throws -> String { String(decoding: try JSONEncoder().encode(url.path),as: UTF8.self) }
        let foreground = evidence.appendingPathComponent("soft-alpha.png")
        try png(foreground,width:5,height:1,pixels:[12,34,56,0,23,45,67,1,99,88,77,64,90,80,70,128,255,128,1,255])
        var fixtures: [(String,URL)] = []
        for (label,bits,srgb) in [("srgb-8",8,true),("adobe-8",8,false),("srgb-16",16,true)] {
            let document = evidence.appendingPathComponent("soft-alpha-\(label).psd")
            _ = try await PhotoshopWorkflowBridge.execute("""
                (function(){
                    var doc=app.open(new File(\(try quoted(foreground))));
                    try {
                        if(\(srgb ? "true" : "false"))doc.convertProfile('sRGB IEC61966-2.1',Intent.RELATIVECOLORIMETRIC,true,false);
                        if(\(bits)===16)doc.bitsPerChannel=BitsPerChannelType.SIXTEEN;
                        var subject=doc.activeLayer,blue=doc.artLayers.add();blue.name='Background #74BFFF';
                        var color=new SolidColor();color.rgb.red=116;color.rgb.green=191;color.rgb.blue=255;
                        doc.selection.selectAll();doc.selection.fill(color);doc.selection.deselect();
                        blue.move(subject,ElementPlacement.PLACEAFTER);blue.visible=true;
                        var options=new PhotoshopSaveOptions();options.layers=true;options.embedColorProfile=true;
                        doc.saveAs(new File(\(try quoted(document))),options,true,Extension.LOWERCASE);
                        return 'created';
                    }finally{doc.close(SaveOptions.DONOTSAVECHANGES);}
                }());
                """)
            fixtures.append(("soft-alpha-\(label)",document))
        }
        if let fixturePath = environment["WORKFLOW_STACK_FIXTURES"] {
            let records = try JSONDecoder().decode([[String:String]].self,from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
            for record in records {
                fixtures.append((try XCTUnwrap(record["name"]),URL(fileURLWithPath: try XCTUnwrap(record["source"]))))
            }
        }
        for (name,source) in fixtures {
            let sourceHash = try AIFileValidation.hash(source.path)
            let folder = evidence.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let document = folder.appendingPathComponent("stack.psd"),owner = UUID()
            try FileManager.default.copyItem(at: source,to: document)
            try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
            let bridge = PhotoshopWorkflowBridge(workspace: folder,coordinator: PhotoshopExecutionCoordinator())
            let snapshot = try await bridge.refreshSavedPSD(document: document,owner: owner)
            XCTAssertNil(snapshot.roles,"This fixture must be an un-matted stack, not extracted roles")
            for repetition in 1...3 {
                var results: [String:Any] = [:]
                // Alternate order to reduce warm-cache bias; both exports read the same immutable PSD.
                for mode in repetition.isMultiple(of:2) ? ["fast","legacy"] : ["legacy","fast"] {
                    let calls = Gate()
                    let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                        var actual = script
                        if mode == "legacy" {
                            actual = actual.replacingOccurrences(of:"wfStackPNG(copy,",with:"wfPNG(copy,")
                        }
                        // Count executed encoders, including the fast helper's mode/bit-depth fallback.
                        actual = "var wfQuickSaves=0,wfLegacySaves=0;\n" + actual
                            .replacingOccurrences(of:"function wfPNG(doc,path) {",with:"function wfPNG(doc,path) {wfLegacySaves++;")
                            .replacingOccurrences(of:"executeAction(s('save'),d,DialogModes.NO);",with:"wfQuickSaves++;executeAction(s('save'),d,DialogModes.NO);")
                            .replacingOccurrences(of:"\n(function(){",with:"\nvar wfEncodedResult=(function(){")
                        actual += "\nvar wfMeasured=eval('('+wfEncodedResult+')');wfMeasured.quickSaves=wfQuickSaves;wfMeasured.legacySaves=wfLegacySaves;wfJSON(wfMeasured);"
                        try actual.write(to:folder.appendingPathComponent("\(mode)-script.jsx"),atomically:true,encoding:.utf8)
                        let result: String
                        do { result = try await PhotoshopWorkflowBridge.execute(actual) }
                        catch { XCTFail("Photoshop \(name) \(mode): \(error)"); throw error }
                        try result.write(to:folder.appendingPathComponent("\(mode)-metadata.json"),atomically:true,encoding:.utf8)
                        let measured = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String:Any]
                        for _ in 0..<(measured?["quickSaves"] as? Int ?? 0) { await calls.append(1) }
                        for _ in 0..<(measured?["legacySaves"] as? Int ?? 0) { await calls.append(2) }
                        return result
                    }
                    let exporter = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                    let started = Date()
                    let exported = try await exporter.exportStackPNG(snapshot: snapshot)
                    let elapsed = Date().timeIntervalSince(started)
                    let encoders = await calls.values()
                    let usesQuick = mode == "fast" && name != "soft-alpha-adobe-8" && name != "soft-alpha-srgb-16"
                    XCTAssertEqual(encoders,[usesQuick ? 1 : 2],"sRGB/8-bit uses quick PNG; non-sRGB and 16-bit retain Save for Web")
                    let bytes = try Data(contentsOf: exported.pngURL).count
                    results[mode] = ["png":exported.pngURL.path,"seconds":elapsed,"bytes":bytes,
                                     "orientation":exported.orientation,"encoders":encoders]
                }
                let legacy = try XCTUnwrap(results["legacy"] as? [String:Any])
                let fast = try XCTUnwrap(results["fast"] as? [String:Any])
                let expected = try WorkflowRaster.read(URL(fileURLWithPath: XCTUnwrap(legacy["png"] as? String)))
                let actual = try WorkflowRaster.read(URL(fileURLWithPath: XCTUnwrap(fast["png"] as? String)))
                XCTAssertEqual(actual.size,expected.size)
                XCTAssertEqual(actual.orientation,expected.orientation)
                XCTAssertEqual(actual.profileData,expected.profileData)
                XCTAssertTrue(actual.pixels == expected.pixels)
                if name.hasPrefix("soft-alpha-") {
                    XCTAssertEqual(stride(from:3,to:actual.pixels.count,by:4).map { actual.pixels[$0] },[0,1,64,128,255],"Preview blue must be hidden; soft alpha must survive")
                }
                // Raw, unpremultiplied RGBA and all color chunks are additionally compared from these files.
                try JSONSerialization.data(withJSONObject: results,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("run-\(repetition).json"))
            }
            XCTAssertEqual(try AIFileValidation.hash(source.path),sourceHash)
            XCTAssertEqual(try AIFileValidation.hash(document.path),sourceHash)
        }
        let verifier = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/verify_workflow_png_pairs.py")
        let process = Process(),output = Pipe()
        process.executableURL = URL(fileURLWithPath:python)
        process.arguments = ["-B",verifier.path,evidence.path]
        process.standardOutput = output
        try process.run()
        let rawComparison = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try rawComparison.write(to:evidence.appendingPathComponent("raw-pixel-comparison.json"))
        XCTAssertEqual(process.terminationStatus,0,"Raw RGBA / ICC / color chunks differ: \(String(decoding:rawComparison,as:UTF8.self))")
    }
    private func roleCacheFixture() throws -> (directory: URL,document: URL,owner: UUID,runner: PhotoshopWorkflowBridge.ScriptRunner,calls: Gate) {
        let directory = try temporaryDirectory(),document = directory.appendingPathComponent("owned.psd"),owner = UUID(),calls = Gate()
        try Data("saved-role-psd".utf8).write(to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup: "1",adjustmentGroup: "2",baseLayer: "3",cutoutLayer: "4",mask: "4:userMask")
        let encodedRoles = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roles))
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,"roles":encodedRoles]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let metadata = String(decoding:try JSONSerialization.data(withJSONObject: ["width":2,"height":2,"profile":"AdobeRGB","summary":"roles","roles":encodedRoles,"originX":0,"originY":0,"extentWidth":2,"extentHeight":2]),as:UTF8.self)
        let fixtures = directory.appendingPathComponent("fixtures"); try FileManager.default.createDirectory(at: fixtures,withIntermediateDirectories: true)
        try png(fixtures.appendingPathComponent("base.png"),width:2,height:2,pixels:[255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255])
        try png(fixtures.appendingPathComponent("mask.png"),width:2,height:2,pixels:[255,255,255,255,0,0,0,255,255,255,255,255,0,0,0,255])
        try png(fixtures.appendingPathComponent("cutout.png"),width:2,height:2,pixels:[255,0,0,255,0,0,0,0,0,0,255,255,0,0,0,0])
        let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
            let regex = try NSRegularExpression(pattern:#"wfRolePNG\(copy,("[^"]*/base\.png")\)"#)
            if let match = regex.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range = Range(match.range(at:1),in:script) {
                let destination = try JSONDecoder().decode(String.self,from:Data(script[range].utf8))
                let folder = URL(fileURLWithPath:destination).deletingLastPathComponent()
                for name in ["base.png","mask.png","cutout.png"] { try FileManager.default.copyItem(at:fixtures.appendingPathComponent(name),to:folder.appendingPathComponent(name)) }
                await calls.append(1)
            }
            return metadata
        }
        return (directory,document,owner,runner,calls)
    }
    private func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Invalid output accepted") } catch {}
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkflowBridgeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func png(_ url: URL, width: Int, height: Int, pixels: [UInt8], colorSpaceName: CFString = CGColorSpace.adobeRGB1998) throws {
        let color = CGColorSpace(name: colorSpaceName)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: color, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
