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

    func testUnnumberedPairsKeepColourFormsAndSexesSeparate() throws {
        let names = ["贝茨蛱蝶黄色 Batesia hypochlora", "贝茨蛱蝶绿色 Batesia hypochlora",
                     "橙斑黑蛱蝶 Catonephele numilia", "橙斑黑蛱蝶雌 Catonephele numilia",
                     "梦幻闪蝶M亚 Morpho deidamia mariae-F"]
        let groups = CardInputParser.group(names.flatMap { name in
            ["D", "v"].map { URL(fileURLWithPath: "/tmp/\(name)_\($0).png") }
        })
        XCTAssertEqual(groups.count, names.count)
        XCTAssertTrue(groups.allSatisfy { $0.front != nil && $0.back != nil && $0.issue == nil })
        let colour = try XCTUnwrap(groups.first { $0.chineseName == "贝茨蛱蝶黄色" })
        XCTAssertEqual(colour.latinName, "Batesia hypochlora")
        XCTAssertEqual(CardRecord(input: colour).outputName, "贝茨蛱蝶黄色_Batesia hypochlora.png")
        XCTAssertEqual(groups.filter { $0.chineseName == "橙斑黑蛱蝶" }.map(\.sex).sorted(by: { $0.rawValue < $1.rawValue }), [.female, .male])
        XCTAssertEqual(groups.first { $0.chineseName == "梦幻闪蝶M亚" }?.sex, .female)
    }

    func testMissingNamesDoNotBlockPairingOrLeaveEmptyExportComponents() throws {
        let cases = [("门亮闪蝶", "门亮闪蝶", "", "门亮闪蝶.png"),
                     ("Morpho anaxibia", "", "Morpho anaxibia", "Morpho anaxibia.png"),
                     ("SC21", "", "", "SC21.png"),
                     ("SC22*纱栎蛱蝶 Euphaedra sarita sarita", "纱栎蛱蝶", "Euphaedra sarita sarita", "SC22_纱栎蛱蝶指名亚种_Euphaedra sarita sarita.png")]
        for (stem, chinese, latin, filename) in cases {
            let groups = CardInputParser.group(["D", "V"].map { URL(fileURLWithPath: "/tmp/\(stem)_\($0).png") })
            XCTAssertEqual(groups.count, 1, stem)
            let group = try XCTUnwrap(groups.first)
            XCTAssertNil(group.issue, stem)
            XCTAssertEqual(group.chineseName, chinese)
            XCTAssertEqual(group.latinName, latin)
            XCTAssertEqual(CardRecord(input: group).outputName, filename)
        }
    }

    func testNominateSubspeciesUsesChineseSuffixOnce() throws {
        for chinese in ["纱栎蛱蝶", "纱栎蛱蝶 sarita 亚种", "纱栎蛱蝶指名亚种"] {
            let name = "/tmp/SC8_\(chinese)_Euphaedra sarita sarita_"
            let input = try XCTUnwrap(CardInputParser.group([URL(fileURLWithPath: name + "D.png"), URL(fileURLWithPath: name + "V.png")]).first)
            XCTAssertEqual(CardRecord(input: input).fields.chineseName, "纱栎蛱蝶指名亚种")
        }
        let other = try XCTUnwrap(CardInputParser.group([URL(fileURLWithPath: "/tmp/SC9_栎蛱蝶 maria 亚种_Euphaedra sarita maria_D.png")]).first)
        XCTAssertEqual(CardRecord(input: other).fields.chineseName, "栎蛱蝶 maria 亚种")
    }

    func testNumberedFacesCanSupplyMissingNamesAndUnnumberedFacesStayInTheirFolder() throws {
        let numbered = CardInputParser.group([
            URL(fileURLWithPath: "/tmp/a/SC3_门亮闪蝶D.png"),
            URL(fileURLWithPath: "/tmp/b/SC3_Morpho anaxibia_V.png")
        ])
        XCTAssertEqual(numbered.count, 1)
        let card = CardRecord(input: try XCTUnwrap(numbered.first))
        XCTAssertNil(card.input.issue)
        XCTAssertNil(card.missingNames)
        XCTAssertEqual(card.outputName, "SC3_门亮闪蝶_Morpho anaxibia.png")

        let unnumbered = CardInputParser.group([
            URL(fileURLWithPath: "/tmp/a/门亮闪蝶_D.png"),
            URL(fileURLWithPath: "/tmp/b/门亮闪蝶_V.png")
        ])
        XCTAssertEqual(unnumbered.count, 2)
        XCTAssertTrue(unnumbered.allSatisfy { $0.issue != nil })
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
