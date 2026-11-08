// 闲鱼产品图处理：扫描透明 PNG，保留相对子目录，将素材绘制到统一的灰底画布并叠加投影和水印。
// 输出 2000 × 2000 PNG，供独立产品图工具与照片工作流共用。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 错误、任务与扫描结果

enum XianyuProductError: LocalizedError {
    case invalidInputFolder
    case invalidWatermark
    case cannotReadImage(String)
    case cannotCreateCanvas(String)
    case cannotEncodeImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFolder:
            return "输入文件夹不存在或无法读取。"
        case .invalidWatermark:
            return "无法读取水印文件 mark.png。"
        case .cannotReadImage(let name):
            return "无法读取图片：\(name)"
        case .cannotCreateCanvas(let name):
            return "无法创建 2000 × 2000 画布：\(name)"
        case .cannotEncodeImage(let name):
            return "无法保存 PNG：\(name)"
        }
    }
}

struct XianyuProductJob {
    let sourceURL: URL
    let destinationURL: URL
}

struct XianyuProductScanResult {
    let jobs: [XianyuProductJob]
    let skippedCount: Int
    let totalCount: Int
}

nonisolated struct XianyuProductProcessor {
    static let canvasSize = 2000
    private static let dropShadowOffset = CGSize(width: 0, height: -24)
    private static let dropShadowBlur: CGFloat = 49
    private static let dropShadowColor = CGColor(
        srgbRed: 0,
        green: 0,
        blue: 0,
        alpha: 0.15
    )

    // MARK: - 素材扫描与输出映射

    static func scan(
        inputFolder: URL,
        outputFolder: URL
    ) throws -> XianyuProductScanResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: inputFolder.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw XianyuProductError.invalidInputFolder
        }

        guard let enumerator = fileManager.enumerator(
            at: inputFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw XianyuProductError.invalidInputFolder
        }

        let inputPath = inputFolder.standardizedFileURL.path
        var jobs: [XianyuProductJob] = []
        var skippedCount = 0
        var totalCount = 0

        for case let sourceURL as URL in enumerator {
            guard sourceURL.pathExtension.lowercased() == "png" else {
                continue
            }

            let values = try? sourceURL.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            guard values?.isRegularFile == true else {
                continue
            }

            totalCount += 1

            let sourcePath = sourceURL.standardizedFileURL.path
            guard sourcePath.hasPrefix(inputPath + "/") else {
                continue
            }

            let relativePath = String(
                sourcePath.dropFirst(inputPath.count + 1)
            )
            let destinationURL = outputFolder
                .appendingPathComponent(relativePath)

            // 按输入相对路径定位输出，扫描时跳过已有成品，便于继续未完成的批次。
            if fileManager.fileExists(atPath: destinationURL.path) {
                skippedCount += 1
            } else {
                jobs.append(
                    XianyuProductJob(
                        sourceURL: sourceURL,
                        destinationURL: destinationURL
                    )
                )
            }
        }

        jobs.sort {
            $0.sourceURL.path.localizedStandardCompare(
                $1.sourceURL.path
            ) == .orderedAscending
        }

        return XianyuProductScanResult(
            jobs: jobs,
            skippedCount: skippedCount,
            totalCount: totalCount
        )
    }

    // MARK: - 水印读取

    static func loadWatermark(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ), let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw XianyuProductError.invalidWatermark
        }

        return image
    }

    // MARK: - 灰底、投影与水印合成

    static func createProductImage(
        sourceURL: URL,
        destinationURL: URL,
        watermark: CGImage
    ) throws {
        let fileName = sourceURL.lastPathComponent

        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            nil
        ), let sourceImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw XianyuProductError.cannotReadImage(fileName)
        }

        guard let colorSpace = CGColorSpace(
            name: CGColorSpace.sRGB
        ), let context = CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XianyuProductError.cannotCreateCanvas(fileName)
        }

        let canvasRect = CGRect(
            x: 0,
            y: 0,
            width: canvasSize,
            height: canvasSize
        )

        // 与已有手工作品一致，93% 灰度对应 RGB 238。
        let gray = CGFloat(238) / 255
        context.setFillColor(
            red: gray,
            green: gray,
            blue: gray,
            alpha: 1
        )
        context.fill(canvasRect)
        context.interpolationQuality = .high

        // 对应 Photoshop 投影：黑色 15%、90°、24 像素距离、0% 扩展、49 像素大小。
        // 黑色阴影以正常混合、15% 不透明度叠加的结果与正片叠底一致。
        context.saveGState()
        context.setShadow(
            offset: dropShadowOffset,
            blur: dropShadowBlur,
            color: dropShadowColor
        )

        // PNG 素材本身为透明方形画布，阴影依照非透明轮廓生成。
        context.draw(sourceImage, in: canvasRect)
        context.restoreGState()

        // 恢复绘图状态后再加水印，确保投影只作用于素材主体。
        context.draw(watermark, in: canvasRect)

        guard let finalImage = context.makeImage() else {
            throw XianyuProductError.cannotCreateCanvas(fileName)
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw XianyuProductError.cannotEncodeImage(fileName)
        }

        CGImageDestinationAddImage(
            destination,
            finalImage,
            [kCGImagePropertyOrientation: 1] as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw XianyuProductError.cannotEncodeImage(fileName)
        }
    }
}
