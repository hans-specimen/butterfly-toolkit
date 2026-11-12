// 图鉴真实批次验收：只读用户选定素材，复制到临时目录；保存成品和界面截图供核对。
import XCTest
import SwiftUI
@testable import Butterfly_Toolkit

final class IdentificationCardBatchLiveTests: XCTestCase {
    @MainActor func testInterfaceSnapshotsWhenRequested() async throws {
        guard let path=ProcessInfo.processInfo.environment["CARD_UI_SESSION"] else { throw XCTSkip("需要已生成的隔离图鉴会话") }
        let root=URL(fileURLWithPath:path)
        try await capture(CardWorkspace(root:root.appendingPathComponent("work")),at:root)
    }
    @MainActor func testSelectedBatchAndInterface() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let sourcePath=env["CARD_LIVE_INPUT"],let templatePath=env["CARD_LIVE_TEMPLATE"] else { throw XCTSkip("需要显式选择图鉴真实素材与模板") }
        let root=URL(fileURLWithPath:"/tmp").appendingPathComponent("toolkit-card-batch-\(UUID())")
        let inputs=root.appendingPathComponent("inputs"),output=root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at:inputs,withIntermediateDirectories:true)
        let original=try CardInputParser.scan([URL(fileURLWithPath:sourcePath)])
        XCTAssertEqual(original.filter { $0.issue == nil }.count,10)
        let workspace=CardWorkspace(root:root.appendingPathComponent("work"),template:URL(fileURLWithPath:templatePath))
        let originalHashes=try workspace.fingerprints(original.flatMap(\.files)+[workspace.template])
        for url in original.flatMap(\.files) { try FileManager.default.copyItem(at:url,to:inputs.appendingPathComponent(url.lastPathComponent)) }
        let groups=try CardInputParser.scan([inputs])
        let bridge=CardPhotoshopBridge()
        let cards = groups.map { group in
            var card = CardRecord(input: group)
            if group.id == "SC10129" { card.fields.chineseName = "赭色栎蛱蝶" }
            return card
        }
        var session = CardSession(records: cards, outputDirectory: output)
        try workspace.save(session)
        if let collectionPath = env["CARD_LIVE_COLLECTION"] {
            let rows = try CardCollectionInfo.parseBatch(String(contentsOfFile: collectionPath, encoding: .utf8))
            let store = IdentificationCardsStore(workspace: workspace)
            try store.applyCollectionBatch(rows, to: cards.map(\.id))
            session = store.session
        }
        for index in session.records.indices {
            var card = session.records[index]
            let group = card.input
            XCTAssertNil(group.issue)
            let request=CardRenderRequest(working:workspace.working(card.id),template:workspace.template,front:try XCTUnwrap(group.front),back:try XCTUnwrap(group.back),fields:card.fields,roles:nil,layout:true)
            let result=try await bridge.render(request,owner:card.id)
            XCTAssertFalse(result.collision,group.id)
            XCTAssertEqual(result.fields.collectionText, card.fields.collectionText, group.id)
            card.roles=result.roles;card.renderedRevision=card.revision
            card.previewHash = result.previewHash
            card.sources = try workspace.fingerprints([request.front, request.back, request.template])
            let hash=try AIFileValidation.hash(workspace.working(card.id).path)
            let destination=output.appendingPathComponent(card.outputName)
            try workspace.publish(result.preview,to:destination,expected:CardTargetStamp.read(destination))
            try await bridge.close(workspace.working(card.id),owner:card.id,expectedHash:hash)
            try workspace.cleanCompleted(card.id,expectedHash:hash)
            XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.working(card.id).path))
            card.roles=nil;card.exportedURL=destination;card.exportedRevision=card.revision
            session.records[index] = card
            try workspace.save(session)
        }
        try workspace.verify(originalHashes)
        try await capture(workspace,at:root)
        try Data(root.path.utf8).write(to:URL(fileURLWithPath:"/tmp/toolkit-card-last-batch.txt"))
        print("CARD_BATCH_EVIDENCE=\(root.path)")
    }
    @MainActor private func capture(_ workspace:CardWorkspace,at root:URL) async throws {
        let store=IdentificationCardsStore(workspace:workspace)
        for width in [1000,1400] {
            let view=NSHostingView(rootView:IdentificationCardsView(store:store))
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:850),styleMask:[.titled],backing:.buffered,defer:false)
            window.contentView=view;window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(500))
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent("interface-\(width).png"))
            window.orderOut(nil)
        }
    }
}
