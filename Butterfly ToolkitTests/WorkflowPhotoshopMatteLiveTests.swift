// 在全新素材副本上验证原生识别、可编辑蒙版、子目录和最终双输出；默认不操作 Photoshop。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPhotoshopMatteLiveTests: XCTestCase {
    func testPhotoshopPipelineWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["WORKFLOW_PS_BATCH"], let evidence = env["WORKFLOW_PS_EVIDENCE"] else {
            throw XCTSkip("Photoshop subject selection requires explicit batch and new evidence directory")
        }
        let root = try WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(evidence)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        let originalURL = URL(fileURLWithPath: manifest), manifestHash = try AIFileValidation.hash(manifest)
        let original = try JSONDecoder().decode(WorkflowBatch.self, from: Data(contentsOf: originalURL))
        let prefixes = (env["WORKFLOW_PS_NAMES"] ?? "SC10140").split(separator: ",").map(String.init)
        let selected = try prefixes.map { prefix in try XCTUnwrap(original.specimens.first { $0.baseName.hasPrefix(prefix) }) }
        let source = root.appendingPathComponent("素材副本"), workspace = root.appendingPathComponent("batch")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        var originals: [URL:String] = [:]
        var groups: [WorkflowDraftGroup] = []
        for specimen in selected {
            let inputs = specimen.front.sources.files + specimen.back.sources.files
            XCTAssertEqual(inputs.count, 6)
            let copies = try inputs.enumerated().map { index, input -> URL? in
                let fingerprint = try AIFileValidation.hash(input.url.path)
                XCTAssertEqual(fingerprint, input.fingerprint)
                originals[input.url] = fingerprint
                let copy = source.appendingPathComponent("\(specimen.baseName.prefix(7))_\(index).JPG")
                try fm.copyItem(at: input.url, to: copy)
                return copy
            }
            groups.append(WorkflowDraftGroup(files: copies))
        }
        let draft = WorkflowBatchDraft(directory: source, groups: groups, remainder: [], otherFiles: [])
        let batch = try draft.freeze(names: selected.map(\.baseName).joined(separator: "\n"), output: workspace,
            checkStack: false, checkMatte: false, manualFinalization: true)
        XCTAssertEqual(batch.effectiveMatteProvider, .photoshop)
        let bridge = PhotoshopWorkflowBridge(workspace: workspace.appendingPathComponent(".work"))
        var services = WorkflowExecutor.Services.live(bridge: bridge, matte: WorkflowMatteService(engine: root.appendingPathComponent("no-engine"), workspace: workspace))
        services.infer = { _ in XCTFail("PS path invoked external AI"); throw WorkflowStateError.invalidTransition }
        services.exportStack = { _ in XCTFail("PS path exported AI input"); throw WorkflowStateError.invalidTransition }
        services.install = { _,_ in XCTFail("PS path installed AI matte"); throw WorkflowStateError.invalidTransition }
        let select = try XCTUnwrap(services.selectSubject)
        services.selectSubject = { snapshot in
            let path = String(decoding: try JSONEncoder().encode(snapshot.workingURL.path), as: UTF8.self)
            let stackBackground = try await PhotoshopExecutionCoordinator.shared.run(owner: snapshot.taskID) {
                try await PhotoshopWorkflowBridge.execute("""
                (function(){var d=app.open(new File(\(path)));try{
                    var bg=d.layers[d.layers.length-1];
                    return String(bg.name==='BG' && bg.typename==='ArtLayer' && bg.visible && bg.allLocked);
                }finally{d.close(SaveOptions.DONOTSAVECHANGES);}}());
                """)
            }
            XCTAssertEqual(stackBackground, "true", "Stack output must already have a locked visible bottom BG")
            let result = try await select(snapshot)
            try JSONEncoder().encode(result).write(to: root.appendingPathComponent("\(snapshot.taskID)-selected.json"))
            return result
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch, manifestURL: workspace.appendingPathComponent("batch.json"))
        try await executor.runPending(batchID: batch.id)
        let processed = try await executor.batch(batchID: batch.id)
        try JSONEncoder().encode(processed).write(to: root.appendingPathComponent("processed.json"))
        for task in processed.activeTasks {
            XCTAssertEqual(task[.matte].state, .completed, task[.matte].error ?? "")
            XCTAssertEqual(task[.geometry].state, .waitingReview, task[.geometry].error ?? "")
            XCTAssertNil(task.matteArtifact); XCTAssertNil(task.stackPNG)
            let saved = try XCTUnwrap(task.snapshot)
            XCTAssertEqual(saved.workingURL.deletingLastPathComponent(), batch.generatedPSDDirectory)
            XCTAssertTrue(task.geometrySolution?.isApplicable == true, task.geometrySolution?.reason ?? "No geometry")
            let path = String(decoding: try JSONEncoder().encode(saved.workingURL.path), as: UTF8.self)
            let maskCheck = try await PhotoshopExecutionCoordinator.shared.run(owner: task.id) {
                try await PhotoshopWorkflowBridge.execute("""
                (function(){var d=app.open(new File(\(path)));try{
                    var a=d.layerSets.getByName('共同调整'),c=a.artLayers.getByName('抠图');
                    d.activeLayer=c;var r=new ActionReference();r.putProperty(charIDToTypeID('Prpr'),stringIDToTypeID('hasUserMask'));
                    r.putEnumerated(charIDToTypeID('Lyr '),charIDToTypeID('Ordn'),charIDToTypeID('Trgt'));
                    var editable=a.layers.length===2 && c.visible && executeActionGet(r).getBoolean(stringIDToTypeID('hasUserMask'));
                    var bg=d.layers[d.layers.length-1];
                    return String(editable && d.layers.length===3 && bg.name==='BG' && bg.typename==='ArtLayer' && bg.visible && bg.allLocked);
                }finally{d.close(SaveOptions.DONOTSAVECHANGES);}}());
                """)
            }
            XCTAssertEqual(maskCheck, "true", "Editable mask and locked visible root BG must remain after geometry")
        }
        // 仅在副本修改蒙版中心一个像素，确认保存刷新读取蒙版而非隐藏的旧成品。
        let task = try XCTUnwrap(processed.activeTasks.first), saved = try XCTUnwrap(task.snapshot)
        let finalBefore = try await bridge.captureFinalPSD(document: saved.workingURL, owner: task.id)
        let rolesBefore = try await bridge.extractRoles(snapshot: finalBefore)
        let raster = try WorkflowRaster.read(rolesBefore.cutoutPNG), w = Int(raster.size.width), h = Int(raster.size.height)
        let candidates = stride(from: 0, to: raster.pixels.count, by: 4).filter { raster.pixels[$0+3] > 240 }
        let offset = try XCTUnwrap(candidates.min { a,b in
            abs(a/4%w-w/2)+abs(a/4/w-h/2) < abs(b/4%w-w/2)+abs(b/4/w-h/2)
        })
        let x = offset/4%w, y = offset/4/w
        let path = String(decoding: try JSONEncoder().encode(saved.workingURL.path), as: UTF8.self)
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: task.id) {
            try await PhotoshopWorkflowBridge.execute("""
            (function(){var d=app.open(new File(\(path)));try{
                d.activeLayer=d.layerSets.getByName('共同调整').artLayers.getByName('抠图');
                var r=new ActionReference(),a=new ActionDescriptor();
                r.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));a.putReference(charIDToTypeID('null'),r);
                executeAction(charIDToTypeID('slct'),a,DialogModes.NO);
                d.selection.select([[\(x),\(y)],[\(x+1),\(y)],[\(x+1),\(y+1)],[\(x),\(y+1)]]);
                var black=new SolidColor();black.rgb.red=0;black.rgb.green=0;black.rgb.blue=0;d.selection.fill(black);d.selection.deselect();d.save();
                return 'saved';
            }finally{d.close(SaveOptions.DONOTSAVECHANGES);}}());
            """)
        }
        try await executor.refreshFinalPSD(batchID: batch.id, taskID: task.id)
        let edited = try await executor.batch(batchID: batch.id)
        let editedRoles = try XCTUnwrap(edited.task(id: task.id)?.roleImages)
        XCTAssertEqual(try WorkflowRaster.read(editedRoles.cutoutPNG).pixels[offset+3], 0)
        try await executor.confirmFinalPSD(batchID: batch.id, specimenIDs: Set(batch.specimens.map(\.id)))
        try await executor.confirm4K(batchID: batch.id, layouts: Dictionary(uniqueKeysWithValues: batch.activeTasks.map { ($0.id,SquareLayout.png4k) }))
        let finished = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(finished.activeTasks.allSatisfy { $0[.hd].state == .completed && $0[.png4k].state == .completed })
        for task in finished.activeTasks {
            for asset in task.artifacts where asset.kind == .png4k {
                let exported = try WorkflowRaster.read(asset.url)
                XCTAssertEqual(exported.size, CGSize(width: 4096,height: 4096))
                XCTAssertEqual(exported.pixels[3], 0, "Preview BG must not enter transparent exports")
            }
        }
        XCTAssertEqual(try AIFileValidation.hash(manifest), manifestHash)
        for (url,hash) in originals { XCTAssertEqual(try AIFileValidation.hash(url.path),hash) }
        try JSONEncoder().encode(finished).write(to: root.appendingPathComponent("finished.json"))
        try JSONSerialization.data(withJSONObject: ["faces":finished.activeTasks.count,"nativeMaskEditable":true,"manualMaskRefresh":true,"sourceUnchanged":true], options: .prettyPrinted).write(to: root.appendingPathComponent("validation.json"))
    }
}
