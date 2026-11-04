import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Synchronous CPU/file work; call from a detached worker, never a view's MainActor task.
nonisolated struct WorkflowAssetRenderer: Sendable {
    func renderHD(roles: RoleImages, destination: URL) throws {
        try validate(roles)
        let raster = try WorkflowRaster.read(roles.basePNG)
        guard raster.size == roles.pixelSize,raster.orientation == 1 else { throw invalid("底图实际尺寸或方向与角色版本不一致") }
        let base = try image(roles.basePNG)
        let rect = roles.cropViewport.offsetBy(dx: -roles.coordinateOrigin.x,dy: -roles.coordinateOrigin.y)
        guard rect == rect.integral, CGRect(origin: .zero,size: roles.pixelSize).contains(rect),
              let crop = base.cropping(to: rect) else { throw invalid("高清视口超出可恢复底图或不是整数像素") }
        let width = Int(raster.size.width)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            try Task.checkCancellation()
            for x in Int(rect.minX)..<Int(rect.maxX) where raster.pixels[(y*width+x)*4+3] != 255 {
                throw invalid("高清视口含透明空角或无效背景，请返回构图确认")
            }
        }
        try write(crop,to: destination,type: .jpeg,quality: 0.82)
    }

    func render4K(roles: RoleImages, layout: SquareLayout, destination: URL) throws {
        try validate(roles)
        let mask = try WorkflowRaster.read(roles.maskPNG)
        let cutout = try WorkflowRaster.read(roles.cutoutPNG)
        let base = try WorkflowRaster.read(roles.basePNG)
        guard [mask,cutout,base].allSatisfy({ $0.size == roles.pixelSize && $0.orientation == 1 }) else { throw invalid("角色尺寸或方向不一致") }
        var values = [UInt8](repeating: 0,count: mask.pixels.count/4)
        for i in values.indices {
            let p = i*4, a = Int(mask.pixels[p])
            guard mask.pixels[p+3] == 255,abs(a-Int(mask.pixels[p+1])) <= 1,abs(a-Int(mask.pixels[p+2])) <= 1,
                  abs((a*Int(base.pixels[p+3])+127)/255-Int(cutout.pixels[p+3])) <= 1 else {
                throw invalid("最新蒙版与抠图角色不一致，请刷新保存版本")
            }
            values[i] = cutout.pixels[p+3]
        }
        let support = try MeaningfulMaskSupport(values: values,width: Int(cutout.size.width),height: Int(cutout.size.height),origin: .zero)
        // Support chooses layout only: retain original fine alpha, even weak pixels inside these bounds.
        let source = try image(roles.cutoutPNG)
        guard let crop = source.cropping(to: support.bounds) else { throw invalid("无法裁取完整主体") }
        try write(square(crop,layout: layout,white: false),to: destination)
    }

    func renderWhite1K(source4K: URL, destination: URL) throws {
        let (source,bounds) = try subject(source4K)
        guard let crop = source.cropping(to: bounds) else { throw invalid("无法裁取主体") }
        try write(square(crop,layout: .white1k,white: true),to: destination)
    }

    func renderFootage(source4K: URL, destination: URL) throws {
        let (_,bounds) = try subject(source4K)
        try TransparentPNGTrimProcessor.trim(TransparentPNGTrimJob(sourceURL: source4K,destinationURL: destination),visibleBounds: bounds)
    }

    func renderXianyu(source4K: URL, watermark: URL, destination: URL) throws {
        _ = try read4K(source4K)
        try reserve(destination)
        let mark = try XianyuProductProcessor.loadWatermark(from: watermark)
        try XianyuProductProcessor.createProductImage(sourceURL: source4K,destinationURL: destination,watermark: mark)
    }

    private func validate(_ roles: RoleImages) throws {
        guard !roles.snapshotVersion.isEmpty,roles.pixelSize.width > 0,roles.pixelSize.height > 0,
              roles.coordinateOrigin.x.isFinite,roles.coordinateOrigin.y.isFinite,
              roles.editableExtent == CGRect(origin: roles.coordinateOrigin,size: roles.pixelSize),
              roles.cropViewport.width > 0,roles.cropViewport.height > 0 else { throw invalid("缺少完整角色坐标或保存版本") }
    }
    private func subject(_ url: URL) throws -> (CGImage,CGRect) {
        let raster = try read4K(url)
        let values = stride(from: 3,to: raster.pixels.count,by: 4).map { raster.pixels[$0] }
        let support = try MeaningfulMaskSupport(values: values,width: 4096,height: 4096,origin: .zero)
        return (try image(url),support.bounds)
    }
    private func read4K(_ url: URL) throws -> WorkflowRaster {
        let raster = try WorkflowRaster.read(url)
        guard raster.size == CGSize(width: 4096,height: 4096),raster.orientation == 1,
              let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier else { throw invalid("派生资产必须读取已确认的 4096 PNG") }
        return raster
    }
    private func square(_ image: CGImage,layout: SquareLayout,white: Bool) throws -> CGImage {
        let side = layout.canvasSide
        guard side > 0,side <= 16384,layout.safeMargin >= 0,layout.safeMargin < side/2,
              layout.center.x.isFinite,layout.center.y.isFinite else { throw invalid("方形构图参数无效") }
        let scale = Double(side-2*layout.safeMargin)/Double(max(image.width,image.height))
        let size = CGSize(width: Double(image.width)*scale,height: Double(image.height)*scale)
        let topRect = CGRect(x: layout.center.x-size.width/2,y: layout.center.y-size.height/2,width: size.width,height: size.height)
        guard CGRect(x: 0,y: 0,width: side,height: side).contains(topRect) else { throw invalid("构图会截断完整主体") }
        guard let context = CGContext(data: nil,width: side,height: side,bitsPerComponent: 8,bytesPerRow: side*4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { throw invalid("无法创建画布") }
        if white { context.setFillColor(red: 1,green: 1,blue: 1,alpha: 1); context.fill(CGRect(x: 0,y: 0,width: side,height: side)) }
        context.interpolationQuality = .high
        context.draw(image,in: CGRect(x: topRect.minX,y: Double(side)-topRect.maxY,width: size.width,height: size.height))
        guard let output = context.makeImage() else { throw invalid("无法创建图片") }
        return output
    }
    private func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw invalid(url.lastPathComponent) }
        return image
    }
    private func reserve(_ destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw invalid("临时目标已存在") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),withIntermediateDirectories: true)
    }
    private func write(_ image: CGImage,to url: URL,type: UTType = .png,quality: Double? = nil) throws {
        try reserve(url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil) else { throw invalid("无法编码") }
        var props: [CFString:Any] = [kCGImagePropertyOrientation:1]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest,image,props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw invalid("写入失败") }
    }
    private func invalid(_ detail: String) -> WorkflowBridgeError { .invalidImage(detail) }
}
