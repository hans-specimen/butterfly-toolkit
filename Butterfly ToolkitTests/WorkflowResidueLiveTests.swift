// 在独立素材副本上回放已有 AI 蒙版，验证默认成品的实际边界与可编辑备份。
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

final class WorkflowResidueLiveTests: XCTestCase {
    func testSavedMatteReplayThroughPhotoshopWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["WORKFLOW_RESIDUE_BATCH"],let evidence = env["WORKFLOW_RESIDUE_EVIDENCE"] else { throw XCTSkip("Requires explicit read-only source batch and new evidence directory") }
        let root = URL(fileURLWithPath: evidence)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        let requestedName = env["WORKFLOW_RESIDUE_NAME"],requestedSide = env["WORKFLOW_RESIDUE_SIDE"]
        let specimens = batch.specimens.filter { requestedName == nil || $0.baseName == requestedName || $0.baseName.hasPrefix(requestedName!+"_") }
        XCTAssertFalse(specimens.isEmpty)
        for specimen in specimens {
            for task in [specimen.front,specimen.back] where requestedSide == nil || task.side.fileSuffix == requestedSide {
                let directory = root.appendingPathComponent(specimen.baseName+"_"+task.side.fileSuffix)
                try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
                try await replay(task: task,root: directory)
            }
        }
    }

    private func replay(task: WorkflowSideTask,root: URL) async throws {
        let source = try XCTUnwrap(task.roleImages)
        let originals = [source.basePNG,source.maskPNG,source.cutoutPNG,try XCTUnwrap(task.snapshot?.workingURL)]
        let hashes = try originals.map { try AIFileValidation.hash($0.path) }
        let base = root.appendingPathComponent("base.png"),mask = root.appendingPathComponent("mask.png"),document = root.appendingPathComponent("copy_V.psd")
        try FileManager.default.copyItem(at: source.basePNG,to: base); try FileManager.default.copyItem(at: source.maskPNG,to: mask)
        func quote(_ url: URL) throws -> String { String(decoding: try JSONEncoder().encode(url.path),as: UTF8.self) }
        let owner = UUID(),basePath = try quote(base),docPath = try quote(document)
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("var d=app.open(new File(\(basePath)));try{var o=new PhotoshopSaveOptions();o.layers=true;d.saveAs(new File(\(docPath)),o,true,Extension.LOWERCASE);}finally{d.close(SaveOptions.DONOTSAVECHANGES);}")
        }
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("work"))
        let snapshot = try await bridge.adoptStack(source: WorkflowSourceFile(url: document,fingerprint: AIFileValidation.hash(document.path)),owner: owner)
        let input = try await bridge.exportStackPNG(snapshot: snapshot)
        let rawCutout = root.appendingPathComponent("raw-cutout.png")
        try Self.makeReplay(input: input.pngURL,mask: mask,output: rawCutout)
        try JSONSerialization.data(withJSONObject: ["inputSha256":input.fingerprint]).write(to: root.appendingPathComponent("result.json"))
        let event = AIEvent(event: "completed",input: input.pngURL.path,prediction: rawCutout.path,predictionAlpha: mask.path)
        let matte: MatteArtifact
        do { matte = try await WorkflowMatteService(engine: root,workspace: root.appendingPathComponent("work"),run: { _ in event }).infer(input: input) }
        catch { XCTFail("Replay inference: \(String(reflecting: error))"); return }
        let before = try WorkflowRaster.read(mask),after = try WorkflowRaster.read(matte.alphaURL)
        let removed = stride(from:0,to:before.pixels.count,by:4).filter { before.pixels[$0]>0 && after.pixels[$0]==0 }
        let cleanup = try XCTUnwrap(matte.validatedCleanupReport())
        XCTAssertEqual(cleanup.removedPixelCount,removed.count)
        XCTAssertTrue(stride(from: 0,to: after.pixels.count,by: 4).allSatisfy { after.pixels[$0] == 0 || after.pixels[$0] == before.pixels[$0] },"Retained alpha must be unchanged")
        try JSONEncoder().encode(cleanup).write(to: root.appendingPathComponent("cleanup-report.json"))
        let installed = try await bridge.installMatte(snapshot: snapshot,matte: matte,createFinishedLayer: true)
        let roles = try await bridge.extractRoles(snapshot: installed)
        let solution = try MaskGeometryProcessor().analyze(input: MaskGeometryInput(sourceVersion: roles.snapshotVersion,sourcePixelSize: roles.pixelSize,maskURL: roles.maskPNG,validBackgroundAlphaURL: roles.basePNG,coordinateOrigin: roles.coordinateOrigin,cropViewport: roles.cropViewport),request: GeometryRequest())
        guard solution.isApplicable else {
            try JSONEncoder().encode(solution).write(to: root.appendingPathComponent("unapplied-geometry.json"))
            XCTFail("Automatic crop unapplied: \(solution.reason ?? "") at \(root.lastPathComponent)"); return
        }
        let applied = try await bridge.applyGeometry(snapshot: installed,solution: solution,createFinishedLayer: true)
        let savedRoles = try await bridge.extractRoles(snapshot: applied)
        let raster = try WorkflowRaster.read(savedRoles.cutoutPNG)
        var x0 = Int(raster.size.width),y0 = Int(raster.size.height),x1 = 0,y1 = 0
        for i in 0..<Int(raster.size.width*raster.size.height) where raster.pixels[i*4+3]>0 {
            let x = i%Int(raster.size.width),y = i/Int(raster.size.width)
            x0 = min(x0,x);y0 = min(y0,y);x1 = max(x1,x+1);y1 = max(y1,y+1)
        }
        let expected = CGRect(x: Double(x0)+savedRoles.coordinateOrigin.x,y: Double(y0)+savedRoles.coordinateOrigin.y,width: Double(x1-x0),height: Double(y1-y0))
        let rawBounds: String
        do { rawBounds = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("""
            var d=app.open(new File(\(docPath))),result;
            try {
                var g=d.layerSets.getByName('共同调整'),top=null;
                for(var i=0;i<g.layers.length;i++)if(g.layers[i].name!=='底图'&&g.layers[i].visible){top=g.layers[i];break;}
                if(!top)throw new Error('Missing cutout');
                function hasMask(layer){var ref=new ActionReference();ref.putIdentifier(charIDToTypeID('Lyr '),layer.id);var desc=executeActionGet(ref);return desc.hasKey(stringIDToTypeID('hasUserMask'))&&desc.getBoolean(stringIDToTypeID('hasUserMask'));}
                if(hasMask(top))throw new Error('Visible finished layer still has mask');
                var editable=g.artLayers.getByName('抠图');
                if(!hasMask(editable)||editable.visible)throw new Error('Editable mask backup missing or visible');
                if(d.activeLayer.id!==top.id)throw new Error('Finished layer is not selected');
                var b=top.bounds;result='['+[b[0].as('px'),b[1].as('px'),b[2].as('px'),b[3].as('px')].join(',')+']';
                // 删除副本的蒙版而不应用，证明备份仍保留原底图像素，可恢复被遮住的区域。
                var restored=editable.duplicate();d.activeLayer=restored;
                var ref=new ActionReference();ref.putEnumerated(charIDToTypeID('Chnl'),charIDToTypeID('Chnl'),charIDToTypeID('Msk '));
                var desc=new ActionDescriptor();desc.putReference(charIDToTypeID('null'),ref);desc.putBoolean(charIDToTypeID('Aply'),false);
                executeAction(charIDToTypeID('Dlt '),desc,DialogModes.NO);
                if(restored.bounds[2].as('px')-restored.bounds[0].as('px')<=b[2].as('px')-b[0].as('px'))throw new Error('Backup lost recoverable background pixels');
            }finally{d.close(SaveOptions.DONOTSAVECHANGES);}result;
            """)
        }
        } catch { XCTFail("Photoshop saved-layer bounds: \(String(reflecting: error))"); return }
        let bounds = try JSONDecoder().decode([Double].self,from: Data(rawBounds.utf8))
        for (actual,wanted) in zip(bounds,[expected.minX,expected.minY,expected.maxX,expected.maxY]) { XCTAssertEqual(actual,wanted,accuracy: 2) }
        XCTAssertLessThan(expected.width,raster.size.width); XCTAssertLessThan(expected.height,raster.size.height)
        let final = try await bridge.captureFinalPSD(document: document,owner: owner)
        let finalRoles = try await bridge.extractRoles(snapshot: final)
        let finalRaster = try WorkflowRaster.read(finalRoles.cutoutPNG)
        XCTAssertEqual(finalRaster.size,applied.pixelSize)
        // 最终导出首个可见成品，与严格蒙版回写结果在当前画布上逐像素一致。
        let fw = Int(finalRaster.size.width),fh = Int(finalRaster.size.height),rw = Int(raster.size.width)
        let ox = Int(savedRoles.coordinateOrigin.x),oy = Int(savedRoles.coordinateOrigin.y)
        var mismatch: Int?
        outer: for y in 0..<fh { for x in 0..<fw { for c in 0..<4 {
            let i = (y*fw+x)*4+c,j = ((y-oy)*rw+x-ox)*4+c
            if finalRaster.pixels[i] != raster.pixels[j] { mismatch = i; break outer }
        } } }
        XCTAssertNil(mismatch)
        let output4K = root.appendingPathComponent("final-4096.png")
        try WorkflowAssetRenderer().render4K(roles: finalRoles,layout: .png4k,destination: output4K)
        XCTAssertEqual(try WorkflowRaster.read(output4K).size,CGSize(width: 4096,height: 4096))
        for (url,hash) in zip(originals,hashes) { XCTAssertEqual(try AIFileValidation.hash(url.path),hash) }
        let fixture: [String:Any] = ["sourceHash":hashes[1],"pixelSize":[before.size.width,before.size.height],"originalBatchCoordinateOrigin":[source.coordinateOrigin.x,source.coordinateOrigin.y],"replayCoordinateOrigin":[0,0],"originalMask":mask.path,"cleanedMask":matte.alphaURL.path,"removedPixelCount":removed.count,"review":"pending visual review"]
        try JSONSerialization.data(withJSONObject: fixture,options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("fixture-index.json"))
        let report: [String:Any] = ["removedMaskPixels":removed.count,"originalAlphaBounds":Self.alphaBounds(before,mask: true),"cleanedAlphaBounds":Self.alphaBounds(after,mask: true),"savedAlphaBoundsRaster":Self.alphaBounds(raster,mask: false),"sourceHashes":hashes,"sourceFiles":originals.map(\.path),"cleanupAlgorithmVersion":cleanup.algorithmVersion,"modelInferenceRun":false,"angleDegrees":solution.angleDegrees,"margins":[solution.actualMargins.left,solution.actualMargins.top,solution.actualMargins.right,solution.actualMargins.bottom],"exportSize":[4096,4096],"applicable":solution.isApplicable,"photoshopSavedLayerBounds":bounds,"cropSize":[applied.pixelSize.width,applied.pixelSize.height],"originalsUnchanged":true,"editableMaskAndRGBRetained":true,"savedLayerHasMask":false,"finalPixelsMatch":mismatch == nil,"workingCopy":document.path]
        try JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("validation.json"))
    }

    private static func alphaBounds(_ raster: WorkflowRaster,mask: Bool) -> [Int] {
        let width = Int(raster.size.width),height = Int(raster.size.height),channel = mask ? 0 : 3
        var x0 = width,y0 = height,x1 = 0,y1 = 0
        for i in 0..<width*height where raster.pixels[i*4+channel] > 0 {
            let x = i%width,y = i/width
            x0 = min(x0,x); y0 = min(y0,y); x1 = max(x1,x+1); y1 = max(y1,y+1)
        }
        return x1 > x0 ? [x0,y0,x1-x0,y1-y0] : [0,0,0,0]
    }

    private static func makeReplay(input: URL,mask: URL,output: URL) throws {
        let decoded = try WorkflowRaster.decode(input),image = decoded.image,alpha = try WorkflowRaster.read(mask)
        let w = image.width,h = image.height
        var pixels = [UInt8](repeating:0,count:w*h*4)
        let cutout = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:image.colorSpace!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(red:1,green:1,blue:1,alpha:1);context.fill(CGRect(x:0,y:0,width:w,height:h));context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            let data = bytes.bindMemory(to:UInt8.self)
            for i in 0..<w*h { let a = Int(alpha.pixels[i*4]);for c in 0..<4 { data[i*4+c] = UInt8((Int(data[i*4+c])*a+127)/255) } }
            return context.makeImage()
        }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,try XCTUnwrap(cutout),nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
        try WorkflowRaster.preservePNGColorMetadata(from: input,to: output)
    }
}
