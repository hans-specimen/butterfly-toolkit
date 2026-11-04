import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TransparentPNGTrimError: LocalizedError, Sendable {
    case invalidInputFolder
    case invalidOutputFolder
    case foldersOverlap
    case unsafeDirectoryPath
    case cannotReadImage(String)
    case imageHasNoVisiblePixels(String)
    case cannotCreatePixelBuffer(String)
    case destinationAlreadyExists(String)
    case cannotWriteImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFolder:
            "输入文件夹不存在或无法读取。"
        case .invalidOutputFolder:
            "无法创建或读取输出文件夹。"
        case .foldersOverlap:
            "输入文件夹和输出文件夹不能相同，也不能互相包含。"
        case .unsafeDirectoryPath:
            "检测到不安全的子文件夹路径，已停止同步。"
        case .cannotReadImage(let name):
            "无法读取 PNG：\(name)"
        case .imageHasNoVisiblePixels(let name):
            "图片没有可见像素：\(name)"
        case .cannotCreatePixelBuffer(let name):
            "无法分析透明区域：\(name)"
        case .destinationAlreadyExists(let name):
            "目标文件已存在：\(name)"
        case .cannotWriteImage(let name):
            "无法保存裁切后的 PNG：\(name)"
        }
    }
}

struct TransparentPNGTrimJob: Sendable {
    let sourceURL: URL
    let destinationURL: URL
}

struct TransparentPNGTrimScanResult: Sendable {
    let jobs: [TransparentPNGTrimJob]
    let totalCount: Int
    let skippedCount: Int
    let missingDirectoryCount: Int
    let extraDirectoryCount: Int
}

struct TransparentPNGDirectorySyncResult: Sendable {
    let createdCount: Int
    let removedCount: Int
}

struct TransparentPNGTrimProcessor {
    nonisolated static func scan(
        inputFolder: URL,
        outputFolder: URL
    ) throws -> TransparentPNGTrimScanResult {
        try validateRoots(inputFolder: inputFolder, outputFolder: outputFolder)

        let inputDirectories = try relativeDirectories(in: inputFolder)
        let outputDirectories = existingRelativeDirectories(in: outputFolder)
        let sourceFiles = try pngFiles(in: inputFolder)
        let fileManager = FileManager.default
        var jobs: [TransparentPNGTrimJob] = []
        var skippedCount = 0

        for source in sourceFiles {
            let relativePath = try relativePath(of: source, inside: inputFolder)
            let relativeDirectory = (relativePath as NSString).deletingLastPathComponent
            let sourceStem = source.deletingPathExtension().lastPathComponent
            let outputName = sourceStem + "_footage.png"
            let destination = relativeDirectory.isEmpty
                ? outputFolder.appendingPathComponent(outputName)
                : outputFolder
                    .appendingPathComponent(relativeDirectory, isDirectory: true)
                    .appendingPathComponent(outputName)

            if fileManager.fileExists(atPath: destination.path) {
                skippedCount += 1
            } else {
                jobs.append(
                    TransparentPNGTrimJob(
                        sourceURL: source,
                        destinationURL: destination
                    )
                )
            }
        }

        return TransparentPNGTrimScanResult(
            jobs: jobs,
            totalCount: sourceFiles.count,
            skippedCount: skippedCount,
            missingDirectoryCount: inputDirectories.subtracting(outputDirectories).count,
            extraDirectoryCount: outputDirectories.subtracting(inputDirectories).count
        )
    }

    /// Makes the visible subfolder tree under output exactly match input.
    /// Extra directories are removed deepest-first, so their contents are removed too.
    nonisolated static func synchronizeDirectories(
        inputFolder: URL,
        outputFolder: URL
    ) throws -> TransparentPNGDirectorySyncResult {
        try validateRoots(inputFolder: inputFolder, outputFolder: outputFolder)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: outputFolder,
                withIntermediateDirectories: true
            )
        } catch {
            throw TransparentPNGTrimError.invalidOutputFolder
        }

        let wanted = try relativeDirectories(in: inputFolder)
        let existing = existingRelativeDirectories(in: outputFolder)
        let extra = existing.subtracting(wanted).sorted {
            pathDepth($0) > pathDepth($1)
        }
        let missing = wanted.subtracting(existing).sorted {
            pathDepth($0) < pathDepth($1)
        }

        for relative in extra {
            let target = try safeChild(relative, of: outputFolder)
            do {
                try fileManager.removeItem(at: target)
            } catch {
                throw TransparentPNGTrimError.invalidOutputFolder
            }
        }

        for relative in missing {
            let target = try safeChild(relative, of: outputFolder)
            do {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            } catch {
                throw TransparentPNGTrimError.invalidOutputFolder
            }
        }

        return TransparentPNGDirectorySyncResult(
            createdCount: missing.count,
            removedCount: extra.count
        )
    }

    nonisolated static func trim(_ job: TransparentPNGTrimJob, visibleBounds: CGRect? = nil) throws {
        let fileManager = FileManager.default
        let name = job.sourceURL.lastPathComponent

        guard !fileManager.fileExists(atPath: job.destinationURL.path) else {
            throw TransparentPNGTrimError.destinationAlreadyExists(
                job.destinationURL.lastPathComponent
            )
        }
        guard let source = CGImageSourceCreateWithURL(job.sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw TransparentPNGTrimError.cannotReadImage(name)
        }

        // Workflow supplies the shared complete-subject support; directory trimming retains its legacy rule.
        let bounds = try visibleBounds ?? visiblePixelBounds(of: image, fileName: name)
        guard let cropped = image.cropping(to: bounds) else {
            throw TransparentPNGTrimError.cannotReadImage(name)
        }

        do {
            try fileManager.createDirectory(
                at: job.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw TransparentPNGTrimError.invalidOutputFolder
        }

        let temporary = job.destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".trim-\(UUID().uuidString).png")
        defer { try? fileManager.removeItem(at: temporary) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TransparentPNGTrimError.cannotWriteImage(name)
        }
        CGImageDestinationAddImage(
            destination,
            cropped,
            [kCGImagePropertyOrientation: 1] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              CGImageSourceCreateWithURL(temporary as CFURL, nil) != nil else {
            throw TransparentPNGTrimError.cannotWriteImage(name)
        }

        do {
            try fileManager.moveItem(at: temporary, to: job.destinationURL)
        } catch {
            throw TransparentPNGTrimError.cannotWriteImage(name)
        }
    }

    nonisolated private static func visiblePixelBounds(
        of image: CGImage,
        fileName: String
    ) throws -> CGRect {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw TransparentPNGTrimError.cannotReadImage(fileName)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw TransparentPNGTrimError.cannotCreatePixelBuffer(fileName)
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bytesPerRow + x * bytesPerPixel + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw TransparentPNGTrimError.imageHasNoVisiblePixels(fileName)
        }

        // CGContext's row order is bottom-up, but the vertical size is unchanged.
        return CGRect(
            x: minX,
            y: height - 1 - maxY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    nonisolated private static func validateRoots(
        inputFolder: URL,
        outputFolder: URL
    ) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: inputFolder.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw TransparentPNGTrimError.invalidInputFolder
        }

        let inputPath = inputFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let outputPath = outputFolder.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputPath != outputPath,
              !inputPath.hasPrefix(outputPath + "/"),
              !outputPath.hasPrefix(inputPath + "/") else {
            throw TransparentPNGTrimError.foldersOverlap
        }
    }

    nonisolated private static func pngFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw TransparentPNGTrimError.invalidInputFolder
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                files.append(url)
            }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    nonisolated private static func relativeDirectories(in root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw TransparentPNGTrimError.invalidInputFolder
        }
        var result = Set<String>()
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                result.insert(try relativePath(of: url, inside: root))
            }
        }
        return result
    }

    nonisolated private static func existingRelativeDirectories(in root: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: root.path),
              let directories = try? relativeDirectories(in: root) else {
            return []
        }
        return directories
    }

    nonisolated private static func relativePath(of url: URL, inside root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = url.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else {
            throw TransparentPNGTrimError.unsafeDirectoryPath
        }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    nonisolated private static func safeChild(_ relative: String, of root: URL) throws -> URL {
        guard !relative.isEmpty,
              !(relative as NSString).isAbsolutePath,
              !relative.split(separator: "/").contains("..") else {
            throw TransparentPNGTrimError.unsafeDirectoryPath
        }
        let child = root.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        guard child.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw TransparentPNGTrimError.unsafeDirectoryPath
        }
        return child
    }

    nonisolated private static func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}
