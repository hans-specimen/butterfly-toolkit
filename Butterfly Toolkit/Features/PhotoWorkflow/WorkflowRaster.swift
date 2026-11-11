// 照片工作流共用错误、图像解码、色彩与像素校验。

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

nonisolated enum WorkflowBridgeError: LocalizedError, Equatable {
    case unsavedDocument, staleSource, invalidStructure, ownershipConflict, invalidImage(String), photoshop(String), interruptedWrite(String)
    case photoshopNotRunning, manualReviewActive
    var errorDescription: String? {
        switch self {
        case .photoshopNotRunning: "Photoshop 未运行，无法确认打开的文档。"
        case .manualReviewActive: "请先保存并关闭本批正在精修的 PSD。"
        case .unsavedDocument: "Photoshop 文档尚未保存，请保存后刷新。"
        case .staleSource: "保存版本或输入图片已变化，请刷新后重试。"
        case .invalidStructure: "PSD 角色图层或蒙版已删除、合并或单独变换，请修复后刷新。"
        case .ownershipConflict: "PSD 已存在或不属于此任务，已停止以保护文件。"
        case .invalidImage(let detail): "图片或 AI 结果校验失败：\(detail)"
        case .photoshop(let detail): "Photoshop 处理失败：\(detail)"
        case .interruptedWrite(let detail): "保存状态需要核对，已暂停队列：\(detail)。请在 Photoshop 检查后刷新，避免重复处理。"
        }
    }
}

// MARK: - 图像解码与像素校验
nonisolated struct WorkflowDecodedImage: Sendable {
    let image: CGImage
    let raster: WorkflowRaster
}

/// 完整解码像素并归一到 sRGB，供预乘 RGB 与 alpha 的坐标一致性检查使用。
nonisolated struct WorkflowRaster: Sendable {
    let size: CGSize
    let orientation: Int
    let hasProfile: Bool
    let profileName: String?
    let profileData: Data?
    let pixels: [UInt8]
    static func read(_ url: URL) throws -> Self { try decode(url).raster }
    static func readMatteInput(_ url: URL) throws -> Self { try decode(url, compositingOnWhite: true).raster }
    static func decode(_ url: URL) throws -> WorkflowDecodedImage { try decode(url, compositingOnWhite: false) }
    private static func decode(_ url: URL, compositingOnWhite: Bool) throws -> WorkflowDecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              var image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width > 0, image.height > 0 else { throw WorkflowBridgeError.invalidImage(url.lastPathComponent) }
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if compositingOnWhite {
            // AI 的 white_rgb 在输入 ICC 空间铺白底；必须先合成再转 sRGB，不能跳过透明边缘的颜色校验。
            guard let space = image.colorSpace, space.model == .rgb,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw WorkflowBridgeError.invalidImage("无法建立 AI 白底校验参照")
            }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(rect)
            context.draw(image, in: rect)
            guard let composited = context.makeImage() else { throw WorkflowBridgeError.invalidImage("无法合成 AI 白底校验参照") }
            image = composited
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard success else { throw WorkflowBridgeError.invalidImage("无法完整解码") }
        let raster = Self(size: CGSize(width: image.width, height: image.height), orientation: info[kCGImagePropertyOrientation] as? Int ?? 1,
                    hasProfile: try hasEmbeddedICC(url), profileName: info[kCGImagePropertyProfileName] as? String, profileData: image.colorSpace?.copyICCData() as Data?, pixels: pixels)
        return WorkflowDecodedImage(image: image,raster: raster)
    }
    // 在原 ICC 空间清零对应像素，避免用 sRGB 校验像素重建宽色域输出。
    static func writeCleanedMatte(alpha: [UInt8],originalAlpha: Self,cutoutURL: URL,alphaURL: URL,outputURL: URL) throws {
        let decoded = try decode(cutoutURL),image = decoded.image,w = image.width,h = image.height
        guard alpha.count == w*h,originalAlpha.size == decoded.raster.size,
              let space = image.colorSpace else { throw WorkflowBridgeError.invalidImage("清理尺寸或颜色空间不符") }
        var rgba = [UInt8](repeating: 0,count: w*h*4)
        let output: CGImage? = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,
                space: space,bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h))
            let pixels = bytes.bindMemory(to: UInt8.self)
            for i in alpha.indices where alpha[i] == 0 {
                for channel in 0..<4 { pixels[i*4+channel] = 0 }
            }
            return context.makeImage()
        }
        let maskPixels = alpha.flatMap { [$0,$0,$0,UInt8(255)] }
        guard let output,let provider = CGDataProvider(data: Data(maskPixels) as CFData),
              let mask = CGImage(width: w,height: h,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else {
            throw WorkflowBridgeError.invalidImage("无法生成清理后的蒙版")
        }
        for (image,url) in [(mask,alphaURL),(output,outputURL)] {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw WorkflowBridgeError.invalidImage("无法创建清理结果") }
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation:1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw WorkflowBridgeError.invalidImage("无法保存清理结果") }
        }
        try preservePNGColorMetadata(from: cutoutURL,to: outputURL)
    }
    // ImageIO 对标准 sRGB 可能只写 sRGB 简记；原样携带颜色块，避免丢失必需的嵌入 ICC。
    static func preservePNGColorMetadata(from source: URL,to destination: URL) throws {
        let colorTypes: Set<String> = ["iCCP","sRGB","gAMA","cHRM"]
        func chunks(_ data: Data) throws -> [(String,Data)] {
            guard data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { throw WorkflowBridgeError.invalidImage("不是完整 PNG") }
            var result: [(String,Data)] = [],offset = 8
            while offset+12 <= data.count {
                let length = data[offset..<(offset+4)].reduce(0) { ($0 << 8) | Int($1) }
                guard length <= data.count-offset-12 else { throw WorkflowBridgeError.invalidImage("PNG 块不完整") }
                let type = String(decoding: data[(offset+4)..<(offset+8)],as: UTF8.self)
                result.append((type,data.subdata(in: offset..<(offset+12+length))))
                offset += length+12
            }
            guard offset == data.count,result.first?.0 == "IHDR",result.last?.0 == "IEND" else { throw WorkflowBridgeError.invalidImage("PNG 结构不完整") }
            return result
        }
        let colors = try chunks(Data(contentsOf: source)).filter { colorTypes.contains($0.0) }
        guard colors.contains(where: { $0.0 == "iCCP" }) else { throw WorkflowBridgeError.invalidImage("源 PNG 缺少 ICC") }
        let encoded = try Data(contentsOf: destination)
        var result = Data(encoded.prefix(8))
        for (type,data) in try chunks(encoded) where !colorTypes.contains(type) {
            result.append(data)
            if type == "IHDR" { for (_,color) in colors { result.append(color) } }
        }
        try result.write(to: destination,options: .atomic)
    }
    private static func hasEmbeddedICC(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { return false }
        var offset = 8
        while offset + 12 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            if data[(offset + 4)..<(offset + 8)] == Data("iCCP".utf8) { return length > 0 }
            offset += length + 12
        }
        return false
    }
    // alpha 图应是不透明灰度图；透明结果的颜色还需符合源图的预乘规则。
    static func validateMatte(original: Self, alpha: Self, cutout: Self, respectSourceAlpha: Bool = false) throws {
        guard original.size == alpha.size, original.size == cutout.size, alpha.orientation == 1, cutout.orientation == 1 else {
            throw WorkflowBridgeError.invalidImage("Alpha 尺寸或方向不符")
        }
        guard cutout.hasProfile, original.profileData == cutout.profileData else { throw WorkflowBridgeError.invalidImage("透明结果的 ICC 与输入不同") }
        var hasSubject = false, hasTransparency = false
        for i in stride(from: 0, to: alpha.pixels.count, by: 4) {
            let a = Int(alpha.pixels[i]), ca = Int(cutout.pixels[i + 3]), sourceAlpha = Int(original.pixels[i + 3])
            let expectedAlpha = respectSourceAlpha ? (a * sourceAlpha + 127) / 255 : a
            guard alpha.pixels[i + 3] == 255, abs(expectedAlpha - ca) <= 1,
                  abs(Int(alpha.pixels[i + 1]) - a) <= 1, abs(Int(alpha.pixels[i + 2]) - a) <= 1 else {
                throw WorkflowBridgeError.invalidImage("Alpha 与透明结果不一致或坐标翻转")
            }
            hasSubject = hasSubject || a > 0; hasTransparency = hasTransparency || a < 255
            for channel in 0..<3 {
                let expected = respectSourceAlpha ? Int(original.pixels[i + channel]) * a / 255 : (sourceAlpha == 0 ? 0 : Int(original.pixels[i + channel]) * a / sourceAlpha)
                guard abs(Int(cutout.pixels[i + channel]) - expected) <= 4 else {
                    throw WorkflowBridgeError.invalidImage("前景与输入像素坐标不符")
                }
            }
        }
        guard respectSourceAlpha || (hasSubject && hasTransparency) else { throw WorkflowBridgeError.invalidImage("蒙版为空或完全不透明") }
    }
}
