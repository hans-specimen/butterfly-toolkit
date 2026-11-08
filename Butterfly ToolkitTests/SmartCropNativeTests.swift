// 验证独立裁剪的蒙版格式、源坐标、预览导出一致性及文件保护。
import XCTest
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

final class SmartCropNativeTests: XCTestCase {
    func testGrayscaleJPEGCanBeRenderedAndExported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartcrop-gray-\(UUID())")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("gray.jpg"),output = directory.appendingPathComponent("cropped.jpg")
        let bytes = Data(repeating: 120,count: 40*40)
        let gray = try XCTUnwrap(CGImage(width: 40,height: 40,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: CGDataProvider(data: bytes as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        try writeJPEG(gray,to: source)
        let version = try ButterflyCropProcessor.fingerprint(source),b = CGRect(x: 8,y: 8,width: 24,height: 24)
        let geometry = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 40,height: 40),version: version,bounds: b)
        let plan = try ButterflyCropProcessor.plan(prepared: geometry,adjustment: SmartCropAdjustment(manualBounds: b,manualAngle: 0),ratio: .adaptive)
        try ButterflyCropProcessor.export(source: source,destination: output,overwrite: false,plan: plan)
        let image = try ButterflyCropProcessor.load(output)
        XCTAssertEqual(image.width,30)
        XCTAssertEqual(image.colorSpace?.model,.rgb)
    }

    func testTinyImageIsRejectedWithoutBackgroundSamplerCrash() throws {
        for size in [CGSize(width: 1,height: 1),CGSize(width: 2,height: 40),CGSize(width: 40,height: 2)] {
            let image = try XCTUnwrap(colorImage().cropping(to: CGRect(origin: .zero,size: size)))
            XCTAssertThrowsError(try ButterflySubjectDetector().detect(image))
        }
    }

    func testByteMaskHonorsPaddedRows() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,3,2,kCVPixelFormatType_OneComponent8,nil,&buffer),kCVReturnSuccess)
        let mask = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(mask,[])
        for y in 0..<2 {
            let row = CVPixelBufferGetBaseAddress(mask)!.advanced(by: y*CVPixelBufferGetBytesPerRow(mask)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<3 { row[x] = UInt8(y*100+x*30) }
        }
        CVPixelBufferUnlockBaseAddress(mask,[])
        XCTAssertEqual(try ButterflySubjectDetector.maskValues(mask),[0,30,60,100,130,160])
    }

    func testRenderUsesTopLeftCoordinatesAndClockwiseRotation() throws {
        let source = colorImage()
        let p = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 40,height: 40),version: "v1",bounds: CGRect(x: 0,y: 0,width: 40,height: 40))
        let s = try p.analyze(request: GeometryRequest(ratio: .square,targetMargin: 0,angleStrategy: .manual(degrees: 90)))
        let rendered = try ButterflyCropProcessor.render(source,sourceSize: CGSize(width: 40,height: 40),solution: s)
        XCTAssertEqual(pixel(rendered,x: 5,y: 5),[0,0,255,255])
        XCTAssertEqual(pixel(rendered,x: 35,y: 5),[255,0,0,255])
        XCTAssertEqual(pixel(rendered,x: 5,y: 35),[255,255,0,255])
        XCTAssertEqual(pixel(rendered,x: 35,y: 35),[0,255,0,255])
    }

    func testExportMatchesPlanAndProtectsChangedSourceAndExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smartcrop-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg"),output = directory.appendingPathComponent("output.jpg")
        try writeJPEG(colorImage(),to: source)
        let original = try Data(contentsOf: source),version = try ButterflyCropProcessor.fingerprint(source)
        let b = CGRect(x: 8,y: 8,width: 24,height: 24)
        let geometry = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 40,height: 40),version: version,bounds: b)
        let plan = try ButterflyCropProcessor.plan(prepared: geometry,adjustment: SmartCropAdjustment(manualBounds: b,manualAngle: 0),ratio: .adaptive)
        try ButterflyCropProcessor.export(source: source,destination: output,overwrite: false,plan: plan)
        let result = try ButterflyCropProcessor.load(output)
        XCTAssertEqual(result.width,30); XCTAssertEqual(result.height,30)
        XCTAssertEqual(try Data(contentsOf: source),original)
        let firstOutput = try Data(contentsOf: output)
        XCTAssertThrowsError(try ButterflyCropProcessor.export(source: source,destination: output,overwrite: false,plan: plan))
        XCTAssertEqual(try Data(contentsOf: output),firstOutput)
        try (original+Data([0])).write(to: source)
        XCTAssertThrowsError(try ButterflyCropProcessor.export(source: source,destination: source,overwrite: true,plan: plan))
        XCTAssertEqual(try Data(contentsOf: source),original+Data([0]))
    }

    func testEXIFOrientationIsAppliedOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smartcrop-orientation-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJPEG(colorImage(),to: url,orientation: 6)
        let normalized = try ButterflyCropProcessor.load(url)
        let topRight = pixel(normalized,x: 35,y: 5)
        XCTAssertGreaterThan(topRight[0],240); XCTAssertLessThan(topRight[1],15); XCTAssertLessThan(topRight[2],15)
    }

    func testZoomCoordinatesRejectLetterboxAndPreservePixelPositions() throws {
        let map = SmartCropCoordinates(sourceSize: CGSize(width: 600,height: 400),viewSize: CGSize(width: 1200,height: 1000))
        XCTAssertNil(map.sourcePoint(CGPoint(x: 10,y: 20)))
        XCTAssertEqual(try XCTUnwrap(map.sourcePoint(CGPoint(x: 240,y: 260))),CGPoint(x: 120,y: 80))
        XCTAssertEqual(map.viewPoint(CGPoint(x: 500,y: 300)),CGPoint(x: 1000,y: 700))
    }

    @MainActor func testEachPhotoKeepsItsOwnTipsAndRatioChangeInvalidatesConfirmation() async throws {
        let store = SmartCropStore()
        let a = URL(fileURLWithPath: "/tmp/smartcrop-missing-a.jpg"),b = URL(fileURLWithPath: "/tmp/smartcrop-missing-b.jpg")
        store.select([a,b],output: URL(fileURLWithPath: "/tmp/smartcrop-test-output"))
        store.edit { $0.tips = [CGPoint(x: 10,y: 20),CGPoint(x: 80,y: 30)] }
        store.move(1)
        XCTAssertTrue(store.adjustment.tips.isEmpty)
        store.edit { $0.manualBounds = CGRect(x: 20,y: 20,width: 30,height: 40) }
        store.move(-1)
        XCTAssertEqual(store.adjustment.tips,[CGPoint(x: 10,y: 20),CGPoint(x: 80,y: 30)])
        XCTAssertNil(store.adjustment.manualBounds)
        store.setRatio(.adaptive)
        XCTAssertFalse(store.adjustment.confirmed)
        XCTAssertNil(store.records[a]?.plan)
        store.leavePanel()
    }

    func testFloatMaskReadsPixelsInsteadOfBytes() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,4,2,kCVPixelFormatType_OneComponent32Float,nil,&buffer),kCVReturnSuccess)
        let mask = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(mask,[])
        for y in 0..<2 {
            let row = CVPixelBufferGetBaseAddress(mask)!.advanced(by: y*CVPixelBufferGetBytesPerRow(mask)).assumingMemoryBound(to: Float.self)
            for (x,value) in [Float(0),0.25,0.5,1].enumerated() { row[x] = value }
        }
        CVPixelBufferUnlockBaseAddress(mask,[])
        XCTAssertEqual(try ButterflySubjectDetector.maskValues(mask),[0,64,128,255,0,64,128,255])
    }

    func testTwoPointsAndManualBoundsUseSourceCoordinates() throws {
        let adjustment = SmartCropAdjustment(tips: [CGPoint(x: 300,y: 120),CGPoint(x: 100,y: 100)],manualBounds: CGRect(x: 100,y: 100,width: 200,height: 180))
        let prepared = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 500,height: 400),version: "v1",bounds: adjustment.manualBounds!)
        let solution = try prepared.analyze(request: adjustment.request(ratio: .fiveFour))
        XCTAssertTrue(solution.isApplicable)
        XCTAssertEqual(solution.angleDegrees,-5.710593,accuracy: 0.00001)
        XCTAssertEqual(solution.sourceCropRect.width/solution.sourceCropRect.height,1.25,accuracy: 0.0001)
        XCTAssertEqual(solution.sourceCropRect.midX,solution.subjectBounds.midX,accuracy: 0.5)
        XCTAssertEqual(solution.sourceCropRect.midY,solution.subjectBounds.midY,accuracy: 0.5)
    }

    func testNativeCropKeepsTenPercentMarginsAndIntegerRatio() throws {
        let prepared = try ButterflyCropProcessor.manualGeometry(size: CGSize(width: 1000,height: 800),version: "v1",bounds: CGRect(x: 200,y: 200,width: 600,height: 400))
        let solution = try prepared.analyze(request: GeometryRequest(ratio: .fiveByFour,angleStrategy: .manual(degrees: 0)))
        XCTAssertEqual(solution.outputSize,CGSize(width: 750,height: 600))
        XCTAssertEqual(solution.actualMargins.left,0.1,accuracy: 0.00001)
        XCTAssertEqual(solution.sourceCropRect,CGRect(x: 125,y: 100,width: 750,height: 600))
    }

    private func colorImage() -> CGImage {
        var bytes = [UInt8](repeating: 0,count: 40*40*4)
        for y in 0..<40 { for x in 0..<40 {
            let color: [UInt8] = y < 20 ? (x < 20 ? [255,0,0,255] : [0,255,0,255]) : (x < 20 ? [0,0,255,255] : [255,255,0,255])
            for c in 0..<4 { bytes[(y*40+x)*4+c] = color[c] }
        } }
        return CGImage(width: 40,height: 40,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
    private func pixel(_ image: CGImage,x: Int,y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0,count: image.width*image.height*4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }
        let i = (y*image.width+x)*4; return Array(bytes[i..<i+4])
    }
    private func writeJPEG(_ image: CGImage,to url: URL,orientation: Int = 1) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation: orientation,kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
