// 图鉴输入与采集信息测试：覆盖实际文件名、空项及不能静默猜测的歧义。
import XCTest
import AppKit
@testable import Butterfly_Toolkit

final class IdentificationCardParsingTests: XCTestCase {
    func testOpaquePNGIsRejected() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("SC1_蝶_Test_D.png")
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        for y in 0..<12 { for x in 0..<16 { bitmap.setColor(NSColor(deviceRed:1,green:1,blue:1,alpha:1),atX:x,y:y) } }
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:url)
        let info=try CardRasterInfo.read(url)
        XCTAssertEqual(info.width,16);XCTAssertEqual(info.height,12)
        XCTAssertTrue(info.issue?.contains("不透明") == true)
    }
    func testFemalePairAndMissingFace() throws {
        let base = "/tmp/SC10129_ochrovirens 栎蛱蝶雌_Euphaedra ochrovirens_"
        let groups = CardInputParser.group([URL(fileURLWithPath: base + "D.png"), URL(fileURLWithPath: base + "V.png")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].chineseName, "ochrovirens 栎蛱蝶")
        XCTAssertEqual(groups[0].sex, .female)
        XCTAssertNil(groups[0].issue)
        XCTAssertTrue(CardInputParser.group([URL(fileURLWithPath: base + "D.png")])[0].issue!.contains("反面"))
    }
    func testDuplicateAndConflictingNamesAreBlocked() {
        let a = URL(fileURLWithPath: "/tmp/a/SC1_栎蛱蝶_Euphaedra test_D.png")
        let b = URL(fileURLWithPath: "/tmp/b/SC1_栎蛱蝶_Euphaedra test_D.png")
        XCTAssertNotNil(CardInputParser.group([a,b])[0].issue)
        XCTAssertNotNil(CardInputParser.group([a,URL(fileURLWithPath: "/tmp/SC1_别名_Euphaedra test_V.png")])[0].issue)
        XCTAssertEqual(CardInputParser.group([a])[0].sex, .male)
    }
    func testCollectionExamplesAndEmptyColumns() throws {
        let first = try CardCollectionInfo.parse("| Ghana | Kwabena Sam Forest, Ashanti | 2025.4.28 |\n| ----- | ---- | ----- |")
        XCTAssertEqual(first.formatted, "Kwabena Sam Forest, Ashanti, Ghana, 2025.4.28")
        let second = try CardCollectionInfo.parse("| Madagascar | Andekaleka, Alaotra-Mangoro | Apr. 2026 |\n| --- | --- | --- |")
        XCTAssertEqual(second.formatted, "Andekaleka, Alaotra-Mangoro, Madagascar, 2026.4")
        XCTAssertEqual(try CardCollectionInfo.parse("| Ghana | | | 1000米 |").formatted, "Ghana, 1000m")
        XCTAssertEqual(CardCollectionInfo().formatted, "")
        XCTAssertEqual(try CardCollectionInfo.parse("\tAndekaleka\t2026.04").formatted, "Andekaleka, 2026.4")
    }
    func testAmbiguousDatesAndMultipleRowsAreNotGuessed() throws {
        let value = try CardCollectionInfo.parse("Ghana\tForest\t04/05/26")
        XCTAssertEqual(value.date, "04/05/26")
        XCTAssertFalse(value.warnings.isEmpty)
        XCTAssertThrowsError(try CardCollectionInfo.parse("Ghana\tForest\t2026\nMadagascar\tForest\t2025"))
        XCTAssertThrowsError(try CardCollectionInfo.parse("Forest, Region, Ghana, 2026"))
        XCTAssertEqual(CardCollectionInfo.normalizedDate("2025.2.30"), "2025.2.30")
    }

    func testCollectionBatchKeepsDataAboveMarkdownSeparatorAndEmptyRows() throws {
        let rows = try CardCollectionInfo.parseBatch("""
        | Cameroon | Ebogo, Centre Reg. | 2026.2 |
        | -------- | ------------------ | ------ |
        | C.A.R. | Bangui | 2024 |

        | | | |
        | DR Congo | Biakato, Mambasa, Ituri | 2004.12.15 |
        """)
        XCTAssertEqual(rows.map(\.info.formatted), [
            "Ebogo, Centre Reg., Cameroon, 2026.2",
            "Bangui, C.A.R., 2024",
            "",
            "Biakato, Mambasa, Ituri, DR Congo, 2004.12.15"
        ])
        let tabular = try CardCollectionInfo.parseBatch("date\tcountry\tlocality\r\n2024\tC.A.R.\tBangui\r\n\t\t")
        XCTAssertEqual(tabular.map(\.info.formatted), ["Bangui, C.A.R., 2024", ""])
        XCTAssertEqual(try CardCollectionInfo.parse(tabular[0].source), tabular[0].info)
        XCTAssertThrowsError(try CardCollectionInfo.parseBatch("Cameroon\tEbogo\t2026.2\n缺少列"))
    }

    func testLeadingWingspanFollowsDateAndLegacyRowsRemainReadable() throws {
        let rows = try CardCollectionInfo.parseBatch("""
        | 74 | DR Congo | Biakato, Mambasa, Ituri | 2004.12.15 |
        | -- | -------- | --------------------- | ---------- |
        | | Cameroon | Ebogo, Centre Reg. | 2026.2 |
        | 81 mm | Cameroon | Ebogo, Centre Reg. | 2026.2 |
        """)
        XCTAssertEqual(rows.map(\.info.formatted), [
            "Biakato, Mambasa, Ituri, DR Congo, 2004.12.15, 74 mm",
            "Ebogo, Centre Reg., Cameroon, 2026.2",
            "Ebogo, Centre Reg., Cameroon, 2026.2, 81 mm"
        ])
        let legacy = try JSONDecoder().decode(CardCollectionInfo.self, from: Data(
            #"{"country":"Ghana","locality":"Ashanti","altitude":"1000m","date":"2025.4","warnings":[]}"#.utf8))
        XCTAssertNil(legacy.wingspan)
        XCTAssertEqual(legacy.formatted, "Ashanti, Ghana, 1000m, 2025.4")
    }
}
