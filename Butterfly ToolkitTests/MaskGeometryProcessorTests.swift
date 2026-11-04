import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

final class MaskGeometryProcessorTests: XCTestCase {
    func testExactFitRejectsOutsideExtentAndRotatedEmptyCorners() throws {
        let fixture = try Fixture(width: 100,height: 100,subject: CGRect(x: 35,y: 35,width: 30,height: 30))
        defer { fixture.remove() }
        var input = fixture.input
        input.coordinateOrigin = CGPoint(x: -20,y: -30)
        input.cropViewport = CGRect(x: -20,y: -30,width: 100,height: 100)
        let prepared = try MaskGeometryProcessor().prepare(input: input)
        var solution = try prepared.analyze(request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        try prepared.validate(solution: solution)
        solution.sourceCropRect = CGRect(x: -25,y: -30,width: 105,height: 100)
        solution.outputSize = solution.sourceCropRect.size
        XCTAssertThrowsError(try prepared.validate(solution: solution))
        solution.sourceCropRect = input.cropViewport; solution.outputSize = input.cropViewport.size
        solution.angleDegrees = 45
        XCTAssertThrowsError(try prepared.validate(solution: solution))
    }

    // These literal examples catch margin arithmetic, stretching and ratio rounding regressions.
    func testKnownAdaptiveAndSquareGeometry() throws {
        let fixture = try Fixture(width: 4000, height: 3600, subject: CGRect(x: 800,y: 900,width: 2400,height: 1800))
        defer { fixture.remove() }
        let processor = MaskGeometryProcessor()
        let prepared = try processor.prepare(input: fixture.input)
        let adaptive = try prepared.analyze(request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        let square = try prepared.analyze(request: GeometryRequest(ratio: .square, angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(adaptive.isApplicable); XCTAssertTrue(square.isApplicable)
        XCTAssertEqual(adaptive.outputSize, CGSize(width: 3000,height: 2250))
        XCTAssertEqual(square.outputSize, CGSize(width: 3000,height: 3000))
        XCTAssertEqual(square.actualMargins.left, 0.1, accuracy: 0.001)
        XCTAssertEqual(square.actualMargins.top, 0.2, accuracy: 0.001)
        XCTAssertEqual(adaptive.sourceCropRect, CGRect(x: 500,y: 675,width: 3000,height: 2250))
    }
    func test11By8Point5Uses22By17Units() throws {
        let f = try Fixture(width: 500,height: 500,subject: CGRect(x: 130,y: 160,width: 240,height: 180)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(ratio: .elevenByEightPointFive,angleStrategy: .manual(degrees: 0)))
        XCTAssertEqual(s.outputSize,CGSize(width: 308,height: 238))
        XCTAssertEqual(Int(s.outputSize.width) % 22,0); XCTAssertEqual(Int(s.outputSize.height) % 17,0)
    }
    func testAntennaeDoNotBecomeWingTips() throws {
        let f = try butterfly(); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest())
        XCTAssertTrue(s.isApplicable); XCTAssertFalse(s.reason?.contains("角度需调整") ?? false)
        XCTAssertEqual(try XCTUnwrap(s.leftWingTip).y,100,accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(s.rightWingTip).y,100,accuracy: 2)
        XCTAssertEqual(s.angleDegrees,0,accuracy: 0.2)
        XCTAssertLessThan(s.subjectBounds.minY,40)
    }
    func testLongVerticalAndSlantedAntennaeOutsideBodyExclusionDoNotBecomeWingTips() throws {
        for slanted in [false,true] {
            let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 190,y: 180,width: 20,height: 130),extras: { p in
                for y in 100..<290 { for x in 60..<190 { p[y*400+x] = 255 }; for x in 210..<340 { p[y*400+x] = 255 } }
                for y in 30..<180 {
                    let x = slanted ? 190-(180-y)/2 : 100
                    p[y*400+x] = 255; p[y*400+399-x] = 255
                }
            }); defer { f.remove() }
            let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest())
            XCTAssertEqual(try XCTUnwrap(s.leftWingTip).y,100,accuracy: 2)
            XCTAssertEqual(try XCTUnwrap(s.rightWingTip).y,100,accuracy: 2)
            XCTAssertFalse(s.reason?.contains("角度需调整") ?? false)
        }
    }
    func testSeparatedEquallyHighWingCrestsRequireReviewInsteadOfAnAirAnchor() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 190,y: 180,width: 20,height: 130),extras: { p in
            for y in 170..<290 { for x in 60..<190 { p[y*400+x] = 255 } }
            for y in 100..<170 { for x in 60..<110 { p[y*400+x] = 255 }; for x in 140..<190 { p[y*400+x] = 255 } }
            for y in 100..<290 { for x in 210..<340 { p[y*400+x] = 255 } }
        }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest())
        XCTAssertEqual(s.angleDegrees,0)
        XCTAssertTrue(s.reason?.contains("角度需调整") ?? false)
        let manual = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .twoPoints(left: CGPoint(x: 80,y: 100),right: CGPoint(x: 300,y: 100))))
        XCTAssertFalse(manual.reason?.contains("角度需调整") ?? false)
    }
    func testBackgroundEntryReturnsGeometryAndHonorsCancellation() async throws {
        let f = try Fixture(width: 100,height: 100,subject: CGRect(x: 20,y: 20,width: 60,height: 60)); defer { f.remove() }
        let request = GeometryRequest(angleStrategy: .manual(degrees: 0))
        let s = try await MaskGeometryProcessor().analyzeInBackground(input: f.input,request: request)
        XCTAssertEqual(s.outputSize,CGSize(width: 75,height: 75))
        let cancelled = Task { try await MaskGeometryProcessor().analyzeInBackground(input: f.input,request: request) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled CPU work published a solution") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }
    func testDamagedWingRequiresReview() throws {
        let f = try butterfly(damaged: true); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest())
        XCTAssertEqual(s.angleDegrees,0); XCTAssertNotNil(s.reason)
        let manual = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .twoPoints(left: CGPoint(x: 60,y: 100),right: CGPoint(x: 340,y: 100))))
        XCTAssertTrue(manual.isApplicable); XCTAssertFalse(manual.reason?.contains("角度需调整") ?? false)
    }
    func testFullBoundsKeepTailAndFineHair() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 100,y: 100,width: 200,height: 180),extras: { p in
            for y in 280..<340 { p[y*400+200] = 2 }
            for x in 70..<100 { p[150*400+x] = 1 }
            p[0] = 1; p[399*400+399] = 255
        }); defer { f.remove() }
        let support = try MaskGeometryProcessor().prepare(input: f.input).support
        XCTAssertEqual(support.bounds,CGRect(x: 70,y: 100,width: 230,height: 240))
        XCTAssertEqual(support.pixels[150*400+70],1); XCTAssertEqual(support.pixels[339*400+200],1)
        XCTAssertEqual(support.pixels[0],0); XCTAssertEqual(support.pixels[399*400+399],0)
    }
    func testDetachedOpaqueWeakAndDiagonalDetailsRemainInCompleteBounds() throws {
        // Each small fragment is below the previous size threshold; no full-subject crop may drop it.
        let cases: [([(Int,Int)],UInt8,CGRect)] = [
            ((60..<80).map { ($0,80) },255,CGRect(x: 60,y: 80,width: 240,height: 200)),
            ((50..<80).map { (70,$0) },2,CGRect(x: 70,y: 50,width: 230,height: 230)),
            ((0..<20).map { (60+$0,60+$0) },1,CGRect(x: 60,y: 60,width: 240,height: 220)),
            ([(50,50),(51,50),(50,51),(51,51)],255,CGRect(x: 50,y: 50,width: 250,height: 230)),
            ((0..<120).map { step in
                let angle = Double(step)*2*Double.pi/120
                return (Int(round(60+14*cos(angle))),Int(round(60+14*sin(angle))))
            },1,CGRect(x: 46,y: 46,width: 254,height: 234))
        ]
        for (detail,alpha,bounds) in cases {
            let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 100,y: 100,width: 200,height: 180),extras: { p in
                for (x,y) in detail { p[y*400+x] = alpha }
                p[0] = 1; p[1] = 1; p[399*400+399] = 255
                for (x,y) in [(397,0),(398,0),(399,0),(398,1),(399,1)] { p[y*400+x] = 1 }
            }); defer { f.remove() }
            let prepared = try MaskGeometryProcessor().prepare(input: f.input)
            XCTAssertEqual(prepared.support.bounds,bounds)
            XCTAssertEqual(prepared.support.componentCount,2)
            for (x,y) in detail { XCTAssertEqual(prepared.support.pixels[y*400+x],1) }
            XCTAssertEqual(prepared.support.pixels[0],0); XCTAssertEqual(prepared.support.pixels[399*400+399],0)
            let s = try prepared.analyze(request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 0)))
            XCTAssertTrue(s.isApplicable); XCTAssertEqual(s.sourceCropRect,bounds)
            XCTAssertNotNil(s.reason,"Detached uncertain detail must remain visible to reviewers")
        }
    }
    func testDetachedWeakDetailDoesNotMoveAutomaticWingProfile() throws {
        let baseline = try butterfly(); defer { baseline.remove() }
        let detailed = try butterfly(extra: { p in for x in 10..<30 { p[40*400+x] = 1 } }); defer { detailed.remove() }
        let processor = MaskGeometryProcessor(),request = GeometryRequest()
        let before = try processor.analyze(input: baseline.input,request: request)
        let prepared = try processor.prepare(input: detailed.input)
        let after = try prepared.analyze(request: request)
        XCTAssertEqual(after.leftWingTip,before.leftWingTip); XCTAssertEqual(after.rightWingTip,before.rightWingTip)
        XCTAssertLessThan(prepared.support.bounds.minX,prepared.support.wingBounds.minX)
        XCTAssertEqual(prepared.support.detachedDetailCount,1)
        XCTAssertTrue(after.reason?.contains("分离细节") ?? false)
        XCTAssertFalse(after.reason?.contains("角度需调整") ?? false)
    }
    func testRotatedCropKeepsDetachedDetail() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 100,y: 100,width: 200,height: 180),extras: { p in
            for x in 60..<80 { p[80*400+x] = 2 }
        }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 90)))
        XCTAssertTrue(s.isApplicable)
        XCTAssertEqual(s.subjectBounds,CGRect(x: 120,y: 60,width: 200,height: 240))
        XCTAssertEqual(s.sourceCropRect,s.subjectBounds)
    }
    func testAutomaticAngleWarningDoesNotHideInsufficientDisplacedPadding() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 0,y: 100,width: 200,height: 200)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest())
        XCTAssertTrue(s.isApplicable); XCTAssertEqual(s.actualMargins.left,0)
        XCTAssertTrue(s.reason?.contains("角度需调整") ?? false)
        XCTAssertTrue(s.reason?.contains("留白不足") ?? false)
    }
    func testInapplicableGeometryPreservesCurrentViewportAndFullHiddenSourceBounds() throws {
        let viewport = CGRect(x: 0,y: 0,width: 200,height: 150)
        let f = try Fixture(width: 600,height: 400,subject: CGRect(x: 250,y: 150,width: 200,height: 160),origin: CGPoint(x: -200,y: -100),viewport: viewport,background: { a in a[200*600+300] = 0 }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .manual(degrees: 25)))
        XCTAssertFalse(s.isApplicable); XCTAssertEqual(s.angleDegrees,0)
        XCTAssertEqual(s.sourceCropRect,viewport); XCTAssertEqual(s.outputSize,viewport.size)
        XCTAssertEqual(s.subjectBounds,CGRect(x: 50,y: 50,width: 200,height: 160))
    }
    func testViewportPreservationDoesNotRequireOpaquePixelsOrContainmentInSourceExtent() throws {
        let viewport = CGRect(x: -250,y: -150,width: 600,height: 500)
        let f = try Fixture(width: 400,height: 300,subject: CGRect(x: 100,y: 100,width: 200,height: 100),origin: CGPoint(x: -200,y: -100),viewport: viewport,background: { a in a[150*400+150] = 0 }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        XCTAssertFalse(s.isApplicable); XCTAssertEqual(s.sourceCropRect,viewport)
        XCTAssertEqual(s.outputSize,CGSize(width: 600,height: 500))
    }
    func testFullSourceAnalysisCanExpandPastCurrentViewport() throws {
        let f = try Fixture(width: 600,height: 400,subject: CGRect(x: 250,y: 150,width: 200,height: 160),origin: CGPoint(x: -200,y: -100),viewport: CGRect(x: 0,y: 0,width: 100,height: 100)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(s.isApplicable); XCTAssertEqual(s.sourceCropRect,CGRect(x: 50,y: 50,width: 200,height: 160))
    }
    func testInvalidVisibleViewportsAreRejected() throws {
        let f = try Fixture(width: 100,height: 100,subject: CGRect(x: 20,y: 20,width: 60,height: 60)); defer { f.remove() }
        for viewport in [CGRect.zero,CGRect.infinite,CGRect(x: CGFloat.nan,y: 0,width: 100,height: 100)] {
            var input = f.input; input.cropViewport = viewport
            XCTAssertThrowsError(try MaskGeometryProcessor().prepare(input: input))
        }
    }
    func testBackgroundHolesRejectOtherwiseValidRectangle() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 100,y: 100,width: 200,height: 200),background: { a in a[150*400+150] = 0 }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        XCTAssertFalse(s.isApplicable); XCTAssertNotNil(s.reason)
    }
    func testImpossibleFixedRatioDoesNotSilentlyChangeRatio() throws {
        let f = try Fixture(width: 400,height: 200,subject: CGRect(x: 20,y: 20,width: 360,height: 160)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(ratio: .square,angleStrategy: .manual(degrees: 0)))
        XCTAssertFalse(s.isApplicable); XCTAssertNotNil(s.reason)
        XCTAssertEqual(s.sourceCropRect,CGRect(x: 0,y: 0,width: 400,height: 200))
    }
    func testInsufficientMarginCanShiftInsideValidBackground() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 0,y: 100,width: 200,height: 200)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(s.isApplicable); XCTAssertNotNil(s.reason)
        XCTAssertEqual(s.sourceCropRect.minX,0); XCTAssertGreaterThanOrEqual(s.sourceCropRect.maxX,200)
        XCTAssertGreaterThanOrEqual(s.actualMargins.left,0)
    }
    func testClockwiseRotationPivotAndNegativeCoordinateOrigin() throws {
        let f = try Fixture(width: 400,height: 300,subject: CGRect(x: 100,y: 100,width: 200,height: 100),origin: CGPoint(x: -250,y: -200)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 90)))
        XCTAssertTrue(s.isApplicable); XCTAssertEqual(s.sourceVersion,"saved-v1")
        XCTAssertEqual(s.rotationPivot,CGPoint(x: -50,y: -50))
        XCTAssertEqual(s.subjectBounds,CGRect(x: -100,y: -150,width: 100,height: 200))
        XCTAssertEqual(s.sourceCropRect,s.subjectBounds)
    }
    func testTwoPointsUsesSourceCoordinatesAndBypassesAutomaticEstimator() throws {
        let f = try Fixture(width: 400,height: 400,subject: CGRect(x: 150,y: 150,width: 100,height: 100),origin: CGPoint(x: -200,y: -200)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .twoPoints(left: CGPoint(x: -50,y: -20),right: CGPoint(x: 50,y: 20))))
        XCTAssertTrue(s.isApplicable); XCTAssertEqual(s.angleDegrees,-21.801409,accuracy: 0.00001)
        XCTAssertEqual(s.leftWingTip,CGPoint(x: -50,y: -20)); XCTAssertNil(s.reason)
    }
    func testRotationCornersAndInternalAlphaUseAlphaNotDarkRGB() throws {
        let f = try Fixture(width: 200,height: 200,subject: CGRect(x: 60,y: 60,width: 80,height: 80)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(ratio: .square,targetMargin: 0.25,angleStrategy: .manual(degrees: 45)))
        XCTAssertTrue(s.isApplicable); XCTAssertNotNil(s.reason)
        XCTAssertLessThan(s.outputSize.width,200)
        XCTAssertGreaterThanOrEqual(s.sourceCropRect.minX,29)
    }
    func testTopLeftRowsAndOffsetAreNotFlipped() throws {
        let f = try Fixture(width: 200,height: 300,subject: CGRect(x: 30,y: 40,width: 80,height: 60),origin: CGPoint(x: -400,y: 25)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 0)))
        XCTAssertEqual(s.subjectBounds,CGRect(x: -370,y: 65,width: 80,height: 60))
        XCTAssertEqual(s.sourceCropRect,s.subjectBounds)
    }
    func testFiveByFourKeepsIntegerRatioWhenMarginIsReduced() throws {
        let f = try Fixture(width: 220,height: 200,subject: CGRect(x: 10,y: 20,width: 200,height: 160)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(ratio: .fiveByFour,angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(s.isApplicable); XCTAssertNotNil(s.reason)
        XCTAssertEqual(s.outputSize,CGSize(width: 220,height: 176))
    }
    func testRotatedBackgroundHoleInsideSubjectRectangleIsRejected() throws {
        let f = try Fixture(width: 200,height: 200,subject: CGRect(x: 60,y: 60,width: 80,height: 80),background: { a in a[100*200+100] = 0 }); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: 0,angleStrategy: .manual(degrees: 10)))
        XCTAssertFalse(s.isApplicable); XCTAssertEqual(s.angleDegrees,0)
    }
    func testEmptyMaskRejectsWholeCanvasAndNoiseOnlyInput() throws {
        let f = try Fixture(width: 100,height: 100,subject: .zero,extras: { p in p[0] = 1; p[9999] = 255 }); defer { f.remove() }
        XCTAssertThrowsError(try MaskGeometryProcessor().prepare(input: f.input))
    }
    func testLargeFiniteMarginDegradesWithoutChangingRatioOrScalingSubject() throws {
        let f = try Fixture(width: 100,height: 100,subject: CGRect(x: 20,y: 20,width: 60,height: 60)); defer { f.remove() }
        let s = try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(ratio: .square,targetMargin: 0.499999999999,angleStrategy: .manual(degrees: 0)))
        XCTAssertTrue(s.isApplicable); XCTAssertNotNil(s.reason)
        XCTAssertEqual(s.outputSize,CGSize(width: 100,height: 100))
        XCTAssertEqual(s.subjectBounds.size,CGSize(width: 60,height: 60))
    }
    func testInvalidRequestsAndMismatchedImagesAreRejected() throws {
        let f = try Fixture(width: 100,height: 100,subject: CGRect(x: 20,y: 20,width: 60,height: 60)); defer { f.remove() }
        for margin in [-0.1,0.5,Double.nan] {
            XCTAssertThrowsError(try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(targetMargin: margin)))
        }
        var bad = f.input; bad.sourcePixelSize.width = 99
        XCTAssertThrowsError(try MaskGeometryProcessor().analyze(input: bad,request: GeometryRequest()))
        XCTAssertThrowsError(try MaskGeometryProcessor().analyze(input: f.input,request: GeometryRequest(angleStrategy: .twoPoints(left: .zero,right: .zero))))
    }

    // Opt-in read-only real masks; TEST_RUNNER_TASK3_EVIDENCE_DIR is forwarded by xcodebuild.
    func testRealSavedMaskEvidenceWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASK3_EVIDENCE_DIR"] else { throw XCTSkip("Real-image evidence is opt-in") }
        let evidence = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        for side in ["F","U"] {
            let root = URL(fileURLWithPath: "/tmp/butterfly-task2-real")
            let roles = try JSONDecoder().decode(RoleImages.self,from: Data(contentsOf: root.appendingPathComponent("\(side)-roles.json")))
            let saved = try JSONDecoder().decode(PSDSnapshot.self,from: Data(contentsOf: root.appendingPathComponent("\(side)-saved.json")))
            XCTAssertEqual(roles.snapshotVersion,saved.contentVersion)
            XCTAssertEqual(try AIFileValidation.hash(saved.snapshotURL.path),saved.contentVersion)
            let before = try Data(contentsOf: roles.maskPNG)
            let input = MaskGeometryInput(sourceVersion: saved.contentVersion,sourcePixelSize: roles.pixelSize,maskURL: roles.maskPNG,validBackgroundAlphaURL: roles.basePNG,coordinateOrigin: roles.coordinateOrigin,cropViewport: roles.cropViewport)
            let started = Date()
            let prepared = try MaskGeometryProcessor().prepare(input: input)
            let s = try prepared.analyze(request: GeometryRequest())
            XCTAssertTrue(s.isApplicable || s.reason != nil)
            if !s.isApplicable {
                XCTAssertEqual(s.angleDegrees,0)
                XCTAssertEqual(s.sourceCropRect,roles.cropViewport)
            }
            XCTAssertEqual(try Data(contentsOf: roles.maskPNG),before)
            let prepareSeconds = Date().timeIntervalSince(started)
            var previewTimes: [Double] = []
            for step in 0..<40 {
                let clock = Date()
                _ = try prepared.analyze(request: GeometryRequest(targetMargin: Double(step % 26)/100))
                previewTimes.append(Date().timeIntervalSince(clock))
            }
            previewTimes.sort()
            let summary: [String: Any] = ["supportBounds": [prepared.support.bounds.minX,prepared.support.bounds.minY,prepared.support.bounds.width,prepared.support.bounds.height],
                "components": prepared.support.componentCount,"detachedDetailCount": prepared.support.detachedDetailCount,"wingComponents": prepared.support.wingComponentCount,"wingBounds": [prepared.support.wingBounds.minX,prepared.support.wingBounds.minY,prepared.support.wingBounds.width,prepared.support.wingBounds.height],"prepareSeconds": prepareSeconds,"analysisP95Seconds": previewTimes[37],
                "analysisMaximumSeconds": previewTimes.last!,"note": "CPU geometry only; not interactive UI p95 or human wing-tip acceptance"]
            try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent("\(side)-support-summary.json"))
            try Data(prepared.support.pixels).write(to: evidence.appendingPathComponent("\(side)-support.gray8"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(s).write(to: evidence.appendingPathComponent("\(side)-geometry.json"))
            print("TASK3_REAL_\(side): \(Date().timeIntervalSince(started)) seconds; support \(prepared.support.bounds); angle \(s.angleDegrees); reason \(s.reason ?? "none")")
        }
    }

    private func butterfly(damaged: Bool = false,extra: ((inout [UInt8]) -> Void)? = nil) throws -> Fixture {
        try Fixture(width: 400,height: 400,subject: CGRect(x: 190,y: 180,width: 20,height: 130),extras: { p in
            for y in 100..<290 { for x in 60..<190 { p[y*400+x] = 255 } }
            for y in (damaged ? 220 : 100)..<290 { for x in 210..<340 { p[y*400+x] = 255 } }
            for y in 30..<180 { p[y*400+192] = 255; p[y*400+207] = 255 }
            extra?(&p)
        })
    }
    private struct Fixture {
        let directory: URL
        let input: MaskGeometryInput
        init(width: Int,height: Int,subject: CGRect,origin: CGPoint = .zero,viewport: CGRect? = nil,extras: ((inout [UInt8]) -> Void)? = nil,background: ((inout [UInt8]) -> Void)? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-\(UUID())")
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            var mask = [UInt8](repeating: 0,count: width*height)
            for y in Int(subject.minY)..<Int(subject.maxY) { for x in Int(subject.minX)..<Int(subject.maxX) { mask[y*width+x] = 255 } }
            extras?(&mask)
            var alpha = [UInt8](repeating: 255,count: width*height); background?(&alpha)
            let maskURL = directory.appendingPathComponent("mask.png"),baseURL = directory.appendingPathComponent("base.png")
            try Self.png(maskURL,width: width,height: height,values: mask,mask: true)
            try Self.png(baseURL,width: width,height: height,values: alpha,mask: false)
            input = MaskGeometryInput(sourceVersion: "saved-v1",sourcePixelSize: CGSize(width: width,height: height),maskURL: maskURL,validBackgroundAlphaURL: baseURL,coordinateOrigin: origin,cropViewport: viewport ?? CGRect(origin: origin,size: CGSize(width: width,height: height)))
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        private static func png(_ url: URL,width: Int,height: Int,values: [UInt8],mask: Bool) throws {
            var pixels = [UInt8](repeating: 0,count: width*height*4)
            for i in values.indices { pixels[i*4] = mask ? values[i] : 0; pixels[i*4+1] = pixels[i*4]; pixels[i*4+2] = pixels[i*4]; pixels[i*4+3] = mask ? 255 : values[i] }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
