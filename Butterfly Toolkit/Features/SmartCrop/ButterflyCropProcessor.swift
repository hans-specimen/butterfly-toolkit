// 独立 JPEG 裁剪入口：归一方向、本机蒙版、共用构图、预览及安全导出；不启动 Photoshop 或外部引擎。
import AppKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 参数与逐图调整
nonisolated enum CropRatio: String,CaseIterable,Identifiable,Sendable {
    case fiveFour = "5:4"
    case adaptive = "自适应"
    var id: String { rawValue }
    var geometryRatio: GeometryRatio { self == .fiveFour ? .fiveByFour : .adaptive }
}

nonisolated struct SmartCropAdjustment: Equatable,Sendable {
    var tips: [CGPoint] = []
    var manualBounds: CGRect?
    var manualAngle: Double?
    var confirmed = false

    func request(ratio: CropRatio) -> GeometryRequest {
        let strategy: GeometryAngleStrategy
        if let manualAngle { strategy = .manual(degrees: manualAngle) }
        else if tips.count == 2 {
            let sorted = tips.sorted { $0.x < $1.x }
            strategy = .twoPoints(left: sorted[0],right: sorted[1])
        } else { strategy = .automaticWingTips }
        return GeometryRequest(ratio: ratio.geometryRatio,targetMargin: 0.1,angleStrategy: strategy)
    }
}

nonisolated enum CropFailureReason: LocalizedError,Sendable {
    case unsupportedFile,cannotReadImage,subjectNotFound,subjectMaskUnreliable
    case destinationExists,cannotCreateImage,cannotWriteImage,sourceChanged,needsReview
    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "仅支持 JPG、JPEG 图片。"
        case .cannotReadImage: "无法读取图片。"
        case .subjectNotFound: "未找到主体，请手动框定完整范围。"
        case .subjectMaskUnreliable: "主体识别不可靠，请手动框定完整范围。"
        case .destinationExists: "输出位置已有同名文件，已跳过。"
        case .cannotCreateImage: "无法生成裁剪图像。"
        case .cannotWriteImage: "无法安全写入 JPEG。"
        case .sourceChanged: "原图已变化，请重新载入并确认构图。"
        case .needsReview: "需要检查主体范围或扶正角度，已跳过。"
        }
    }
}

nonisolated struct SmartCropPlan: Sendable {
    var sourceVersion: String
    var sourceSize: CGSize
    var solution: GeometrySolution
    var needsReview: Bool
}

nonisolated struct SmartCropPreview: Sendable {
    var original: CGImage
    var cropped: CGImage?
    var plan: SmartCropPlan?
    var size: CGSize
    var version: String
    var message: String?
}

// MARK: - 图像读取、几何与渲染
nonisolated struct ButterflyCropProcessor: Sendable {
    static let supportedExtensions = ["jpg","jpeg"]

    static func fingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url,options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
    }

    static func load(_ url: URL,maximumPixelSize: Int? = nil) throws -> CGImage {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { throw CropFailureReason.unsupportedFile }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,let height = info[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize ?? max(width,height)
              ] as CFDictionary) else { throw CropFailureReason.cannotReadImage }
        return image
    }

    static func input(size: CGSize,version: String) -> GeometryImageInput {
        GeometryImageInput(sourceVersion: version,sourcePixelSize: size,coordinateOrigin: .zero,cropViewport: CGRect(origin: .zero,size: size))
    }

    static func manualGeometry(size: CGSize,version: String,bounds: CGRect) throws -> PreparedMaskGeometry {
        let extent = CGRect(origin: .zero,size: size)
        guard bounds.origin.x.isFinite,bounds.origin.y.isFinite,bounds.width.isFinite,bounds.height.isFinite,
              bounds.width >= 2,bounds.height >= 2,extent.contains(bounds) else { throw CropFailureReason.subjectMaskUnreliable }
        let rect = bounds.integral,w = Int(size.width),h = Int(size.height)
        var values = [UInt8](repeating: 0,count: w*h)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            if y % 128 == 0 { try Task.checkCancellation() }
            for x in Int(rect.minX)..<Int(rect.maxX) { values[y*w+x] = 255 }
        }
        return try SpecimenGeometry.prepare(input: input(size: size,version: version),mask: values)
    }

    static func plan(prepared: PreparedMaskGeometry,adjustment: SmartCropAdjustment,ratio: CropRatio) throws -> SmartCropPlan {
        // 人工矩形不能提供翅顶；未选点时保留角度并要求确认。
        var request = adjustment.request(ratio: ratio)
        let manualNeedsAngle = adjustment.manualBounds != nil && adjustment.tips.count != 2 && adjustment.manualAngle == nil
        if manualNeedsAngle { request.angleStrategy = .manual(degrees: 0) }
        var solution = try prepared.analyze(request: request)
        if manualNeedsAngle { solution.reason = ["手动范围：请选翅顶，或确认保持原角度",solution.reason].compactMap { $0 }.joined(separator: "；") }
        let review = manualNeedsAngle || (solution.reason?.contains("角度需调整") ?? false)
            || (solution.reason?.contains("分离细节") ?? false)
        return SmartCropPlan(sourceVersion: prepared.input.sourceVersion,sourceSize: prepared.input.sourcePixelSize,
            solution: solution,needsReview: review && !adjustment.confirmed)
    }

    static func render(_ image: CGImage,sourceSize: CGSize,solution: GeometrySolution,maximumPixelSize: Int? = nil) throws -> CGImage {
        guard solution.isApplicable else { throw CropFailureReason.needsReview }
        let rect = solution.sourceCropRect,pivot = solution.rotationPivot
        // 共用几何以左上为原点；Core Image 以左下为原点，角度符号和裁剪纵坐标必须一起转换。
        let p = CGPoint(x: pivot.x,y: sourceSize.height-pivot.y)
        let transform = CGAffineTransform(translationX: p.x,y: p.y).rotated(by: -solution.angleDegrees * .pi/180).translatedBy(x: -p.x,y: -p.y)
        let crop = CGRect(x: rect.minX,y: sourceSize.height-rect.maxY,width: rect.width,height: rect.height)
        var result = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: sourceSize.width/Double(image.width),y: sourceSize.height/Double(image.height)))
            .transformed(by: transform).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX,y: -crop.minY))
        var outputSize = rect.size
        if let maximumPixelSize,max(rect.width,rect.height) > Double(maximumPixelSize) {
            let scale = Double(maximumPixelSize)/max(rect.width,rect.height)
            outputSize = CGSize(width: max(1,floor(rect.width*scale)),height: max(1,floor(rect.height*scale)))
            result = result.transformed(by: CGAffineTransform(scaleX: outputSize.width/rect.width,y: outputSize.height/rect.height))
        }
        // RGBA 渲染不能使用灰度或 CMYK 工作空间；RGB 输入继续保留原 ICC。
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space,.outputColorSpace: space])
        guard let output = context.createCGImage(result,from: CGRect(origin: .zero,size: outputSize),format: .RGBA8,colorSpace: space) else { throw CropFailureReason.cannotCreateImage }
        return output
    }

    // MARK: - 预览方案导出与源保护
    static func export(source: URL,destination: URL,overwrite: Bool,plan: SmartCropPlan) throws {
        guard plan.solution.isApplicable,!plan.needsReview else { throw CropFailureReason.needsReview }
        guard try fingerprint(source) == plan.sourceVersion else { throw CropFailureReason.sourceChanged }
        if !overwrite,FileManager.default.fileExists(atPath: destination.path) { throw CropFailureReason.destinationExists }
        if overwrite,source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() { throw CropFailureReason.cannotWriteImage }
        let original = try load(source)
        guard CGSize(width: original.width,height: original.height) == plan.sourceSize else { throw CropFailureReason.sourceChanged }
        let rendered = try render(original,sourceSize: plan.sourceSize,solution: plan.solution)
        try Task.checkCancellation()
        let manager = FileManager.default,parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent,withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".smartcrop-\(UUID()).jpg")
        defer { try? manager.removeItem(at: temporary) }
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL,nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(sourceRef,0,nil) as? [CFString: Any],
              let output = CGImageDestinationCreateWithURL(temporary as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw CropFailureReason.cannotWriteImage }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.98
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = rendered.width; properties[kCGImagePropertyPixelHeight] = rendered.height
        // 删除原方向的缩略图，避免查看器显示未裁剪的缓存图。
        properties.removeValue(forKey: kCGImagePropertyThumbnailImages)
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1; properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = rendered.width; exif[kCGImagePropertyExifPixelYDimension] = rendered.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(output,rendered,properties as CFDictionary)
        guard CGImageDestinationFinalize(output),let check = CGImageSourceCreateWithURL(temporary as CFURL,nil),
              let decoded = CGImageSourceCreateImageAtIndex(check,0,nil),decoded.width == rendered.width,decoded.height == rendered.height else { throw CropFailureReason.cannotWriteImage }
        try Task.checkCancellation()
        guard try fingerprint(source) == plan.sourceVersion else { throw CropFailureReason.sourceChanged }
        if overwrite { _ = try manager.replaceItemAt(destination,withItemAt: temporary,backupItemName: nil,options: .usingNewMetadataOnly) }
        else { try manager.moveItem(at: temporary,to: destination) }
    }
}
