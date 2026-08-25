import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageProcessorError: LocalizedError {
    case cannotOpenImage(String)
    case cannotReadProperties(String)
    case cannotCreateThumbnail(String)
    case cannotCreateDestination(String)
    case cannotEncodeImage(String)
    case cannotReachTargetSize(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenImage(let name):
            return "无法读取图片：\(name)"

        case .cannotReadProperties(let name):
            return "无法读取图片信息：\(name)"

        case .cannotCreateThumbnail(let name):
            return "无法生成图片数据：\(name)"

        case .cannotCreateDestination(let name):
            return "无法创建 JPEG：\(name)"

        case .cannotEncodeImage(let name):
            return "无法编码图片：\(name)"

        case .cannotReachTargetSize(let name):
            return "无法将图片压缩到指定大小：\(name)"
        }
    }
}

struct ImageProcessor {
    
    static let supportedExtensions = [
        "jpg",
        "jpeg",
        "png",
        "tif",
        "tiff"
    ]
    
    // MARK: - 读取文件夹中的图片
    
    static func imageFiles(in folderURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            supportedExtensions.contains(
                url.pathExtension.lowercased()
            )
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }
    }
    
    // MARK: - 压缩单张图片
    
    static func compressImage(
        sourceURL: URL,
        destinationURL: URL,
        targetKilobytes: Int
    ) throws {
        
        let fileName = sourceURL.lastPathComponent
        let targetBytes = targetKilobytes * 1024
        
        guard let imageSource = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            nil
        ) else {
            throw ImageProcessorError.cannotOpenImage(fileName)
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            nil
        ) as? [CFString: Any] else {
            throw ImageProcessorError.cannotReadProperties(fileName)
        }
        
        let pixelWidth =
        properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        
        let pixelHeight =
        properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ImageProcessorError.cannotReadProperties(fileName)
        }
        
        var maximumPixelSize = max(pixelWidth, pixelHeight)
        var finalData: Data?
        
        // 先尝试保持原始分辨率，只降低 JPEG 质量。
        // 如果仍然达不到目标，再逐步降低像素尺寸。
        for _ in 0..<18 {
            
            guard let image = createImage(
                from: imageSource,
                maximumPixelSize: maximumPixelSize,
                fileName: fileName
            ) else {
                throw ImageProcessorError.cannotCreateThumbnail(fileName)
            }
            
            if let data = jpegData(
                from: image,
                targetBytes: targetBytes,
                fileName: fileName
            ) {
                finalData = data
                break
            }
            
            let reducedSize = Int(
                Double(maximumPixelSize) * 0.88
            )
            
            if reducedSize >= maximumPixelSize ||
                reducedSize < 500 {
                break
            }
            
            maximumPixelSize = reducedSize
        }
        
        guard let finalData else {
            throw ImageProcessorError.cannotReachTargetSize(fileName)
        }
        
        try finalData.write(
            to: destinationURL,
            options: .atomic
        )
    }
    
    // MARK: - 创建正确方向的 CGImage
    
    private static func createImage(
        from imageSource: CGImageSource,
        maximumPixelSize: Int,
        fileName: String
    ) -> CGImage? {
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        
        return CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        )
    }
    
    // MARK: - 二分查找 JPEG 质量
    
    private static func jpegData(
        from image: CGImage,
        targetBytes: Int,
        fileName: String
    ) -> Data? {
        
        var lowestQuality = 0.03
        var highestQuality = 0.98
        var bestData: Data?
        
        for _ in 0..<16 {
            let quality =
            (lowestQuality + highestQuality) / 2
            
            guard let data = encodeJPEG(
                image: image,
                quality: quality
            ) else {
                return nil
            }
            
            if data.count <= targetBytes {
                bestData = data
                lowestQuality = quality
            } else {
                highestQuality = quality
            }
        }
        
        return bestData
    }
    
    // MARK: - 编码为 JPEG
    
    private static func encodeJPEG(
        image: CGImage,
        quality: Double
    ) -> Data? {
        
        let mutableData = NSMutableData()
        
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1
        ]
        
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    // MARK: - 旋转单张图片
    
    static func rotateImage(
        sourceURL: URL,
        destinationURL: URL,
        degrees: Int
    ) throws {
        
        let fileName = sourceURL.lastPathComponent
        
        guard let imageSource = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            nil
        ) else {
            throw ImageProcessorError.cannotOpenImage(fileName)
        }
        
        guard let sourceImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            nil
        ) else {
            throw ImageProcessorError.cannotOpenImage(fileName)
        }
        
        let normalizedDegrees = ((degrees % 360) + 360) % 360
        
        let sourceWidth = sourceImage.width
        let sourceHeight = sourceImage.height
        
        let outputWidth: Int
        let outputHeight: Int
        
        if normalizedDegrees == 90 || normalizedDegrees == 270 {
            outputWidth = sourceHeight
            outputHeight = sourceWidth
        } else {
            outputWidth = sourceWidth
            outputHeight = sourceHeight
        }
        
        guard let colorSpace = sourceImage.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageProcessorError.cannotEncodeImage(fileName)
        }
        
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageProcessorError.cannotEncodeImage(fileName)
        }
        
        context.interpolationQuality = .high
        
        switch normalizedDegrees {
        case 90:
            context.translateBy(
                x: CGFloat(outputWidth),
                y: 0
            )
            context.rotate(
                by: CGFloat.pi / 2
            )
            
        case 180:
            context.translateBy(
                x: CGFloat(outputWidth),
                y: CGFloat(outputHeight)
            )
            context.rotate(
                by: CGFloat.pi
            )
            
        case 270:
            context.translateBy(
                x: 0,
                y: CGFloat(outputHeight)
            )
            context.rotate(
                by: -CGFloat.pi / 2
            )
            
        default:
            break
        }
        
        context.draw(
            sourceImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: sourceWidth,
                height: sourceHeight
            )
        )
        
        guard let rotatedImage = context.makeImage() else {
            throw ImageProcessorError.cannotEncodeImage(fileName)
        }
        
        let outputExtension =
        sourceURL.pathExtension.lowercased()
        
        let outputType: UTType
        
        switch outputExtension {
        case "png":
            outputType = .png
            
        case "tif", "tiff":
            outputType = .tiff
            
        default:
            outputType = .jpeg
        }
        
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            outputType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessorError.cannotCreateDestination(fileName)
        }
        
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1
        ]
        
        if outputType == .jpeg {
            properties[
                kCGImageDestinationLossyCompressionQuality
            ] = 0.98
        }
        
        CGImageDestinationAddImage(
            destination,
            rotatedImage,
            properties as CFDictionary
        )
        
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessorError.cannotEncodeImage(fileName)
        }
    }
}
