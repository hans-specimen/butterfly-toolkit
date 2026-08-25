import CoreGraphics
import XCTest
@testable import Butterfly_Toolkit

final class ButterflyCropProcessorTests: XCTestCase {
    func testCenteredCropKeepsRequestedRatioAndPadding() throws {
        let polygon = rectanglePolygon(width: 1_000, height: 800)
        let subject = CGRect(x: 200, y: 200, width: 600, height: 400)
        let result = try XCTUnwrap(
            ButterflyCropProcessor.findCropRect(
                subjectRect: subject,
                sourcePolygon: polygon,
                aspectRatio: 5 / 4,
                preferredPadding: 0.1
            )
        )
        XCTAssertEqual(result.rect.width / result.rect.height, 5 / 4, accuracy: 0.001)
        XCTAssertTrue(result.rect.contains(subject))
        XCTAssertEqual(result.padding, 0.1, accuracy: 0.001)
        XCTAssertEqual(result.rect.midX, subject.midX, accuracy: 0.001)
        XCTAssertEqual(result.rect.midY, subject.midY, accuracy: 0.001)
    }

    func testPaddingReducesWhenSourceSpaceIsLimited() throws {
        let polygon = rectanglePolygon(width: 1_000, height: 800)
        let subject = CGRect(x: 40, y: 80, width: 920, height: 640)
        let result = try XCTUnwrap(
            ButterflyCropProcessor.findCropRect(
                subjectRect: subject,
                sourcePolygon: polygon,
                aspectRatio: 5 / 4,
                preferredPadding: 0.1
            )
        )
        XCTAssertLessThan(result.padding, 0.1)
        XCTAssertTrue(result.rect.contains(subject))
        XCTAssertEqual(result.rect.width / result.rect.height, 5 / 4, accuracy: 0.001)
    }

    func testImpossibleRatioReturnsNilInsteadOfClippingSubject() {
        let polygon = rectanglePolygon(width: 1_000, height: 600)
        let subject = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let result = ButterflyCropProcessor.findCropRect(
            subjectRect: subject,
            sourcePolygon: polygon,
            aspectRatio: 5 / 4,
            preferredPadding: 0.1
        )
        XCTAssertNil(result)
    }

    func testCropStaysInsideRotatedValidPixelPolygon() throws {
        let polygon = [
            CGPoint(x: 100, y: 0),
            CGPoint(x: 1_000, y: 100),
            CGPoint(x: 900, y: 800),
            CGPoint(x: 0, y: 700)
        ]
        let subject = CGRect(x: 250, y: 220, width: 500, height: 360)
        let result = try XCTUnwrap(
            ButterflyCropProcessor.findCropRect(
                subjectRect: subject,
                sourcePolygon: polygon,
                aspectRatio: 4 / 3,
                preferredPadding: 0.05
            )
        )
        XCTAssertTrue(result.rect.contains(subject))
        XCTAssertEqual(result.rect.width / result.rect.height, 4 / 3, accuracy: 0.001)
    }

    func testAllPublishedRatiosAreLandscapeAndStable() {
        XCTAssertEqual(CropRatio.allCases.map(\.rawValue), [
            "5:4", "11:8.5", "7:5", "4:3", "3:2"
        ])
        for ratio in CropRatio.allCases {
            XCTAssertGreaterThan(ratio.value, 1)
        }
    }

    private func rectanglePolygon(width: CGFloat, height: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: 0, y: height)
        ]
    }
}
