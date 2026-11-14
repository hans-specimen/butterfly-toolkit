// 图鉴排版规则与真实 Photoshop 副本验证；真实调用必须显式启用。
import XCTest
import AppKit
import JavaScriptCore
@testable import Butterfly_Toolkit

final class IdentificationCardBridgeTests: XCTestCase {
    func testWidePairSharesWidthAndCentersWithAtLeast25PixelsVertically() throws {
        let wide = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 3000, height: 2000), back: CGSize(width: 2900, height: 1900))).frames
        XCTAssertEqual(wide[0].width, 1870, accuracy: 0.01)
        XCTAssertEqual(wide[1].width, 1870, accuracy: 0.01)
        XCTAssertEqual(wide[0].midX, 1000, accuracy: 0.01)
        XCTAssertEqual(wide[1].midX, 3000, accuracy: 0.01)
        XCTAssertEqual(wide[0].midY, 900, accuracy: 0.01)
        XCTAssertEqual(wide[1].midY, 900, accuracy: 0.01)

        let tight = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1870, height: 1580), back: CGSize(width: 2000, height: 1600))).frames
        XCTAssertEqual(tight[0].minY, 125, accuracy: 0.01)
        XCTAssertEqual(tight[0].maxY, 1675, accuracy: 0.01)
        XCTAssertEqual(tight[0].width, tight[1].width, accuracy: 0.01)
        XCTAssertEqual(tight[1].midY, 900, accuracy: 0.01)
    }

    func testTallPairUsesTheLargestContainedHeightBeforeAllowingOverflow() throws {
        let pair = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1870, height: 1630), back: CGSize(width: 2000, height: 1730))).frames
        for frame in pair {
            XCTAssertEqual(frame.minY, 100, accuracy: 0.01)
            XCTAssertEqual(frame.maxY, 1700, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(frame.width, 1800)
            XCTAssertLessThanOrEqual(frame.width, 1870)
        }

        let boundary = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1800, height: 1600), back: CGSize(width: 3600, height: 3200))).frames
        XCTAssertEqual(boundary[0].width, 1800, accuracy: 0.01)
        XCTAssertEqual(boundary[0].maxY, 1700, accuracy: 0.01)

        let mixed = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1870, height: 1630), back: CGSize(width: 3000, height: 2000))).frames
        XCTAssertEqual(mixed[0].height, mixed[1].height, accuracy: 0.01)
        XCTAssertEqual(mixed[0].midY, 900, accuracy: 0.01)
        XCTAssertEqual(mixed[1].width, 1870, accuracy: 0.01)
    }

    func testTallPairUses60PixelInsetAndCapsOverflowAt150Pixels() throws {
        let modest = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1800, height: 1660), back: CGSize(width: 1810, height: 1660))).frames
        XCTAssertEqual(modest[1].width, 1800, accuracy: 0.01)
        XCTAssertLessThan(modest[0].width, 1800)
        XCTAssertEqual(modest[0].minY, 100, accuracy: 0.01)
        XCTAssertEqual(modest[1].minY, 100, accuracy: 0.01)
        XCTAssertEqual(modest[0].maxY, 100 + 1660 * 1800.0 / 1810, accuracy: 0.01)
        XCTAssertEqual(modest[1].height, modest[0].height, accuracy: 0.01)

        let extreme = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1800, height: 2100), back: CGSize(width: 1840, height: 2100))).frames
        for frame in extreme {
            XCTAssertLessThan(frame.width, 1800)
            XCTAssertEqual(frame.minY, 100, accuracy: 0.01)
            XCTAssertEqual(frame.maxY, 1850, accuracy: 0.01)
        }
    }

    func testPhotoshopLayoutShrinksBothSidesFromTheTopToAvoidText() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var Units={PIXELS:1}, DialogModes={NO:0}, DocumentMode={RGB:1};
        var ElementPlacement={PLACEBEFORE:0}, LayerKind={TEXT:1}, AnchorPosition={MIDDLECENTER:0};
        var SelectionType={INTERSECT:0};
        function Unit(px){this.as=function(){return px;};}
        function layer(id, name, rect) {
            var l={id:id, name:name, typename:'ArtLayer', rect:rect, visible:true, move:function(){}};
            Object.defineProperty(l,'boundsNoEffects',{get:function(){return this.rect.map(function(x){return new Unit(x);});}});
            l.resize=function(x,y){
                this.rect[2]=this.rect[0]+(this.rect[2]-this.rect[0])*x/100;
                this.rect[3]=this.rect[1]+(this.rect[3]-this.rect[1])*y/100;
            };
            l.translate=function(x,y){this.rect=[this.rect[0]+x,this.rect[1]+y,this.rect[2]+x,this.rect[3]+y];};
            return l;
        }
        function group(id, layers){
            var g={id:id, typename:'LayerSet', layers:layers, move:function(){}};
            for(var i=0;i<layers.length;i++)layers[i].parent=g;
            return g;
        }
        var front=layer(1,'front',[0,0,1800,1660]),back=layer(2,'back',[0,0,1810,1660]);
        var texts=['female','male','latin','collection','credit','chinese'].map(function(name,i) {
            var l=layer(7+i,name,[i===3?500:3000,1650,i===3?1500:3500,1700]);l.kind=LayerKind.TEXT;
            l.visible=i===3;l.textItem={font:'test',contents:i===4?'Image Hans Collection.':'Test'};return l;
        });
        var doc=group(20,[group(3,[front,back]),group(4,texts),group(5,[]),layer(6,'85BG',[0,0,4000,2250])]);
        doc.width=new Unit(4000);doc.height=new Unit(2250);doc.mode=DocumentMode.RGB;
        doc.fullName={fsName:'/fixture/card.psd'};doc.saved=true;doc.save=function(){};
        var app={preferences:{},documents:[doc],fonts:{getByName:function(){}}};
        function stringIDToTypeID(id){return id;} function charIDToTypeID(id){return id;}
        function ActionReference(){} function ActionDescriptor(){}
        ActionReference.prototype.putProperty=ActionReference.prototype.putEnumerated=function(){};
        ActionDescriptor.prototype.putReference=function(){}; function executeAction(){}
        doc.selection={
            select:function(box){
                var r=doc.activeLayer.rect, t=box;
                var x=Math.max(r[0],t[0][0]),y=Math.max(r[1],t[0][1]),right=Math.min(r[2],t[2][0]),bottom=Math.min(r[3],t[2][1]);
                this.bounds=x<right&&y<bottom?[x,y,right,bottom].map(function(n){return new Unit(n);}):null;
            },deselect:function(){this.bounds=null;}
        };
        """)
        let placement = try XCTUnwrap(CardLayout.placement(front: CGSize(width: 1800, height: 1660), back: CGSize(width: 1810, height: 1660)))
        let payload: [String: Any] = [
            "operation": "layout", "nativePath": "/fixture/card.psd", "documentID": 20,
            "roles": ["front": 1, "back": 2, "butterfly": 3, "text": 4, "shape": 5, "bg": 6,
                      "female": 7, "male": 8, "latin": 9, "collection": 10, "credit": 11, "chinese": 12],
            "frames": placement.frames.map { [$0.minX, $0.minY, $0.width, $0.height] },
            "matchHeight": placement.matchHeight, "topAligned": placement.topAligned, "bottomLimit": placement.bottomLimit
        ]
        let request = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let source = CardPhotoshopScript.source + """

        var result=cardRun(\(request));
        JSON.stringify({collision:JSON.parse(result).collision,rects:[front.rect,back.rect]});
        """
        let result = context.evaluateScript(source)
        XCTAssertNil(context.exception?.toString())
        let output = Data(try XCTUnwrap(result?.toString()).utf8)
        struct LayoutResult: Decodable { let collision: Bool; let rects: [[Double]] }
        let layout = try JSONDecoder().decode(LayoutResult.self, from: output)
        XCTAssertFalse(layout.collision)
        for rect in layout.rects {
            XCTAssertEqual(rect[1], 100, accuracy: 0.01)
            XCTAssertLessThanOrEqual(rect[3], 1638)
            XCTAssertLessThan(rect[2] - rect[0], 1800)
        }
        XCTAssertEqual((layout.rects[0][0] + layout.rects[0][2]) / 2, 1000, accuracy: 0.01)
        XCTAssertEqual((layout.rects[1][0] + layout.rects[1][2]) / 2, 3000, accuracy: 0.01)
        XCTAssertEqual(layout.rects[0][3], layout.rects[1][3], accuracy: 0.01)
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
