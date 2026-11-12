// 图鉴工作目录与发布测试：拒绝未确认覆盖，保留失败现场与可恢复的编辑内容。
import XCTest
import AppKit
@testable import Butterfly_Toolkit

final class IdentificationCardStoreTests: XCTestCase {
    @MainActor func testBatchCollectionAppliesInReviewedOrderAndRejectsIncompleteInput() throws {
        let workspace = CardWorkspace(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let groups = CardInputParser.group([
            URL(fileURLWithPath: "/tmp/SC1_甲_Test one_D.png"),
            URL(fileURLWithPath: "/tmp/SC2_乙_Test two_D.png")
        ])
        var records = groups.map { CardRecord(input: $0) }
        records[0].fields.chineseName = "人工名称"
        records[0].exportedURL = URL(fileURLWithPath: "/tmp/old.png")
        records[0].exportedRevision = 0
        try workspace.save(CardSession(records: records))
        let store = IdentificationCardsStore(workspace: workspace)
        let rows = try CardCollectionInfo.parseBatch("Cameroon\tEbogo\t2026.2\nC.A.R.\tBangui\t2024")
        let ids = records.map(\.id)
        XCTAssertThrowsError(try store.applyCollectionBatch(Array(rows.prefix(1)), to: ids))
        XCTAssertThrowsError(try store.applyCollectionBatch(rows, to: Array(ids.reversed())))
        XCTAssertEqual(store.session.records.map(\.fields.collectionText), ["", ""])
        try store.applyCollectionBatch(rows, to: ids)
        let saved = try workspace.load().records
        XCTAssertEqual(saved.map(\.fields.collectionText), ["Ebogo, Cameroon, 2026.2", "Bangui, C.A.R., 2024"])
        XCTAssertEqual(saved[0].fields.chineseName, "人工名称")
        XCTAssertEqual(saved.map(\.revision), [1, 1])
        XCTAssertFalse(saved[0].isExported)
    }

    func testPreparedRolesRecoverWithoutReinitializingAndRejectChangedHash() throws {
        let workspace=CardWorkspace(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let card=CardRecord(input:CardInputParser.group([URL(fileURLWithPath:"/tmp/SC1_蝶_Test_D.png")])[0])
        try FileManager.default.createDirectory(at:workspace.directory(card.id),withIntermediateDirectories:true)
        try Data("prepared".utf8).write(to:workspace.working(card.id))
        let checkpoint=CardPreparedState(roles:["front":42,"back":43],workHash:try AIFileValidation.hash(workspace.working(card.id).path),layoutPending:false)
        try JSONEncoder().encode(checkpoint).write(to:workspace.directory(card.id).appendingPathComponent("prepared.json"))
        try workspace.save(CardSession(records:[card]))
        let restored=try workspace.load().records[0]
        XCTAssertEqual(restored.roles,checkpoint.roles)
        XCTAssertEqual(restored.workHash,checkpoint.workHash)
        XCTAssertEqual(restored.layoutPending,false)
    }
    func testCleanupRefusesNewWorkingVersion() throws {
        let workspace=CardWorkspace(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id=UUID(); try FileManager.default.createDirectory(at:workspace.directory(id),withIntermediateDirectories:true)
        try Data("exported".utf8).write(to:workspace.working(id))
        let expected=try AIFileValidation.hash(workspace.working(id).path)
        try Data("new manual edit".utf8).write(to:workspace.working(id))
        XCTAssertThrowsError(try workspace.cleanCompleted(id,expectedHash:expected))
        XCTAssertEqual(try String(contentsOf:workspace.working(id),encoding:.utf8),"new manual edit")
        let updated=try AIFileValidation.hash(workspace.working(id).path)
        try workspace.cleanCompleted(id,expectedHash:updated)
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.working(id).path))
    }
    func testExportStatusDoesNotFollowPreviewRevision() throws {
        var record=CardRecord(input:CardInputParser.group([URL(fileURLWithPath:"/tmp/SC1_蝶_Test_D.png")])[0])
        record.exportedURL=URL(fileURLWithPath:"/tmp/done.png");record.exportedRevision=0
        XCTAssertTrue(record.isExported)
        record.revision=1;record.renderedRevision=1
        XCTAssertFalse(record.isExported)
    }
    @MainActor func testImportPreviewsAndManualExternalChangeCanBeResumed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let front=root.appendingPathComponent("SC1_蝶_Test_D.png"), back=root.appendingPathComponent("SC1_蝶_Test_V.png")
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        for y in 0..<12 { for x in 0..<16 { bitmap.setColor(NSColor(deviceRed:1,green:0.5,blue:0,alpha:x < 8 ? 1 : 0),atX:x,y:y) } }
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        try png.write(to:front); try png.write(to:back)
        let bridge=CardTestBridge(), workspace=CardWorkspace(root:root.appendingPathComponent("work"),template:front)
        let store=IdentificationCardsStore(workspace:workspace,bridge:bridge)
        store.importFiles([front,back]); try await settle(store)
        XCTAssertNotNil(store.current?.renderedRevision,"导入后应自动生成首张预览")
        if store.current?.renderedRevision == nil { store.refresh(); try await settle(store) }
        let id=try XCTUnwrap(store.current?.id)
        try Data("external edit".utf8).write(to:workspace.working(id))
        store.openPhotoshop(); try await settle(store)
        XCTAssertEqual(store.manualID,id,"外部保存后应允许进入人工模式读回，不能陷入无法刷新的死路")
        if store.manualID != nil { store.finishManual(); try await settle(store) }
        XCTAssertNil(store.manualID)
    }
    @MainActor private func settle(_ store:IdentificationCardsStore) async throws {
        for _ in 0..<200 { if !store.busy { return }; try await Task.sleep(for:.milliseconds(20)) }
        XCTFail("状态操作超时")
    }
    func testManifestRoundTripAndSingleWorkingPath() throws {
        let workspace = CardWorkspace(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let group = CardInputParser.group([URL(fileURLWithPath:"/tmp/SC1_蝶_Test_D.png")])[0]
        var record = CardRecord(input:group); record.fields.chineseName = "手动名称"; record.fields.collectionText = ""
        let session = CardSession(records:[record])
        try workspace.save(session)
        XCTAssertEqual(try workspace.load().records[0].fields.chineseName,"手动名称")
        XCTAssertEqual(workspace.working(record.id),workspace.working(record.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:workspace.root.path),["session.json"])
    }
    func testTargetChangeInvalidatesConsentAndInvalidPNGPreservesOldOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = CardWorkspace(root:root.appendingPathComponent("work"))
        let target = root.appendingPathComponent("output.png"), candidate = root.appendingPathComponent("bad.png")
        try Data("old".utf8).write(to:target); try Data("bad".utf8).write(to:candidate)
        let stamp = try CardTargetStamp.read(target)
        try Data("changed".utf8).write(to:target)
        XCTAssertThrowsError(try workspace.publish(candidate,to:target,expected:stamp))
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"changed")
        XCTAssertThrowsError(try workspace.publish(candidate,to:target,expected:CardTargetStamp.read(target)))
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"changed")
    }
    func testSourceChangeDetected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let input = root.appendingPathComponent("SC1_蝶_Test_D.png")
        try Data("source".utf8).write(to:input)
        let workspace = CardWorkspace(root:root.appendingPathComponent("work"))
        let hashes = try workspace.fingerprints([input])
        try Data("changed".utf8).write(to:input)
        XCTAssertThrowsError(try workspace.verify(hashes))
    }
}

private actor CardTestBridge: CardPhotoshopServing {
    func render(_ request:CardRenderRequest,owner:UUID) async throws -> CardRenderResult {
        try FileManager.default.createDirectory(at:request.working.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("working".utf8).write(to:request.working)
        return CardRenderResult(roles:["front":1],fields:request.fields,preview:request.working.deletingLastPathComponent().appendingPathComponent("preview.png"),width:4000,height:2250,collision:false)
    }
    func beginManual(_ url:URL,owner:UUID) async throws {}
    func finishManual(_ request:CardRenderRequest,owner:UUID) async throws -> CardRenderResult { try await render(request,owner:owner) }
    func close(_ url:URL,owner:UUID,expectedHash:String?) async throws {}
}
