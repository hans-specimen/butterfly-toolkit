// 用独立合成像素验证残留分类与真实细节保护，不依赖用户照片。
import XCTest
@testable import Butterfly_Toolkit

final class MaskResidueCleanupTests: XCTestCase {
    private func fixture() -> [UInt8] {
        var values = [UInt8](repeating: 0,count: 400*400)
        for y in 100..<280 { for x in 100..<300 { values[y*400+x] = 255 } }
        return values
    }
    func testLargeRemoteHazeIsRemoved() throws {
        for count in [615,738] {
            var values = fixture()
            for i in 0..<count { values[(330+i/30)*400+20+i%30] = i%13 == 0 ? 23 : 4 }
            let cleaned = try MaskResidueCleanup.clean(values,width: 400,height: 400)
            XCTAssertEqual(cleaned,fixture(),"Remote haze with \(count) pixels must not change the subject")
        }
    }
    func testEdgeBandWithBrightSpecksIsRemoved() throws {
        var values = fixture()
        for y in 395..<400 { for x in 5..<390 { values[y*400+x] = x%61 == 0 ? 110 : 13 } }
        XCTAssertEqual(try MaskResidueCleanup.clean(values,width: 400,height: 400),fixture())
    }
    func testTouchingEdgeSubjectSurvives() throws {
        var values = fixture()
        for y in 0..<100 { values[y*400+200] = 2 }
        for y in 0..<25 { for x in 100..<160 { values[y*400+x] = 180 } }
        XCTAssertEqual(try MaskResidueCleanup.clean(values,width: 400,height: 400),values)
    }
    func testDetachedAntennaAndTranslucentWingSurvive() throws {
        var values = fixture()
        for y in 110..<180 { values[y*400+97] = 1 }
        for y in 320..<345 { for x in 220..<270 { values[y*400+x] = 40 } }
        XCTAssertEqual(try MaskResidueCleanup.clean(values,width: 400,height: 400),values)
    }
    func testMultipleTrustedComponentsSurvive() throws {
        var values = fixture()
        for y in 320..<370 { for x in 20..<80 { values[y*400+x] = 200 } }
        XCTAssertEqual(try MaskResidueCleanup.clean(values,width: 400,height: 400),values)
    }
    func testCleanupIsIdempotentAndSupportMatchesEveryNonzeroAlphaPixel() throws {
        var values = fixture()
        for y in 330..<360 { for x in 20..<45 { values[y*400+x] = 4 } }
        values[80*400+80] = 96
        let first = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
        let second = try MaskResidueCleanup.analyze(first.alpha,width: 400,height: 400)
        XCTAssertEqual(first.alpha,second.alpha)
        XCTAssertEqual(first.subjectSupport,first.alpha.map { $0 > 0 ? 1 : 0 })
        XCTAssertTrue(zip(values,first.alpha).allSatisfy { $1 == 0 || $0 == $1 })
        XCTAssertEqual(first.report.removedPixelCount,750)
        XCTAssertTrue(first.report.regions.contains { $0.decision == .removedBackground && $0.reason == .remoteHaze })
    }
    func testWeakBridgeIsRetainedAndFlagged() throws {
        var values = fixture()
        for y in 280..<396 { values[y*400+200] = 1 }
        for bandAlpha: UInt8 in [5,40,110] {
            for x in 0..<400 { values[395*400+x] = bandAlpha }
            let result = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
            XCTAssertEqual(result.alpha,values)
            let region = try XCTUnwrap(result.report.regions.first { $0.decision == .uncertain && $0.reason == .ambiguousConnection })
            XCTAssertGreaterThan(region.bounds.minY,280,"Highlight the suspect connection, not the whole subject")
        }
    }
    func testNoReliableCoreDoesNotDelete() throws {
        let values = [UInt8](repeating: 3,count: 10000)
        let result = try MaskResidueCleanup.analyze(values,width: 100,height: 100)
        XCTAssertEqual(result.alpha,values)
        XCTAssertEqual(result.report.regions.first?.reason,.noReliableCore)
    }
    func testContourProtectionDoesNotUseBoundingRectangle() throws {
        var values = [UInt8](repeating: 0,count: 400*400)
        for y in 80..<300 { for x in 80..<120 { values[y*400+x] = 255 } }
        for y in 260..<300 { for x in 80..<320 { values[y*400+x] = 255 } }
        for y in 100..<125 { for x in 260..<290 { values[y*400+x] = 4 } }
        let result = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
        XCTAssertEqual(result.report.removedPixelCount,750)
        XCTAssertEqual(result.alpha[100*400+260],0)
        XCTAssertEqual(result.alpha[100*400+80],255)
    }
    func testThinRemoteWeakDetailIsUncertainAndRetained() throws {
        var values = fixture()
        for y in 320..<350 { values[y*400+80] = 1 }
        let result = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
        XCTAssertEqual(result.alpha,values)
        XCTAssertTrue(result.report.regions.contains { $0.decision == .uncertain })
    }
    func testInvalidDimensionsAndCancellation() async throws {
        XCTAssertThrowsError(try MaskResidueCleanup.analyze([],width: Int.max,height: 2))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MaskResidueCleanup.analyze(fixture(),width: 400,height: 400)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {}
    }

    func testEdgeBandDistributionAcrossSizesAndRotations() throws {
        for size in [400,800] { for rotate in [false,true] {
            var values = [UInt8](repeating: 0,count: size*size),expected = values
            func index(_ x: Int,_ y: Int) -> Int { rotate ? x*size+(size-1-y) : y*size+x }
            for y in size/4..<size*3/4 { for x in size/4..<size*3/4 { expected[index(x,y)] = 255 } }
            values = expected
            for y in (size-max(3,size/200))..<size { for x in 10..<size-10 {
                values[index(x,y)] = x%20 == 0 ? 110 : (x%20 < 4 ? 44 : 3)
            } }
            let result = try MaskResidueCleanup.analyze(values,width: size,height: size)
            XCTAssertEqual(result.alpha,expected)
        } }
    }
    func testStrongerEdgeFragmentIsNotBackground() throws {
        var values = fixture()
        for x in 10..<390 { values[399*400+x] = 40 }
        XCTAssertEqual(try MaskResidueCleanup.clean(values,width: 400,height: 400),values)
    }

    func testDetachedTouchingEdgeAntennaSurvivesInBothOrientations() throws {
        for rotate in [false,true] {
            var values = fixture()
            for x in 20..<80 { values[rotate ? x*400 : x] = 2 }
            let result = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
            XCTAssertEqual(result.alpha,values)
            XCTAssertTrue(result.report.regions.contains { $0.decision == .uncertain })
        }
    }

    func testProtectionBandBoundarySurvivesTranslation() throws {
        for offset in [0,20] {
            var values = [UInt8](repeating: 0,count: 400*400)
            for y in 100..<280 { for x in (100+offset)..<(300+offset) { values[y*400+x] = 255 } }
            for y in 120..<122 { for x in (96+offset)..<(98+offset) { values[y*400+x] = 2 } }
            let expected = values
            for y in 160..<162 { for x in (93+offset)..<(95+offset) { values[y*400+x] = 2 } }
            let result = try MaskResidueCleanup.analyze(values,width: 400,height: 400)
            XCTAssertEqual(result.alpha,expected)
            XCTAssertEqual(result.report.removedPixelCount,4)
        }
    }

}
