// 验证独立工具迁移后依然保护完整主体、比例和原图范围。
import XCTest
@testable import Butterfly_Toolkit

final class ButterflyCropProcessorTests: XCTestCase {
    func testTenPercentMarginUsesOutputDimensions() throws {
        let prepared = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 1000,height: 800),version: "v1",bounds: CGRect(x: 200,y: 200,width: 600,height: 400))
        let result = try prepared.analyze(request: GeometryRequest(ratio: .fiveByFour,angleStrategy: .manual(degrees: 0)))
        XCTAssertEqual(result.outputSize,CGSize(width: 750,height: 600))
    }
    func testZeroMarginRoundsUpToContainSubject() throws {
        let prepared = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 1000,height: 800),version: "v1",bounds: CGRect(x: 200,y: 200,width: 601,height: 400))
        let s = try prepared.analyze(request: GeometryRequest(ratio: .fiveByFour,targetMargin: 0,angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(s.isApplicable)
        XCTAssertEqual(s.outputSize,CGSize(width: 605,height: 484))
        XCTAssertTrue(s.sourceCropRect.contains(s.subjectBounds))
    }
    func testImpossibleCenteredRatioPreservesSourceInsteadOfClipping() throws {
        let prepared = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 1000,height: 600),version: "v1",bounds: CGRect(x: 0,y: 0,width: 1000,height: 600))
        let s = try prepared.analyze(request: GeometryRequest(ratio: .fiveByFour,angleStrategy: .manual(degrees: 0)))
        XCTAssertFalse(s.isApplicable)
        XCTAssertEqual(s.sourceCropRect,CGRect(x: 0,y: 0,width: 1000,height: 600))
    }
    func testManualBoundsCannotEscapeSource() throws {
        XCTAssertThrowsError(try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 100,height: 100),version: "v1",bounds: CGRect(x: -1,y: 20,width: 30,height: 20)))
    }
    func testManualRectangleCannotPretendToProvideAutomaticWingTips() throws {
        let b = CGRect(x: 100,y: 100,width: 200,height: 160)
        let p = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 400,height: 400),version: "v1",bounds: b)
        let plan = try ButterflyCropProcessor.plan(prepared: p,adjustment: SmartCropAdjustment(manualBounds: b),ratio: .adaptive)
        XCTAssertTrue(plan.needsReview)
        XCTAssertEqual(plan.solution.angleDegrees,0)
        XCTAssertTrue(plan.solution.isApplicable)
    }
}
