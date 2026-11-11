// 仅在显式启用时使用全新合成素材验证 Photoshop 连续文档与保存恢复，不访问用户照片。
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowDocumentSessionLiveTests: XCTestCase {
    private actor Calls {
        var geometry = 0
        func record(_ script: String) { if script.contains("var px=") { geometry += 1 } }
        func count() -> Int { geometry }
    }
    func testSyntheticStackSubjectGeometryKeepsOneDocumentAndRecoversReceipt() async throws {
        guard ProcessInfo.processInfo.environment["WORKFLOW_SESSION_SYNTHETIC"] == "1" else {
            throw XCTSkip("Requires explicit synthetic Photoshop validation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Toolkit-Session-Live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("SESSION_EVIDENCE=" + root.path)
        let image = try syntheticImage()
        let sources = try (0..<3).map { index -> URL in
            let path = root.appendingPathComponent("synthetic-\(index).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return path
        }
        let sourceHashes = try sources.map { try AIFileValidation.hash($0.path) }
        let owner = UUID(), work = root.appendingPathComponent("work.psd"), calls = Calls()
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("evidence"), scriptRunner: { script in
            await calls.record(script)
            let diagnostic = root.appendingPathComponent(UUID().uuidString)
            try script.write(to: diagnostic.appendingPathExtension("jsx"), atomically: true, encoding: .utf8)
            do {
                let response = try await PhotoshopWorkflowBridge.execute(script)
                try response.write(to: diagnostic.appendingPathExtension("json"), atomically: true, encoding: .utf8)
                return response
            } catch {
                try String(reflecting: error).write(to: diagnostic.appendingPathExtension("error.txt"), atomically: true, encoding: .utf8)
                let probe = """
                (function(){var out=[];for(var i=0;i<app.documents.length;i++){var d=app.documents[i];out.push('doc '+d.id+' '+d.name+' saved '+d.saved);for(var j=0;j<d.layers.length;j++){try{var l=d.layers[j];out.push('layer '+l.id+' '+l.name+' '+l.typename);}catch(e){out.push('layer error '+e);}}}return out.join('\\n');}());
                """
                if let response = try? await PhotoshopWorkflowBridge.execute(probe) {
                    try response.write(to: diagnostic.appendingPathExtension("probe.txt"), atomically: true, encoding: .utf8)
                }
                throw error
            }
        })
        let path = String(decoding: try JSONEncoder().encode(work.path), as: UTF8.self)
        let inspect = """
        (function(){for(var i=0;i<app.documents.length;i++){var d=app.documents[i];try{if(d.fullName.fsName.replace(/^\\/private(?=\\/(tmp|var)\\/)/,'')===new File(\(path)).fsName.replace(/^\\/private(?=\\/(tmp|var)\\/)/,''))return String(d.id);}catch(e){}}return 'closed';}());
        """
        let result = try await bridge.withTaskDocument(owner: owner, document: work) {
            let stack = try await bridge.stack(job: FocusStackJob(id: 1, sourceFiles: sources, destinationURL: work, butterflyName: "synthetic", side: "D"), owner: owner)
            let stackID = try await PhotoshopWorkflowBridge.execute(inspect)
            XCTAssertNotEqual(stackID, "closed")
            let subject = try await bridge.selectSubject(snapshot: stack)
            let observedID0 = try await PhotoshopWorkflowBridge.execute(inspect)
            XCTAssertEqual(observedID0, stackID)
            let repeatedSubject = try await bridge.selectSubject(snapshot: stack)
            XCTAssertEqual(repeatedSubject.contentVersion, subject.contentVersion, "Successful subject receipt must not repeat mask levels")
            let images = try await bridge.extractRoles(snapshot: subject)
            XCTAssertEqual(images.snapshotVersion, subject.contentVersion)
            var solution = ExecutorFixture.solution(subject.contentVersion)
            solution.angleDegrees = 7
            solution.rotationPivot = CGPoint(x: 256, y: 256)
            solution.sourceCropRect = CGRect(x: 16, y: 16, width: 480, height: 480)
            solution.outputSize = CGSize(width: 480, height: 480)
            let final = try await bridge.applyGeometry(snapshot: subject, solution: solution)
            let observedID1 = try await PhotoshopWorkflowBridge.execute(inspect)
            XCTAssertEqual(observedID1, stackID)
            let recovered = try await bridge.applyGeometry(snapshot: subject, solution: solution)
            XCTAssertEqual(recovered, final, "Exact successful receipt must recover without applying geometry twice")
            let observedID2 = try await PhotoshopWorkflowBridge.execute(inspect)
            XCTAssertEqual(observedID2, stackID)
            return (stack, subject, final)
        }
        let after = try await PhotoshopWorkflowBridge.execute(inspect)
        XCTAssertEqual(after, "closed")
        let geometryCalls = await calls.count()
        XCTAssertEqual(geometryCalls, 1)
        XCTAssertEqual(try sources.map { try AIFileValidation.hash($0.path) }, sourceHashes)
        let final = try await bridge.captureFinalPSD(document: work, owner: owner)
        _ = try await bridge.extractRoles(snapshot: final)
        XCTAssertEqual(final.contentVersion, result.2.contentVersion)
        let record = work.appendingPathExtension("workflow-owner.json")
        var ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        ownership["pendingMutation"] = ["operation":"geometry", "sourceVersion":result.1.contentVersion]
        try JSONSerialization.data(withJSONObject: ownership).write(to: record, options: .atomic)
        try await bridge.acknowledgeManualResult(snapshot: final)
        let acknowledged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertNil(acknowledged["pendingMutation"])
        let manual = root.appendingPathComponent("manual-mask.psd")
        _ = try await bridge.restoreCheckpoint(snapshot: result.0, destination: manual)
        // 模拟用户在新副本中保存了正确三层；磁盘内容来自刚才已核验的PS识别快照。
        try Data(contentsOf: result.1.snapshotURL).write(to: manual, options: .atomic)
        let adopted = try await bridge.adoptManualMask(document: manual, owner: owner)
        XCTAssertEqual(adopted.contentVersion, result.1.contentVersion)
        XCTAssertEqual(adopted.roles, result.1.roles)
        XCTAssertEqual(try AIFileValidation.hash(work.path), result.2.contentVersion, "Manual restoration must preserve the previous working PSD")
        let changed = root.appendingPathComponent("manual-changed-base.psd")
        _ = try await bridge.restoreCheckpoint(snapshot: result.0, destination: changed)
        try Data(contentsOf: result.1.snapshotURL).write(to: changed, options: .atomic)
        let changedPath = String(decoding: try JSONEncoder().encode(changed.path), as: UTF8.self)
        _ = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("""
            (function(){var d=app.open(new File(\(changedPath)));try{
                var layer=d.layerSets.getByName('共同调整').artLayers.getByName('Stack');d.activeLayer=layer;layer.visible=true;
                d.selection.select([[0,0],[3,0],[3,3],[0,3]]);var red=new SolidColor();red.rgb.red=255;red.rgb.green=0;red.rgb.blue=0;
                d.selection.fill(red);d.selection.deselect();layer.visible=false;d.save();return 'saved';
            }finally{if(d.saved)d.close(SaveOptions.DONOTSAVECHANGES);}}());
            """)
        }
        do { _ = try await bridge.adoptManualMask(document: changed, owner: owner); XCTFail("Changed Stack pixels were accepted as mask-only editing") }
        catch WorkflowBridgeError.invalidImage {}
        let rejectedRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: changed.appendingPathExtension("workflow-owner.json"))) as? [String: Any])
        XCTAssertNil(rejectedRecord["roles"], "Failed validation must not claim manual roles")
        try JSONEncoder().encode(result.2).write(to: root.appendingPathComponent("result.json"))
        try JSONSerialization.data(withJSONObject: ["sameWorkingDocument":true,"geometryCalls":geometryCalls,"sourceFilesUnchanged":true,"manualMaskAccepted":true,"changedStackRejected":true,"explicitManualAcknowledgement":true,"checkpointRestoredToNewPath":true], options: .prettyPrinted)
            .write(to: root.appendingPathComponent("validation.json"))
    }
    func testSyntheticFinalExportUsesRenamedHiddenFirstLayer() async throws {
        guard ProcessInfo.processInfo.environment["WORKFLOW_SESSION_SYNTHETIC"] == "1" else {
            throw XCTSkip("Requires explicit synthetic Photoshop validation")
        }
        let owner = UUID()
        let openCount = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute("String(app.documents.length)")
        }
        guard openCount.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw XCTSkip("Photoshop has open documents; leave the user's editing session untouched")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Toolkit-First-Layer-Live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("FIRST_LAYER_EVIDENCE=" + root.path)
        let image = try syntheticImage()
        let sources = try (0..<3).map { index -> URL in
            let url = root.appendingPathComponent("synthetic-\(index).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
        let hashes = try sources.map { try AIFileValidation.hash($0.path) }
        let work = root.appendingPathComponent("manual-first-layer.psd")
        let bridge = PhotoshopWorkflowBridge(workspace: root.appendingPathComponent("evidence"))
        let encodedPath = String(decoding: try JSONEncoder().encode(work.path), as: UTF8.self)
        // 只操作本测试新建的PSD，模拟一个有独特像素、改名且隐藏的首层；原抠图层仍留在下方。
        let topID = try await bridge.withTaskDocument(owner: owner, document: work) {
            let stack = try await bridge.stack(job: FocusStackJob(id: 1, sourceFiles: sources, destinationURL: work, butterflyName: "synthetic", side: "D"), owner: owner)
            _ = try await bridge.selectSubject(snapshot: stack)
            let identifier = try await PhotoshopWorkflowBridge.execute("""
            (function(){var d=app.open(new File(\(encodedPath)));
                var g=d.layerSets.getByName('共同调整');
                var top=g.artLayers.getByName('Keying_Level').duplicate();top.move(g,ElementPlacement.INSIDE);
                top.name='人工精修结果';d.activeLayer=top;d.activeChannels=d.componentChannels;
                d.selection.selectAll();var c=new SolidColor();c.rgb.red=240;c.rgb.green=20;c.rgb.blue=20;
                d.selection.fill(c);d.selection.deselect();top.visible=false;d.save();return String(top.id);
            }());
            """)
            let openDocuments = try await bridge.openDocuments()
            let observed = try XCTUnwrap(openDocuments.first { $0.url == work.resolvingSymlinksInPath().standardizedFileURL })
            XCTAssertGreaterThan(observed.documentID, 0)
            XCTAssertTrue(observed.saved)
            return identifier
        }
        let closedDocuments = try await bridge.openDocuments()
        XCTAssertFalse(closedDocuments.contains { $0.url == work.resolvingSymlinksInPath().standardizedFileURL })
        let savedHash = try AIFileValidation.hash(work.path)
        let final = try await bridge.captureFinalPSD(document: work, owner: owner)
        let roles = try await bridge.extractRoles(snapshot: final)
        XCTAssertEqual(final.finalRoles?.cutoutLayer, topID)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(roles.cutoutPNG as CFURL, nil))
        let cutout = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let center = try XCTUnwrap(cutout.cropping(to: CGRect(x: cutout.width / 2, y: cutout.height / 2, width: 1, height: 1)))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[3], 200, "The subject center must retain mask alpha")
        XCTAssertGreaterThan(Int(pixel[0]), Int(pixel[1]) + 100, "Export must contain the edited first-layer pixels")
        XCTAssertEqual(try AIFileValidation.hash(work.path), savedHash, "Extraction must not change the saved PSD or its visibility")
        XCTAssertEqual(try sources.map { try AIFileValidation.hash($0.path) }, hashes)
        try JSONEncoder().encode(final).write(to: root.appendingPathComponent("final-snapshot.json"))
    }
    private func syntheticImage() throws -> CGImage {
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 512,height: 512))
        // 有纹理的蝴蝶形状供自动对齐/混合与主体选择；所有像素均由测试生成。
        for side in [-1.0, 1.0] {
            context.saveGState();context.translateBy(x: 256,y: 256);context.scaleBy(x: side,y: 1)
            context.setFillColor(CGColor(red: 0.15, green: 0.24, blue: 0.42, alpha: 1))
            context.fillEllipse(in: CGRect(x: 5,y: 0,width: 178,height: 170))
            context.fillEllipse(in: CGRect(x: 5,y: -140,width: 140,height: 150))
            context.setFillColor(CGColor(red: 0.92, green: 0.49, blue: 0.08, alpha: 1))
            context.fillEllipse(in: CGRect(x: 24,y: 24,width: 135,height: 122))
            context.fillEllipse(in: CGRect(x: 22,y: -115,width: 100,height: 113))
            context.setStrokeColor(CGColor(gray: 0.12, alpha: 1));context.setLineWidth(3)
            for i in 0..<7 {context.move(to: CGPoint(x: 12,y: 0));context.addLine(to: CGPoint(x: 30+i*20,y: 140-i*12));context.strokePath()}
            context.restoreGState()
        }
        context.setFillColor(CGColor(gray: 0.08,alpha: 1));context.fillEllipse(in: CGRect(x: 245,y: 130,width: 22,height: 220))
        context.fillEllipse(in: CGRect(x: 241,y: 342,width: 30,height: 32))
        return try XCTUnwrap(context.makeImage())
    }
}
