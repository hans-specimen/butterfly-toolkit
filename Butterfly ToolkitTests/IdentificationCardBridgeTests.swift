// 图鉴排版规则与真实 Photoshop 副本验证；真实调用必须显式启用。
import XCTest
import AppKit
@testable import Butterfly_Toolkit

final class IdentificationCardBridgeTests: XCTestCase {
    func testNormalAndTallLayoutShareCenters() throws {
        let normal = CardLayout.frames(front: CGSize(width: 3000,height: 2000), back: CGSize(width: 2900,height: 1900))
        XCTAssertEqual(normal[0].width,1880,accuracy: 0.01)
        XCTAssertEqual(normal[0].midY,normal[1].midY,accuracy: 0.01)
        XCTAssertEqual(normal[0].midX,1000,accuracy: 0.01)
        let tall = CardLayout.frames(front: CGSize(width: 1800,height: 3000), back: CGSize(width: 1900,height: 3100))
        XCTAssertEqual(tall[0].minY,100,accuracy: 0.01)
        XCTAssertEqual(tall[0].height,tall[1].height,accuracy: 0.01)
        XCTAssertLessThanOrEqual(tall[0].maxY,1850)
        XCTAssertLessThanOrEqual(tall[1].width,1880)
    }
    func testActualTemplateQuickExportAndManualRefresh() async throws {
        guard ProcessInfo.processInfo.environment["CARD_LIVE_TEMPLATE"] != nil else { throw XCTSkip("需要显式指定模板，真实 Photoshop 测试默认跳过") }
        let template = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CARD_LIVE_TEMPLATE"]!)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("card-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("SC1_测试蝶_Test species_D.png")
        let image = NSImage(size: NSSize(width:400,height:400)); image.lockFocus()
        NSColor.orange.setFill(); NSBezierPath(ovalIn:NSRect(x:40,y:30,width:320,height:340)).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:input)
        let working = root.appendingPathComponent("card.psd")
        let request = CardRenderRequest(working:working, template:template, front:input, back:input,
                                        fields:CardFields(chineseName:"测试蝶 excelsior 亚种 f. jupiter",latinName:"Test species"),
                                        roles:nil, layout:true)
        let bridge = CardPhotoshopBridge(), owner = UUID()
        let result = try await bridge.render(request,owner:owner)
        XCTAssertEqual(result.width,4000); XCTAssertEqual(result.height,2250)
        XCTAssertEqual(result.roles.count,12)
        XCTAssertFalse(result.collision)
        XCTAssertTrue(FileManager.default.fileExists(atPath:result.preview.path))
        let path = working.resolvingSymlinksInPath().path
        let checkClosed = "var path=new File('\(path)').fsName.replace(/^\\/private\\//,'/');var found=false;for(var i=0;i<app.documents.length;i++){try{if(app.documents[i].fullName.fsName.replace(/^\\/private\\//,'/')==path)found=true;}catch(e){}}found?'open':'closed';"
        let openAfterPreview = try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
            try await PhotoshopWorkflowBridge.execute(checkClosed)
        }
        XCTAssertEqual(openAfterPreview,"closed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.path))
        let chineseLayer = try XCTUnwrap(result.roles["chinese"])
        let readStyles = """
        var d=app.open(new File('\(path)'));app.activeDocument=d;
        function k(n){return stringIDToTypeID(n);}
        var ref=new ActionReference();ref.putProperty(k('property'),k('textKey'));ref.putIdentifier(k('layer'),\(chineseLayer));
        var list=executeActionGet(ref).getObjectValue(k('textKey')).getList(k('textStyleRange')), styles=[];
        for(var i=0;i<list.count;i++){
         var style=list.getObjectValue(i).getObjectValue(k('textStyle'));
         var key=style.hasKey(k('impliedFontSize'))?'impliedFontSize':'size';
         styles.push(style.getString(k('fontPostScriptName'))+':'+style.getUnitDoubleValue(k(key)).toFixed(2));
        }
        styles.join(',');
        """
        let styles = try await PhotoshopExecutionCoordinator.shared.run(owner:owner) {
            try await PhotoshopWorkflowBridge.execute(readStyles)
        }
        XCTAssertEqual(styles, "PingFangSC-Regular:16.00,TimesNewRomanPS-ItalicMT:16.00,PingFangSC-Regular:16.00,TimesNewRomanPS-ItalicMT:16.00")
        var refresh = request; refresh.roles=result.roles; refresh.layout=false
        let second = try await bridge.render(refresh,owner:owner)
        XCTAssertEqual(second.roles,result.roles)
        // 在工具自有副本模拟人工调整及保存，再验证刷新和改文字均不重排。
        let script = "var d=app.open(new File('\(path)'));app.activeDocument=d;function layer(p,id){for(var i=0;i<p.layers.length;i++){var l=p.layers[i];if(l.id==id)return l;if(l.typename=='LayerSet'){var r=layer(l,id);if(r)return r;}}}var l=layer(d,\(result.roles["front"]!));l.translate(0,-30);String(d.id);"
        let editedID = try await PhotoshopExecutionCoordinator.shared.run(owner:owner) { try await PhotoshopWorkflowBridge.execute(script) }
        let documentID = try XCTUnwrap(Int(editedID))
        try await bridge.beginManual(working,owner:owner)
        do { _ = try await bridge.finishManual(refresh,owner:owner); XCTFail("未保存时不能刷新") }
        catch { XCTAssertTrue(error.localizedDescription.contains("保存")) }
        let saveOwned = "var saved=false;for(var i=0;i<app.documents.length;i++){var doc=app.documents[i];if(doc.id==\(documentID)){doc.save();saved=true;break;}}saved?'saved':'missing';"
        let saveResult = try await PhotoshopExecutionCoordinator.shared.readSaved(owner:owner) { try await PhotoshopWorkflowBridge.execute(saveOwned) }
        XCTAssertEqual(saveResult,"saved")
        let manual = try await bridge.finishManual(refresh,owner:owner)
        XCTAssertFalse(manual.collision)
        refresh.fields.latinName="Test species with a longer scientific name"
        let changed = try await bridge.render(refresh,owner:owner)
        XCTAssertEqual(changed.fields.latinName,refresh.fields.latinName)
        let inspect = "var d=app.open(new File('\(path)'));app.activeDocument=d;var a=[];function walk(p){for(var i=0;i<p.layers.length;i++){var l=p.layers[i];if(l.id==\(result.roles["front"]!))a.push(l.boundsNoEffects[1].as('px'));if(l.typename=='LayerSet')walk(l);}}walk(d);a.join(',');"
        let top = try await PhotoshopExecutionCoordinator.shared.run(owner:owner) { try await PhotoshopWorkflowBridge.execute(inspect) }
        XCTAssertEqual(Double(top),70,"人工上移 30px 后，刷新和修改文字不得重排")
        try await bridge.close(working,owner:owner)
        print("CARD_LIVE_EVIDENCE=\(root.path)")
    }
}
