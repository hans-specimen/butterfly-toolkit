// 验证编号位置兼容时不改变物种名称，且规范化不会再次追加编号。
import XCTest
@testable import Butterfly_Toolkit

final class SpecimenFilenameTests: XCTestCase {
    func testNumberLocationsAndLegacySeparatorsNormalizeOnce() {
        for stem in ["SC10136_红褐栎蛱蝶 Euphaedra eberti", "SC10136 红褐栎蛱蝶 Euphaedra eberti",
                     "SC10136红褐栎蛱蝶 Euphaedra eberti", "SC10136*红褐栎蛱蝶 Euphaedra eberti",
                     "红褐栎蛱蝶 Euphaedra eberti_SC10136"] {
            let normalized = SpecimenFilename.normalized(stem)
            XCTAssertEqual(normalized, "红褐栎蛱蝶 Euphaedra eberti_SC10136")
            XCTAssertEqual(SpecimenFilename.normalized(normalized), normalized)
        }
        for stem in ["蝶", "Morpho anaxibia", "蝶_Morpho anaxibia", "SC21", ""] {
            XCTAssertEqual(SpecimenFilename.normalized(stem), stem)
        }
    }

    func testCameraOrderAndNewRawSlotsKeepNumberFirstInSortKey() {
        XCTAssertEqual(SpecimenFilename.sortKey("A_MT10005"), SpecimenFilename.sortKey("MT10005_A"))
        let names = ["DSC10", "DSC2", "DSC1"].sorted {
            SpecimenFilename.sortKey($0).localizedStandardCompare(SpecimenFilename.sortKey($1)) == .orderedAscending
        }
        XCTAssertEqual(names, ["DSC1", "DSC2", "DSC10"])
    }

    func testLegacyLeadingIdentityWinsOverNumberedNameQualifier() {
        let value = SpecimenFilename.components("SC1_蝶_Test species_1")
        XCTAssertEqual(value.number, "SC1")
        XCTAssertEqual(value.name, "蝶_Test species_1")
        XCTAssertEqual(SpecimenFilename.normalized("SC1_蝶_Test species_1"), "蝶_Test species_1_SC1")
    }
}
