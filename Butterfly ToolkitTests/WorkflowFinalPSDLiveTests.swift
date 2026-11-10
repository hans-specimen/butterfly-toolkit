// 仅在独立副本上验证 Photoshop 的最终图层读取、应用蒙版及双输出。
import XCTest
@testable import Butterfly_Toolkit

final class WorkflowFinalPSDLiveTests: XCTestCase {
    func testAffectedSavedMasksWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifestPath = env["WORKFLOW_FINAL_GEOMETRY_BATCH"],let evidencePath = env["WORKFLOW_FINAL_GEOMETRY_EVIDENCE"] else {
            throw XCTSkip("Affected real masks require explicit read-only batch and new evidence directory")
        }
        let root = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let names: [String:WorkflowSide] = ["SC10135":.back,"SC10136":.front,"SC10138":.back]
        var report: [[String:Any]] = []
        for (prefix,side) in names.sorted(by: { $0.key < $1.key }) {
            let specimen = try XCTUnwrap(batch.specimens.first { $0.baseName.hasPrefix(prefix) })
            let task = side == .front ? specimen.front : specimen.back
            let original = try XCTUnwrap(task.roleImages)
            let beforeMask = try AIFileValidation.hash(original.maskPNG.path),beforeBase = try AIFileValidation.hash(original.basePNG.path)
            let folder = root.appendingPathComponent(prefix); try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let maskURL = folder.appendingPathComponent("mask.png"),baseURL = folder.appendingPathComponent("base.png")
            try FileManager.default.copyItem(at: original.maskPNG,to: maskURL); try FileManager.default.copyItem(at: original.basePNG,to: baseURL)
            let mask = try WorkflowRaster.read(maskURL),base = try WorkflowRaster.read(baseURL)
            let raw = stride(from: 0,to: mask.pixels.count,by: 4).map { mask.pixels[$0] }
            let support = try MeaningfulMaskSupport(values: raw,width: Int(mask.size.width),height: Int(mask.size.height),origin: original.coordinateOrigin)
            let invisible = raw.indices.filter { raw[$0] > 0 && base.pixels[$0*4+3] == 0 }.count
            let prepared = try MaskGeometryProcessor().prepare(input: MaskGeometryInput(sourceVersion: original.snapshotVersion,sourcePixelSize: original.pixelSize,maskURL: maskURL,validBackgroundAlphaURL: baseURL,coordinateOrigin: original.coordinateOrigin,cropViewport: original.cropViewport))
            let solution = try prepared.analyze(request: task.geometryRequest)
            XCTAssertTrue(solution.isApplicable || solution.reason != nil)
            XCTAssertEqual(try AIFileValidation.hash(original.maskPNG.path),beforeMask)
            XCTAssertEqual(try AIFileValidation.hash(original.basePNG.path),beforeBase)
            XCTAssertEqual(try AIFileValidation.hash(maskURL.path),beforeMask)
            func rect(_ value: CGRect) -> [Double] { [value.minX,value.minY,value.width,value.height] }
            report.append(["name":specimen.baseName+"_"+side.fileSuffix,"invisibleResidue":invisible,"rawMaskBounds":rect(support.bounds),"actualAlphaBounds":rect(prepared.support.bounds),"applicable":solution.isApplicable,"reason":solution.reason ?? "","sourceUnchanged":true])
        }
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("validation.json"))
    }

    func testFinalPSDWithMaskAndAppliedMaskWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["WORKFLOW_FINAL_SOURCE"],let evidencePath = env["WORKFLOW_FINAL_EVIDENCE"] else {
            throw XCTSkip("Final PSD live test requires an isolated copy and explicit source")
        }
        let source = URL(fileURLWithPath: sourcePath),root = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let sourceHash = try AIFileValidation.hash(source.path),owner = UUID(),document = root.appendingPathComponent("final_V.psd")
        try FileManager.default.copyItem(at: source,to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],ofItemAtPath: document.path)
        // 副本独立归属；不接管或修改用户正在工作的原 PSD。
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("work"))
        let masked = try await bridge.captureFinalPSD(document: document,owner: owner)
        let maskedRoles = try await bridge.extractRoles(snapshot: masked)
        XCTAssertEqual(maskedRoles.isFinalized,true)
        let renderer = WorkflowAssetRenderer()
        try renderer.renderHD(roles: maskedRoles,destination: root.appendingPathComponent("base.jpg"))
        try renderer.render4K(roles: maskedRoles,layout: .png4k,destination: root.appendingPathComponent("masked-4k.png"))
        let path = String(decoding: try JSONEncoder().encode(document.path),as: UTF8.self)
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("""
            var d=app.open(new File(\(path)));
            try {
                var g=d.layerSets.getByName('共同调整'),top=null;
                for(var i=0;i<g.layers.length;i++)if(g.layers[i].name!=='底图'&&g.layers[i].visible){top=g.layers[i];break;}
                if(!top)throw new Error('Missing fixture cutout');
                var finished=top.duplicate();finished.move(top,ElementPlacement.PLACEBEFORE);finished.name='人工最终透明图';d.activeLayer=finished;
                var lr=new ActionReference();lr.putIdentifier(charIDToTypeID('Lyr '),finished.id);var ld=executeActionGet(lr);
                if(ld.hasKey(stringIDToTypeID('hasUserMask'))&&ld.getBoolean(stringIDToTypeID('hasUserMask'))){
                    var ref=new ActionReference();ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));
                    var desc=new ActionDescriptor();desc.putReference(charIDToTypeID('null'),ref);desc.putBoolean(charIDToTypeID('Aply'),true);
                    executeAction(charIDToTypeID('Dlt '),desc,DialogModes.NO);
                }
                // 留下可见的旧蒙版层，导出仍必须只读取最上面的最终图层。
                top.visible=true;g.artLayers.getByName('底图').visible=false;
                d.save();
            } finally { d.close(SaveOptions.DONOTSAVECHANGES); }
            """)
        }
        let applied = try await bridge.captureFinalPSD(document: document,owner: owner)
        XCTAssertNotEqual(applied.finalRoles?.cutoutLayer,masked.finalRoles?.cutoutLayer)
        XCTAssertNotEqual(applied.contentVersion,masked.contentVersion)
        let appliedRoles = try await bridge.extractRoles(snapshot: applied)
        try renderer.render4K(roles: appliedRoles,layout: .png4k,destination: root.appendingPathComponent("applied-4k.png"))
        let before = try WorkflowRaster.read(root.appendingPathComponent("masked-4k.png")),after = try WorkflowRaster.read(root.appendingPathComponent("applied-4k.png"))
        XCTAssertEqual(after.size,CGSize(width: 4096,height: 4096)); XCTAssertEqual(before.pixels,after.pixels)
        do { _ = try await bridge.extractRoles(snapshot: masked); XCTFail("Stale PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.staleSource) }

        // 在测试副本擦除主体中心像素并裁切画布，刷新和导出不得重建成品覆盖这些修改。
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("""
            var d=app.open(new File(\(path)));
            try {
                var g=d.layerSets.getByName('共同调整'),layer=g.artLayers.getByName('人工最终透明图');d.activeLayer=layer;
                var w=d.width.as('px'),h=d.height.as('px'),cx=Math.floor(w/2),cy=Math.floor(h/2);
                d.selection.select([[cx-3,cy-3],[cx+3,cy-3],[cx+3,cy+3],[cx-3,cy+3]]);
                d.selection.clear();d.selection.deselect();
                d.crop([UnitValue(5,'px'),UnitValue(5,'px'),UnitValue(w-5,'px'),UnitValue(h-5,'px')]);
                d.save();
            } finally { d.close(SaveOptions.DONOTSAVECHANGES); }
            """)
        }
        let editedHash = try AIFileValidation.hash(document.path)
        let edited = try await bridge.captureFinalPSD(document: document,owner: owner)
        let editedRoles = try await bridge.extractRoles(snapshot: edited)
        XCTAssertEqual(edited.pixelSize,CGSize(width: applied.pixelSize.width-10,height: applied.pixelSize.height-10))
        let editedRaster = try WorkflowRaster.read(editedRoles.cutoutPNG)
        let center = (Int(editedRaster.size.height)/2*Int(editedRaster.size.width)+Int(editedRaster.size.width)/2)*4+3
        XCTAssertEqual(editedRaster.pixels[center],0)
        try renderer.render4K(roles: editedRoles,layout: .png4k,destination: root.appendingPathComponent("manually-edited-4k.png"))
        try renderer.renderHD(roles: editedRoles,destination: root.appendingPathComponent("manually-cropped-base.jpg"))
        XCTAssertEqual(try WorkflowRaster.read(root.appendingPathComponent("manually-edited-4k.png")).size,CGSize(width: 4096,height: 4096))
        XCTAssertEqual(try AIFileValidation.hash(document.path),editedHash)
        let savedHash = try AIFileValidation.hash(document.path)
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("var d=app.open(new File(\(path)));d.layerSets.getByName('共同调整').name='未保存修改';")
        }
        do { _ = try await bridge.captureFinalPSD(document: document,owner: owner); XCTFail("Unsaved PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.unsavedDocument) }
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("var f=new File(\(path));for(var i=app.documents.length-1;i>=0;i--){var d=app.documents[i];if(d.fullName.fsName===f.fsName)d.close(SaveOptions.DONOTSAVECHANGES);}")
        }
        XCTAssertEqual(try AIFileValidation.hash(document.path),savedHash)
        XCTAssertEqual(try AIFileValidation.hash(source.path),sourceHash)
        let result: [String:Any] = ["sourceUnchanged":true,"maskedAndAppliedPixelsEqual":true,"pngWidth":4096,"pngHeight":4096,"manualPixelsAndCropPreserved":true,"savedVersionChecked":true,"unsavedRejected":true,"workingPSD":document.path]
        try JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("validation.json"))
    }
}
