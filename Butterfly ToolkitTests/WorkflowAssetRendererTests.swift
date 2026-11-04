import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

final class WorkflowAssetRendererTests: XCTestCase {
    func testSquareSizesMarginsAndPureBackgrounds() throws {
        let f = try Fixture(); defer { f.remove() }
        let renderer = WorkflowAssetRenderer()
        try renderer.render4K(roles: f.roles, layout: .png4k, destination: f.url("4k.png"))
        let four = try WorkflowRaster.read(f.url("4k.png"))
        XCTAssertEqual(four.size, CGSize(width: 4096,height: 4096))
        assertBounds(bounds(four, alpha: true), CGRect(x: 256,y: 256,width: 3584,height: 3584))
        XCTAssertEqual(Array(four.pixels[0..<4]), [0,0,0,0])
        try renderer.renderWhite1K(source4K: f.url("4k.png"), destination: f.url("white.png"))
        let white = try WorkflowRaster.read(f.url("white.png"))
        XCTAssertEqual(white.size, CGSize(width: 1000,height: 1000))
        assertBounds(bounds(white, alpha: false), CGRect(x: 10,y: 10,width: 980,height: 980))
        XCTAssertEqual(Array(white.pixels[0..<4]), [255,255,255,255])
        try renderer.renderFootage(source4K: f.url("4k.png"), destination: f.url("footage.png"))
        XCTAssertEqual(try WorkflowRaster.read(f.url("footage.png")).size, CGSize(width: 3584,height: 3584))
    }
    func testLongTailFullSupportAndLatestMaskWithoutDoublePremultiplication() throws {
        let f = try Fixture(subject: CGRect(x: 30,y: 30,width: 40,height: 20), detail: true); defer { f.remove() }
        let renderer = WorkflowAssetRenderer()
        try renderer.render4K(roles: f.roles, layout: .png4k, destination: f.url("tail.png"))
        let r = try WorkflowRaster.read(f.url("tail.png")), b = try XCTUnwrap(bounds(r,alpha: true))
        XCTAssertEqual(b.minY,256,accuracy: 1); XCTAssertEqual(b.maxY,3840,accuracy: 1); XCTAssertGreaterThan(b.minX,256)
        // Role extraction already applied the latest mask. Do not premultiply a second time.
        let samples = stride(from: 0,to: r.pixels.count,by: 4).filter { r.pixels[$0+3] == 128 }
        XCTAssertFalse(samples.isEmpty)
        for i in samples.prefix(20) {
            XCTAssertEqual(Int(r.pixels[i]),100,accuracy: 2)
            XCTAssertEqual(Int(r.pixels[i+1]),40,accuracy: 2)
            XCTAssertEqual(Int(r.pixels[i+2]),20,accuracy: 2)
        }
        try renderer.renderWhite1K(source4K: f.url("tail.png"),destination: f.url("white.png"))
        let white = try WorkflowRaster.read(f.url("white.png"))
        let wb = try XCTUnwrap(bounds(white,alpha: false))
        XCTAssertEqual(wb.minY,10,accuracy: 1); XCTAssertEqual(wb.maxY,990,accuracy: 1); XCTAssertGreaterThan(wb.minX,10)
        // White hairs remain white through alpha and compositing; no dark/white color fringe.
        let hair = stride(from: 0,to: r.pixels.count,by: 4).filter { r.pixels[$0+3] > 0 && r.pixels[$0] == r.pixels[$0+3] }
        XCTAssertFalse(hair.isEmpty)
    }
    func testLayoutRetainsDetachedDetailButDoesNotFitIsolatedCornerNoise() throws {
        let f = try Fixture(); defer { f.remove() }
        var mask = try WorkflowRaster.read(f.roles.maskPNG).pixels
        var cutout = try WorkflowRaster.read(f.roles.cutoutPNG).pixels
        for (x,y,a) in [(90,50,16),(91,50,16),(0,0,1)] {
            let p = (y*100+x)*4
            for c in 0..<3 { mask[p+c] = UInt8(a) }
            cutout[p] = UInt8(200*a/255); cutout[p+1] = UInt8(80*a/255); cutout[p+2] = UInt8(40*a/255); cutout[p+3] = UInt8(a)
        }
        try Self.write(f.roles.maskPNG,width: 100,height: 100,pixels: mask)
        try Self.write(f.roles.cutoutPNG,width: 100,height: 100,pixels: cutout)
        try WorkflowAssetRenderer().render4K(roles: f.roles,layout: .png4k,destination: f.url("detached.png"))
        let r = try WorkflowRaster.read(f.url("detached.png"))
        assertBounds(bounds(r,alpha: true),CGRect(x: 256,y: 554.6666667,width: 3584,height: 2986.6666667))
    }
    func testHDUsesBaseRoleAndCurrentViewportAtNegativeOrigin() throws {
        let f = try Fixture(); defer { f.remove() }
        var roles = f.roles
        roles.coordinateOrigin = CGPoint(x: -20,y: -30)
        roles.editableExtent = CGRect(x: -20,y: -30,width: 100,height: 100)
        roles.cropViewport = CGRect(x: 0,y: 0,width: 35,height: 21)
        var gradient = [UInt8]()
        for y in 0..<100 { for x in 0..<100 { gradient += [UInt8(x*2),UInt8(y*2),221,255] } }
        try Self.write(roles.basePNG,width: 100,height: 100,pixels: gradient)
        try WorkflowAssetRenderer().renderHD(roles: roles,destination: f.url("hd.jpg"))
        let hd = try WorkflowRaster.read(f.url("hd.jpg"))
        XCTAssertEqual(hd.size,CGSize(width: 35,height: 21))
        XCTAssertEqual(Int(hd.pixels[0]),40,accuracy: 3)
        XCTAssertEqual(Int(hd.pixels[1]),60,accuracy: 3)
        XCTAssertEqual(Int(hd.pixels[2]),221,accuracy: 3)
    }
    func testHDRejectsTransparentCornerAndInternalHoleButAllowsPixelsOutsideViewport() throws {
        let f = try Fixture(); defer { f.remove() }
        var pixels = [UInt8]()
        for _ in 0..<10000 { pixels += [22,123,221,255] }
        pixels[0] = 0; pixels[1] = 0; pixels[2] = 0; pixels[3] = 0
        try Self.write(f.roles.basePNG,width: 100,height: 100,pixels: pixels)
        XCTAssertThrowsError(try WorkflowAssetRenderer().renderHD(roles: f.roles,destination: f.url("empty-corner.jpg")))
        var cropped = f.roles; cropped.cropViewport = CGRect(x: 10,y: 10,width: 20,height: 20)
        try WorkflowAssetRenderer().renderHD(roles: cropped,destination: f.url("valid-crop.jpg"))
        let center = (20*100+20)*4
        pixels[center] = 11; pixels[center+1] = 61; pixels[center+2] = 110; pixels[center+3] = 128
        try Self.write(f.roles.basePNG,width: 100,height: 100,pixels: pixels)
        XCTAssertThrowsError(try WorkflowAssetRenderer().renderHD(roles: cropped,destination: f.url("hole.jpg")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url("hole.jpg").path))
    }
    func testHDRejectsActualBaseSizeAndOrientationMismatch() throws {
        let f = try Fixture(); defer { f.remove() }
        var roles = f.roles; roles.pixelSize.width = 101; roles.editableExtent.size.width = 101
        XCTAssertThrowsError(try WorkflowAssetRenderer().renderHD(roles: roles,destination: f.url("size.jpg")))
        let pixels = try WorkflowRaster.read(f.roles.basePNG).pixels
        try Self.write(f.roles.basePNG,width: 100,height: 100,pixels: pixels,orientation: 3)
        XCTAssertThrowsError(try WorkflowAssetRenderer().renderHD(roles: f.roles,destination: f.url("orientation.jpg")))
    }
    func testCustomLayoutCenterUsesTopLeftCoordinates() throws {
        let f = try Fixture(); defer { f.remove() }
        let layout = SquareLayout(canvasSide: 4096,safeMargin: 512,center: CGPoint(x: 2048,y: 1700))
        try WorkflowAssetRenderer().render4K(roles: f.roles,layout: layout,destination: f.url("offset.png"))
        let r = try WorkflowRaster.read(f.url("offset.png"))
        assertBounds(bounds(r,alpha: true),CGRect(x: 512,y: 164,width: 3072,height: 3072))
    }
    func testMissingWatermarkOnlyFailsXianyu() throws {
        let f = try Fixture(); defer { f.remove() }
        let r = WorkflowAssetRenderer()
        try r.render4K(roles: f.roles,layout: .png4k,destination: f.url("4k.png"))
        XCTAssertThrowsError(try r.renderXianyu(source4K: f.url("4k.png"),watermark: f.url("absent.png"),destination: f.url("x.png")))
        try r.renderWhite1K(source4K: f.url("4k.png"),destination: f.url("w.png"))
        try r.renderFootage(source4K: f.url("4k.png"),destination: f.url("f.png"))
        try Self.write(f.url("mark.png"),width: 2,height: 2,pixels: [UInt8](repeating: 0,count: 16))
        try r.renderXianyu(source4K: f.url("4k.png"),watermark: f.url("mark.png"),destination: f.url("x.png"))
        let x = try WorkflowRaster.read(f.url("x.png"))
        XCTAssertEqual(x.size,CGSize(width: 2000,height: 2000)); XCTAssertEqual(Array(x.pixels[0..<4]),[238,238,238,255])
    }
    func testForeignSameNameIsConflict() throws {
        let f = try Fixture(); defer { f.remove() }
        let a = f.artifact
        try FileManager.default.copyItem(at: f.roles.basePNG,to: a.url)
        let before = try Data(contentsOf: a.url)
        XCTAssertThrowsError(try WorkflowArtifactStore().publish(temp: f.roles.cutoutPNG,artifact: a))
        XCTAssertEqual(try Data(contentsOf: a.url),before)
    }
    func testPublishValidatesDecodedImage() throws {
        let f = try Fixture(); defer { f.remove() }
        try Data("not an image".utf8).write(to: f.url("bad.png"))
        XCTAssertThrowsError(try WorkflowArtifactStore().publish(temp: f.url("bad.png"),artifact: f.artifact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.artifact.url.path))
        // Valid image with wrong fixed preset dimensions must also be rejected.
        var wrong = f.artifact; wrong.kind = .png4k
        XCTAssertThrowsError(try WorkflowArtifactStore().publish(temp: f.roles.cutoutPNG,artifact: wrong))
    }
    func testInterruptedReceiptAdoptsOnlyExactPublishedBytesAndRecipe() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = WorkflowArtifactStore()
        let first = try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)
        let receipt = f.root.appendingPathComponent(".published.png.workflow.json")
        // Reconstruct the durable state immediately before the final receipt/manifest update.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        try JSONSerialization.data(withJSONObject: ["pending":encoded]).write(to: receipt,options: .atomic)
        XCTAssertEqual(try store.recover(artifact: f.artifact),first)
        var next = f.artifact; next.presetFingerprint = "new-preset"
        XCTAssertNil(try store.recover(artifact: next))
        next.fileFingerprint = "incorrect"
        XCTAssertThrowsError(try store.publish(temp: f.roles.basePNG,artifact: next))
        XCTAssertEqual(try AIFileValidation.hash(first.url.path),first.fileFingerprint)
        XCTAssertEqual(try store.recover(artifact: f.artifact),first)
    }
    func testIdenticalPixelsCanBePublishedForANewerRecipe() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = WorkflowArtifactStore()
        let first = try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)
        var newer = f.artifact; newer.sourceFingerprint = "new-saved-version-same-pixels"
        let second = try store.publish(temp: f.roles.cutoutPNG,artifact: newer)
        XCTAssertEqual(second.fileFingerprint,first.fileFingerprint)
        XCTAssertEqual(try store.recover(artifact: newer),second)
    }
    func testInterruptedIdenticalContentPreservesPreviousRecipeOnRecoveryAndRetry() throws {
        for retry in [false,true] {
            let f = try Fixture(); defer { f.remove() }
            let store = WorkflowArtifactStore()
            let first = try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)
            var newer = first; newer.sourceFingerprint = "new-source-same-pixels"; newer.presetFingerprint = "new-preset-same-pixels"
            let committed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
            let pending = try JSONSerialization.jsonObject(with: JSONEncoder().encode(newer))
            // Actual old crash window: new recipe exposed, old recipe not archived, bytes identical.
            try JSONSerialization.data(withJSONObject: ["committed":committed,"pending":pending])
                .write(to: f.root.appendingPathComponent(".published.png.workflow.json"),options: .atomic)
            let result = try retry ? store.publish(temp: f.roles.cutoutPNG,artifact: newer) : XCTUnwrap(store.recover(artifact: newer))
            XCTAssertEqual(result,newer)
            let all = FileManager.default.enumerator(at: f.root,includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
            let originals = try all.filter { $0.lastPathComponent == "artifact.json" }.filter {
                try JSONDecoder().decode(WorkflowArtifact.self,from: Data(contentsOf: $0)) == first
            }
            XCTAssertFalse(originals.isEmpty,"Old recipe lost after \(retry ? "retry" : "recovery")")
            for record in originals {
                let image = record.deletingLastPathComponent().appendingPathComponent(first.url.lastPathComponent)
                XCTAssertEqual(try AIFileValidation.hash(image.path),first.fileFingerprint)
                XCTAssertEqual(try WorkflowRaster.read(image).size,CGSize(width: 100,height: 100))
            }
            XCTAssertEqual(try store.recover(artifact: newer),newer)
        }
    }
    func testInterruptedIdenticalContentRejectsForeignReceiptState() throws {
        for foreignPending in [false,true] {
            let f = try Fixture(); defer { f.remove() }
            let store = WorkflowArtifactStore()
            let first = try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)
            var foreign = first; foreign.ownerTaskID = UUID()
            let committed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreignPending ? first : foreign))
            let pending = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreignPending ? foreign : first))
            try JSONSerialization.data(withJSONObject: ["committed":committed,"pending":pending])
                .write(to: f.root.appendingPathComponent(".published.png.workflow.json"),options: .atomic)
            XCTAssertThrowsError(try store.recover(artifact: first))
            XCTAssertThrowsError(try store.publish(temp: f.roles.cutoutPNG,artifact: first))
            XCTAssertEqual(try AIFileValidation.hash(first.url.path),first.fileFingerprint)
        }
    }
    func testStaleMaskAndOutsideLayoutAreRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        var mask = [UInt8](repeating: 255,count: 100*100*4)
        mask[0] = 0; mask[1] = 0; mask[2] = 0
        try Self.write(f.roles.maskPNG,width: 100,height: 100,pixels: mask)
        XCTAssertThrowsError(try WorkflowAssetRenderer().render4K(roles: f.roles,layout: .png4k,destination: f.url("stale.png")))
        let good = try Fixture(); defer { good.remove() }
        var layout = SquareLayout.png4k; layout.center = .zero
        XCTAssertThrowsError(try WorkflowAssetRenderer().render4K(roles: good.roles,layout: layout,destination: good.url("outside.png")))
    }
    func testPublishRecoveryOwnershipVersionAndPreservedOldOutput() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = WorkflowArtifactStore()
        try FileManager.default.copyItem(at: f.roles.basePNG,to: f.url("one.png"))
        let first = try store.publish(temp: f.url("one.png"),artifact: f.artifact)
        XCTAssertEqual(first.fileFingerprint,try AIFileValidation.hash(first.url.path)); XCTAssertEqual(first.state,.completed)
        // Manifest can still have pending/empty hash after file publication; durable receipt adopts exact version.
        XCTAssertEqual(try store.recover(artifact: f.artifact), first)
        var foreign = f.artifact; foreign.ownerTaskID = UUID()
        XCTAssertThrowsError(try store.recover(artifact: foreign))
        var newer = f.artifact; newer.sourceFingerprint = "saved-2"
        XCTAssertNil(try store.recover(artifact: newer))
        try FileManager.default.copyItem(at: f.roles.cutoutPNG,to: f.url("two.png"))
        let second = try store.publish(temp: f.url("two.png"),artifact: newer)
        XCTAssertNotEqual(second.fileFingerprint,first.fileFingerprint)
        let all = FileManager.default.enumerator(at: f.root,includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        XCTAssertTrue(all.contains { $0 != second.url && (try? AIFileValidation.hash($0.path)) == first.fileFingerprint })
        // Tampering invalidates adoption and must not be overwritten on retry.
        try Data("foreign replacement".utf8).write(to: second.url)
        XCTAssertThrowsError(try store.recover(artifact: newer))
        XCTAssertThrowsError(try store.publish(temp: f.roles.basePNG,artifact: newer))
    }

    private func assertBounds(_ actual: CGRect?,_ expected: CGRect,file: StaticString = #filePath,line: UInt = #line) {
        guard let actual else { XCTFail("Missing subject",file: file,line: line); return }
        for (a,e) in [(actual.minX,expected.minX),(actual.minY,expected.minY),(actual.maxX,expected.maxX),(actual.maxY,expected.maxY)] { XCTAssertEqual(a,e,accuracy: 1,file: file,line: line) }
    }
    private func bounds(_ raster: WorkflowRaster,alpha: Bool) -> CGRect? {
        let w = Int(raster.size.width),h = Int(raster.size.height)
        var x0 = w,y0 = h,x1 = 0,y1 = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            if alpha ? raster.pixels[i+3] > 2 : raster.pixels[i..<i+3].contains(where: { $0 < 250 }) {
                x0 = min(x0,x); y0 = min(y0,y); x1 = max(x1,x+1); y1 = max(y1,y+1)
            }
        } }
        return x1 > x0 ? CGRect(x: x0,y: y0,width: x1-x0,height: y1-y0) : nil
    }
    nonisolated static func write(_ url: URL,width: Int,height: Int,pixels: [UInt8],orientation: Int = 1) throws {
        let data = Data(pixels) as CFData
        let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:orientation] as CFDictionary); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    struct Fixture {
        let root: URL
        var roles: RoleImages
        var artifact: WorkflowArtifact { WorkflowArtifact(ownerTaskID: UUID(uuidString:"11111111-1111-1111-1111-111111111111")!,kind: .footage,url: url("published.png"),sourceFingerprint:"saved-1",presetFingerprint:"trim-v1",fileFingerprint:"",state:.pending) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        init(subject: CGRect = CGRect(x: 20,y: 20,width: 60,height: 60),detail: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            roles = RoleImages(snapshotVersion:"saved-1",basePNG:root.appendingPathComponent("base.png"),cutoutPNG:root.appendingPathComponent("cutout.png"),maskPNG:root.appendingPathComponent("mask.png"),pixelSize:CGSize(width:100,height:100),coordinateOrigin:.zero,editableExtent:CGRect(x:0,y:0,width:100,height:100),cropViewport:CGRect(x:0,y:0,width:100,height:100))
            var base = [UInt8](),cutout = [UInt8](),mask = [UInt8]()
            for y in 0..<100 { for x in 0..<100 {
                let body = subject.contains(CGPoint(x:x,y:y)),tail = detail && x == 50 && y >= 50 && y < 90
                let hair = detail && x == 31 && y >= 31 && y < 49
                let a: UInt8 = body ? (detail ? 128 : 255) : ((tail || hair) ? 16 : 0)
                base += [22,123,221,255]
                // Saved role cutout is premultiplied and already includes the current mask.
                cutout += hair ? [a,a,a,a] : [UInt8(Int(a)*200/255),UInt8(Int(a)*80/255),UInt8(Int(a)*40/255),a]
                mask += [a,a,a,255]
            } }
            try WorkflowAssetRendererTests.write(roles.basePNG,width:100,height:100,pixels:base)
            try WorkflowAssetRendererTests.write(roles.cutoutPNG,width:100,height:100,pixels:cutout)
            try WorkflowAssetRendererTests.write(roles.maskPNG,width:100,height:100,pixels:mask)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
