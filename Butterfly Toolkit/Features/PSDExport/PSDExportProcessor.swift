// 扫描 PSD 并保留相对目录结构，将合成图转换为 sRGB JPG 或 PNG，清理输出元数据。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 导出格式、来源与任务模型

enum PSDExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPG"
    case png = "PNG"

    var id: String { rawValue }

    nonisolated var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    nonisolated var contentType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

enum PSDExportSource: Sendable {
    case folder(URL)
    case files([URL])

    var accessURLs: [URL] {
        switch self {
        case .folder(let url):
            [url]
        case .files(let urls):
            urls
        }
    }
}

enum PSDExportError: LocalizedError {
    case invalidInputFolder
    case noPSD(filesDescription: String)
    case invalidOutputFolder
    case duplicateOutputName(String)
    case cannotReadPSD(String)
    case unsupportedDimensions(String)
    case cannotCreateCanvas(String)
    case destinationAlreadyExists(String)
    case cannotEncodeImage(String)
    case cannotRemoveMetadata(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFolder:
            "输入文件夹不存在或无法读取。"
        case .noPSD(let description):
            description
        case .invalidOutputFolder:
            "输出文件夹不存在且无法创建。"
        case .duplicateOutputName(let name):
            "多个 PSD 会生成同一个文件名：\(name)"
        case .cannotReadPSD(let name):
            "无法读取 PSD 合成图：\(name)"
        case .unsupportedDimensions(let name):
            "PSD 的像素尺寸无效：\(name)"
        case .cannotCreateCanvas(let name):
            "无法为 PSD 创建 sRGB 画布：\(name)"
        case .destinationAlreadyExists(let name):
            "目标文件已存在：\(name)"
        case .cannotEncodeImage(let name):
            "无法保存图片：\(name)"
        case .cannotRemoveMetadata(let name):
            "图片已编码，但无法移除元数据：\(name)"
        }
    }
}

struct PSDExportJob: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let format: PSDExportFormat
}

struct PSDExportScanResult: Sendable {
    let jobs: [PSDExportJob]
    let skippedCount: Int
    let totalCount: Int
}

struct PSDExportProcessor {
    // 用用户提供的 4200 × 3360 参考 PSD 校准：ImageIO 0.82 的输出大小
    // 与 Photoshop“导出为”质量 6 的约 3.6 MB 预估最接近。
    nonisolated static let jpegQuality: CGFloat = 0.82

    // MARK: - 源文件统计与任务规划

    nonisolated static func sourceCount(
        for source: PSDExportSource
    ) throws -> Int {
        try collectSourceFiles(from: source).count
    }

    nonisolated static func scan(
        source: PSDExportSource,
        outputFolder: URL,
        format: PSDExportFormat
    ) throws -> PSDExportScanResult {
        let sourceFiles = try collectSourceFiles(from: source)
        guard !sourceFiles.isEmpty else {
            throw PSDExportError.noPSD(
                filesDescription: "所选位置中没有找到 PSD 文件。"
            )
        }

        let fileManager = FileManager.default
        var jobs: [PSDExportJob] = []
        var skippedCount = 0
        var destinationPaths = Set<String>()

        for sourceFile in sourceFiles {
            let relativeOutputPath = sourceFile.relativePath
                .deletingPathExtension
                .appendingPathExtension(format.fileExtension)
            let destinationURL = outputFolder
                .appendingPathComponent(relativeOutputPath)
            // 统一 Unicode 形式并忽略大小写，提前识别多个源文件映射到同一输出的冲突。
            let destinationKey = destinationURL.standardizedFileURL.path
                .precomposedStringWithCanonicalMapping
                .lowercased()

            guard destinationPaths.insert(destinationKey).inserted else {
                throw PSDExportError.duplicateOutputName(
                    destinationURL.lastPathComponent
                )
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                skippedCount += 1
            } else {
                jobs.append(
                    PSDExportJob(
                        sourceURL: sourceFile.url,
                        destinationURL: destinationURL,
                        format: format
                    )
                )
            }
        }

        return PSDExportScanResult(
            jobs: jobs,
            skippedCount: skippedCount,
            totalCount: sourceFiles.count
        )
    }

    // MARK: - 合成图转换与编码

    nonisolated static func export(_ job: PSDExportJob) throws {
        let fileManager = FileManager.default
        let fileName = job.sourceURL.lastPathComponent

        guard !fileManager.fileExists(atPath: job.destinationURL.path) else {
            throw PSDExportError.destinationAlreadyExists(
                job.destinationURL.lastPathComponent
            )
        }

        guard let source = CGImageSourceCreateWithURL(
            job.sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let sourceImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw PSDExportError.cannotReadPSD(fileName)
        }

        let width = sourceImage.width
        let height = sourceImage.height
        guard width > 0, height > 0 else {
            throw PSDExportError.unsupportedDimensions(fileName)
        }

        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PSDExportError.cannotCreateCanvas(fileName)
        }

        let bitmapInfo: CGBitmapInfo
        switch job.format {
        case .jpeg:
            bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        case .png:
            bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw PSDExportError.cannotCreateCanvas(fileName)
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        // JPEG 使用白底承接透明区域，PNG 则保留透明通道。
        if job.format == .jpeg {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(canvas)
        } else {
            context.clear(canvas)
        }

        context.setRenderingIntent(.relativeColorimetric)
        context.interpolationQuality = .none
        context.draw(sourceImage, in: canvas)

        guard let outputImage = context.makeImage() else {
            throw PSDExportError.cannotCreateCanvas(fileName)
        }

        do {
            try fileManager.createDirectory(
                at: job.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw PSDExportError.invalidOutputFolder
        }

        guard let destination = CGImageDestinationCreateWithURL(
            job.destinationURL as CFURL,
            job.format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw PSDExportError.cannotEncodeImage(fileName)
        }

        let properties: CFDictionary
        switch job.format {
        case .jpeg:
            properties = [
                kCGImageDestinationLossyCompressionQuality: jpegQuality,
                kCGImagePropertyJFIFDictionary: [
                    kCGImagePropertyJFIFIsProgressive: false
                ]
            ] as CFDictionary
        case .png:
            properties = [
                kCGImagePropertyPNGDictionary: [:]
            ] as CFDictionary
        }

        // 只给编码器传入格式参数，不复制源文件属性，从而移除元数据。
        // outputImage 自带 sRGB 色彩空间，ImageIO 会把该 ICC 配置写入文件。
        CGImageDestinationAddImage(destination, outputImage, properties)

        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: job.destinationURL)
            throw PSDExportError.cannotEncodeImage(fileName)
        }

        do {
            try removeMetadata(
                from: job.destinationURL,
                format: job.format
            )
        } catch {
            try? fileManager.removeItem(at: job.destinationURL)
            throw PSDExportError.cannotRemoveMetadata(fileName)
        }
    }

    // MARK: - 清理格式元数据

    nonisolated private static func removeMetadata(
        from url: URL,
        format: PSDExportFormat
    ) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let cleanedData: Data

        switch format {
        case .jpeg:
            cleanedData = try jpegWithoutMetadata(data)
        case .png:
            cleanedData = try pngWithoutMetadata(data)
        }

        try cleanedData.write(to: url, options: .atomic)
    }

    nonisolated private static func jpegWithoutMetadata(
        _ data: Data
    ) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw PSDExportError.cannotEncodeImage("JPEG")
        }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        output.append(contentsOf: bytes[0..<2])
        var position = 2

        while position < bytes.count {
            let markerStart = position
            guard bytes[position] == 0xFF else {
                throw PSDExportError.cannotEncodeImage("JPEG")
            }
            while position < bytes.count, bytes[position] == 0xFF {
                position += 1
            }
            guard position < bytes.count else {
                throw PSDExportError.cannotEncodeImage("JPEG")
            }

            let marker = bytes[position]
            position += 1

            // Start of Scan 后面是压缩图像数据，必须逐字节保留。
            if marker == 0xDA {
                output.append(contentsOf: bytes[markerStart...])
                return Data(output)
            }

            let isStandalone = marker == 0x01 || (0xD0...0xD9).contains(marker)
            if isStandalone {
                output.append(contentsOf: bytes[markerStart..<position])
                continue
            }

            guard position + 2 <= bytes.count else {
                throw PSDExportError.cannotEncodeImage("JPEG")
            }
            let length = Int(bytes[position]) << 8 |
                Int(bytes[position + 1])
            guard length >= 2, position + length <= bytes.count else {
                throw PSDExportError.cannotEncodeImage("JPEG")
            }
            let segmentEnd = position + length

            // 保留 JFIF、ICC 和 Adobe 色彩转换标记；移除 EXIF/XMP、
            // Photoshop/IPTC、Content Credentials、注释及其他应用元数据。
            let shouldRemove = marker == 0xE1 ||
                (0xE3...0xED).contains(marker) ||
                marker == 0xEF ||
                marker == 0xFE
            if !shouldRemove {
                output.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            position = segmentEnd
        }

        throw PSDExportError.cannotEncodeImage("JPEG")
    }

    nonisolated private static func pngWithoutMetadata(
        _ data: Data
    ) throws -> Data {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        ]
        guard bytes.count >= signature.count,
              Array(bytes[0..<signature.count]) == signature else {
            throw PSDExportError.cannotEncodeImage("PNG")
        }

        let metadataChunks: Set<String> = [
            "eXIf", "tEXt", "zTXt", "iTXt", "tIME"
        ]
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        output.append(contentsOf: signature)
        var position = signature.count
        var foundEnd = false

        while position + 12 <= bytes.count {
            let length = Int(bytes[position]) << 24 |
                Int(bytes[position + 1]) << 16 |
                Int(bytes[position + 2]) << 8 |
                Int(bytes[position + 3])
            guard length >= 0 else {
                throw PSDExportError.cannotEncodeImage("PNG")
            }
            let chunkEnd = position + 12 + length
            guard chunkEnd <= bytes.count else {
                throw PSDExportError.cannotEncodeImage("PNG")
            }

            let typeBytes = bytes[(position + 4)..<(position + 8)]
            guard let type = String(bytes: typeBytes, encoding: .ascii) else {
                throw PSDExportError.cannotEncodeImage("PNG")
            }
            if !metadataChunks.contains(type) {
                output.append(contentsOf: bytes[position..<chunkEnd])
            }
            position = chunkEnd

            if type == "IEND" {
                foundEnd = true
                break
            }
        }

        guard foundEnd else {
            throw PSDExportError.cannotEncodeImage("PNG")
        }
        return Data(output)
    }

    // MARK: - 源文件收集

    private struct SourceFile: Sendable {
        let url: URL
        let relativePath: String
    }

    nonisolated private static func collectSourceFiles(
        from source: PSDExportSource
    ) throws -> [SourceFile] {
        switch source {
        case .folder(let folder):
            return try collectSourceFiles(in: folder)
        case .files(let urls):
            let uniqueURLs = Dictionary(
                urls.map { ($0.standardizedFileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
            return uniqueURLs
                .filter { $0.pathExtension.lowercased() == "psd" }
                .map {
                    SourceFile(url: $0, relativePath: $0.lastPathComponent)
                }
                .sorted {
                    $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
                }
        }
    }

    nonisolated private static func collectSourceFiles(
        in folder: URL
    ) throws -> [SourceFile] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PSDExportError.invalidInputFolder
        }

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PSDExportError.invalidInputFolder
        }

        let rootPath = folder.standardizedFileURL.path
        var files: [SourceFile] = []

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "psd" else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else {
                continue
            }
            files.append(
                SourceFile(
                    url: url,
                    relativePath: String(path.dropFirst(rootPath.count + 1))
                )
            )
        }

        return files.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}

private extension String {
    nonisolated var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }

    nonisolated func appendingPathExtension(
        _ pathExtension: String
    ) -> String {
        (self as NSString).appendingPathExtension(pathExtension) ?? self
    }
}
