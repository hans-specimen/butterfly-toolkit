import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum CropRatio: String, CaseIterable, Identifiable, Sendable {
    case fiveFour = "5:4"
    case elevenEightPointFive = "11:8.5"
    case sevenFive = "7:5"
    case fourThree = "4:3"
    case threeTwo = "3:2"

    var id: String { rawValue }

    nonisolated var value: CGFloat {
        switch self {
        case .fiveFour: 5 / 4
        case .elevenEightPointFive: 11 / 8.5
        case .sevenFive: 7 / 5
        case .fourThree: 4 / 3
        case .threeTwo: 3 / 2
        }
    }

    nonisolated var pixelUnits: (width: Int, height: Int) {
        switch self {
        case .fiveFour: (5, 4)
        case .elevenEightPointFive: (22, 17)
        case .sevenFive: (7, 5)
        case .fourThree: (4, 3)
        case .threeTwo: (3, 2)
        }
    }
}

struct CropOptions: Sendable {
    let ratio: CropRatio
    let preferredPadding: CGFloat
    let autoStraighten: Bool
    var maximumStraightenAngle: CGFloat = 10
    var jpegQuality: CGFloat = 0.98
}

enum CropFailureReason: LocalizedError, Sendable {
    case unsupportedFile
    case cannotReadImage
    case cannotReadMetadata
    case subjectNotFound
    case subjectMaskUnreliable
    case straightenUnreliable
    case ratioCannotContainSubject
    case destinationExists
    case cannotCreateImage
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "仅支持 JPG、JPEG 图片。"
        case .cannotReadImage: "无法读取图片。"
        case .cannotReadMetadata: "无法读取图片元数据。"
        case .subjectNotFound: "没有识别到可靠的蝴蝶主体。"
        case .subjectMaskUnreliable: "主体蒙版不可靠。"
        case .straightenUnreliable: "无法可靠判断扶正角度。"
        case .ratioCannotContainSubject: "目标比例无法完整容纳蝴蝶，已跳过。"
        case .destinationExists: "输出目录中已有同名文件，已跳过。"
        case .cannotCreateImage: "无法生成裁剪图像。"
        case .cannotWriteImage: "无法安全写入 JPEG。"
        }
    }
}

struct CropAnalysis: Sendable {
    let sourcePixelSize: CGSize
    let rotationDegrees: CGFloat
    let subjectRect: CGRect
    let cropRect: CGRect
    let rotatedCanvasSize: CGSize
    let validSourcePolygon: [CGPoint]
    let requestedPadding: CGFloat
    let actualPadding: CGFloat
    let symmetryScore: CGFloat
}

struct CropResult: Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let analysis: CropAnalysis
}

final class CropCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct ButterflyCropProcessor: Sendable {
    nonisolated static let supportedExtensions = ["jpg", "jpeg"]

    nonisolated func analyze(
        sourceURL: URL,
        options: CropOptions
    ) throws -> CropAnalysis {
        try validateExtension(sourceURL)

        let analysisImage = try loadNormalizedImage(
            sourceURL,
            maximumPixelSize: 1_400
        )
        let fullSize = try normalizedPixelSize(sourceURL)
        let mask: MaskData
        let maskSummary: MaskSummary
        do {
            let visionMask = try foregroundMask(for: analysisImage)
            let visionSummary = try summarize(mask: visionMask)
            mask = visionMask
            maskSummary = visionSummary
        } catch {
            let colorMask = try backgroundDifferenceMask(for: analysisImage)
            mask = colorMask
            maskSummary = try summarize(mask: colorMask)
        }

        let straightening: (angle: CGFloat, score: CGFloat)
        if options.autoStraighten {
            straightening = try bestStraightening(
                mask: mask,
                summary: maskSummary,
                maximumDegrees: options.maximumStraightenAngle
            )
        } else {
            straightening = (0, maskSummary.symmetryAtZero)
        }

        let sourceSize = CGSize(
            width: fullSize.width,
            height: fullSize.height
        )
        let geometry = rotatedGeometry(
            sourceSize: sourceSize,
            mask: mask,
            angleDegrees: straightening.angle
        )

        guard let crop = Self.findCropRect(
            subjectRect: geometry.subjectRect,
            sourcePolygon: geometry.sourcePolygon,
            aspectRatio: options.ratio.value,
            preferredPadding: options.preferredPadding
        ), let pixelCrop = Self.pixelAlignedCropRect(
            crop.rect,
            subjectRect: geometry.subjectRect,
            sourcePolygon: geometry.sourcePolygon,
            units: options.ratio.pixelUnits
        ) else {
            throw CropFailureReason.ratioCannotContainSubject
        }

        return CropAnalysis(
            sourcePixelSize: sourceSize,
            rotationDegrees: straightening.angle,
            subjectRect: geometry.subjectRect,
            cropRect: pixelCrop,
            rotatedCanvasSize: geometry.canvasSize,
            validSourcePolygon: geometry.sourcePolygon,
            requestedPadding: options.preferredPadding,
            actualPadding: crop.padding,
            symmetryScore: straightening.score
        )
    }

    nonisolated func renderPreview(
        sourceURL: URL,
        options: CropOptions,
        maximumPixelSize: Int = 1_600
    ) throws -> (image: NSImage, analysis: CropAnalysis) {
        let analysis = try analyze(sourceURL: sourceURL, options: options)
        let image = try loadNormalizedImage(
            sourceURL,
            maximumPixelSize: maximumPixelSize
        )
        let scale = CGFloat(image.width) / analysis.sourcePixelSize.width
        let previewAnalysis = scaledAnalysis(analysis, by: scale)
        let rendered = try render(image: image, analysis: previewAnalysis)
        return (
            NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            ),
            analysis
        )
    }

    nonisolated func process(
        sourceURL: URL,
        destinationURL: URL,
        overwriteSource: Bool,
        options: CropOptions
    ) throws -> CropResult {
        if !overwriteSource,
           FileManager.default.fileExists(atPath: destinationURL.path) {
            throw CropFailureReason.destinationExists
        }

        let analysis = try analyze(sourceURL: sourceURL, options: options)
        let image = try loadNormalizedImage(sourceURL, maximumPixelSize: nil)
        let rendered = try render(image: image, analysis: analysis)
        try writeJPEGAtomically(
            rendered,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            overwrite: overwriteSource,
            quality: options.jpegQuality
        )
        return CropResult(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            analysis: analysis
        )
    }

    // MARK: - Testable crop geometry

    nonisolated static func findCropRect(
        subjectRect: CGRect,
        sourcePolygon: [CGPoint],
        aspectRatio: CGFloat,
        preferredPadding: CGFloat
    ) -> (rect: CGRect, padding: CGFloat)? {
        guard subjectRect.width > 0,
              subjectRect.height > 0,
              aspectRatio > 0,
              sourcePolygon.count == 4 else {
            return nil
        }

        var padding = max(0, preferredPadding)
        while padding >= -0.0001 {
            let effectivePadding = max(0, padding)
            let padded = subjectRect.insetBy(
                dx: -subjectRect.width * effectivePadding,
                dy: -subjectRect.height * effectivePadding
            )
            let size: CGSize
            if padded.width / padded.height > aspectRatio {
                size = CGSize(
                    width: padded.width,
                    height: padded.width / aspectRatio
                )
            } else {
                size = CGSize(
                    width: padded.height * aspectRatio,
                    height: padded.height
                )
            }

            let xRange = (
                lower: subjectRect.maxX - size.width / 2,
                upper: subjectRect.minX + size.width / 2
            )
            let yRange = (
                lower: subjectRect.maxY - size.height / 2,
                upper: subjectRect.minY + size.height / 2
            )
            if xRange.lower <= xRange.upper,
               yRange.lower <= yRange.upper {
                let xs = candidateCenters(
                    preferred: subjectRect.midX,
                    lower: xRange.lower,
                    upper: xRange.upper
                )
                let ys = candidateCenters(
                    preferred: subjectRect.midY,
                    lower: yRange.lower,
                    upper: yRange.upper
                )
                var candidates: [(CGRect, CGFloat)] = []
                for x in xs {
                    for y in ys {
                        let rect = CGRect(
                            x: x - size.width / 2,
                            y: y - size.height / 2,
                            width: size.width,
                            height: size.height
                        )
                        guard rect.contains(subjectRect),
                              rectCorners(rect).allSatisfy({
                                  pointInConvexPolygon($0, polygon: sourcePolygon)
                              }) else {
                            continue
                        }
                        let distance = hypot(
                            x - subjectRect.midX,
                            y - subjectRect.midY
                        )
                        candidates.append((rect, distance))
                    }
                }
                if let best = candidates.min(by: { $0.1 < $1.1 }) {
                    return (best.0, effectivePadding)
                }
            }
            if effectivePadding == 0 { break }
            padding = max(0, effectivePadding - 0.01)
        }
        return nil
    }

    private nonisolated static func pixelAlignedCropRect(
        _ preferredRect: CGRect,
        subjectRect: CGRect,
        sourcePolygon: [CGPoint],
        units: (width: Int, height: Int)
    ) -> CGRect? {
        let unitWidth = CGFloat(units.width)
        let unitHeight = CGFloat(units.height)
        let preferredScale = Int(floor(min(
            preferredRect.width / unitWidth,
            preferredRect.height / unitHeight
        )))
        let minimumScale = Int(ceil(max(
            subjectRect.width / unitWidth,
            subjectRect.height / unitHeight
        )))
        guard preferredScale >= minimumScale else { return nil }

        for scale in stride(
            from: preferredScale,
            through: minimumScale,
            by: -1
        ) {
            let size = CGSize(
                width: CGFloat(scale * units.width),
                height: CGFloat(scale * units.height)
            )
            let rect = CGRect(
                x: preferredRect.midX - size.width / 2,
                y: preferredRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            if rect.contains(subjectRect),
               rectCorners(rect).allSatisfy({
                   pointInConvexPolygon($0, polygon: sourcePolygon)
               }) {
                return rect
            }
        }
        return nil
    }

    // MARK: - Image loading and metadata

    private nonisolated func validateExtension(_ url: URL) throws {
        guard Self.supportedExtensions.contains(
            url.pathExtension.lowercased()
        ) else {
            throw CropFailureReason.unsupportedFile
        }
    }

    private nonisolated func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CropFailureReason.cannotReadImage
        }
        return source
    }

    private nonisolated func normalizedPixelSize(_ url: URL) throws -> CGSize {
        let source = try imageSource(url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil
        ) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
        let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            throw CropFailureReason.cannotReadMetadata
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        return [5, 6, 7, 8].contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private nonisolated func loadNormalizedImage(
        _ url: URL,
        maximumPixelSize: Int?
    ) throws -> CGImage {
        let source = try imageSource(url)
        let maxDimension: Int
        if let maximumPixelSize {
            maxDimension = maximumPixelSize
        } else {
            let size = try normalizedPixelSize(url)
            maxDimension = Int(max(size.width, size.height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw CropFailureReason.cannotReadImage
        }
        return image
    }

    // MARK: - Vision mask and straightening

    private struct MaskData: Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let foregroundPoints: [CGPoint]
    }

    private struct MaskSummary: Sendable {
        let bounds: CGRect
        let centroid: CGPoint
        let coverage: CGFloat
        let symmetryAtZero: CGFloat
    }

    private nonisolated func foregroundMask(for image: CGImage) throws -> MaskData {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                throw CropFailureReason.subjectNotFound
            }
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
            return try copyMask(buffer)
        } catch let reason as CropFailureReason {
            throw reason
        } catch {
            throw CropFailureReason.subjectNotFound
        }
    }

    private nonisolated func copyMask(_ buffer: CVPixelBuffer) throws -> MaskData {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw CropFailureReason.subjectNotFound
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [UInt8](repeating: 0, count: width * height)
        var points: [CGPoint] = []
        points.reserveCapacity(width * height / 4)

        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = row[x]
                let isForeground = value >= 64
                pixels[y * width + x] = isForeground ? 255 : 0
                if isForeground, x % 2 == 0, y % 2 == 0 {
                    // Convert the top-origin mask into Core Image's bottom-origin space.
                    points.append(CGPoint(x: x, y: height - 1 - y))
                }
            }
        }
        guard !points.isEmpty else { throw CropFailureReason.subjectNotFound }
        return MaskData(
            width: width,
            height: height,
            pixels: pixels,
            foregroundPoints: points
        )
    }

    /// Macro specimen photographs often do not produce a semantic Vision subject.
    /// Their near-solid border background is nevertheless very stable, so use a
    /// robust border-color model and keep the largest connected foreground shape.
    private nonisolated func backgroundDifferenceMask(
        for image: CGImage
    ) throws -> MaskData {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CropFailureReason.cannotCreateImage
        }
        // Store row zero as the visual top, matching the Vision mask convention.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let borderDepth = max(3, min(width, height) / 35)
        let sampleStep = max(2, min(width, height) / 350)
        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []

        func appendPixel(x: Int, y: Int) {
            let offset = y * bytesPerRow + x * 4
            reds.append(rgba[offset])
            greens.append(rgba[offset + 1])
            blues.append(rgba[offset + 2])
        }
        for x in Swift.stride(from: 0, to: width, by: sampleStep) {
            for y in Swift.stride(from: 0, to: borderDepth, by: sampleStep) {
                appendPixel(x: x, y: y)
                appendPixel(x: x, y: height - 1 - y)
            }
        }
        for y in Swift.stride(from: borderDepth, to: height - borderDepth, by: sampleStep) {
            for x in Swift.stride(from: 0, to: borderDepth, by: sampleStep) {
                appendPixel(x: x, y: y)
                appendPixel(x: width - 1 - x, y: y)
            }
        }
        guard !reds.isEmpty else { throw CropFailureReason.subjectNotFound }
        let background = (
            r: CGFloat(median(reds)),
            g: CGFloat(median(greens)),
            b: CGFloat(median(blues))
        )

        var borderDistances: [CGFloat] = []
        borderDistances.reserveCapacity(reds.count)
        for index in reds.indices {
            borderDistances.append(colorDistance(
                r: CGFloat(reds[index]),
                g: CGFloat(greens[index]),
                b: CGFloat(blues[index]),
                background: background
            ))
        }
        borderDistances.sort()
        let percentileIndex = min(
            borderDistances.count - 1,
            Int(CGFloat(borderDistances.count - 1) * 0.92)
        )
        let threshold = max(30, borderDistances[percentileIndex] + 13)
        let backgroundSaturation = saturation(
            r: background.r,
            g: background.g,
            b: background.b
        )

        var binary = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let r = CGFloat(rgba[offset])
                let g = CGFloat(rgba[offset + 1])
                let b = CGFloat(rgba[offset + 2])
                let distance = colorDistance(
                    r: r, g: g, b: b, background: background
                )
                let pixelSaturation = saturation(r: r, g: g, b: b)
                if distance > threshold
                    || pixelSaturation > max(0.17, backgroundSaturation + 0.10) {
                    binary[y * width + x] = 255
                }
            }
        }

        // Join tiny breaks around scales and antennae, then discard dust specks.
        binary = erode(
            dilate(binary, width: width, height: height, radius: 2),
            width: width,
            height: height,
            radius: 2
        )
        binary = largestConnectedRegion(
            binary,
            width: width,
            height: height
        )

        var points: [CGPoint] = []
        for y in Swift.stride(from: 0, to: height, by: 2) {
            for x in Swift.stride(from: 0, to: width, by: 2)
            where binary[y * width + x] > 0 {
                points.append(CGPoint(x: x, y: height - 1 - y))
            }
        }
        guard !points.isEmpty else { throw CropFailureReason.subjectNotFound }
        return MaskData(
            width: width,
            height: height,
            pixels: binary,
            foregroundPoints: points
        )
    }

    private nonisolated func median(_ values: [UInt8]) -> UInt8 {
        values.sorted()[values.count / 2]
    }

    private nonisolated func colorDistance(
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        background: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> CGFloat {
        // Luminance gets slightly more weight; chroma still separates pale wings.
        let dr = r - background.r
        let dg = g - background.g
        let db = b - background.b
        let luminance = 0.2126 * dr + 0.7152 * dg + 0.0722 * db
        return sqrt(dr * dr + dg * dg + db * db + 0.35 * luminance * luminance)
    }

    private nonisolated func saturation(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        return maximum == 0 ? 0 : (maximum - minimum) / maximum
    }

    private nonisolated func dilate(
        _ source: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        var output = source
        for y in 0..<height {
            for x in 0..<width where source[y * width + x] > 0 {
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    for xx in max(0, x - radius)...min(width - 1, x + radius) {
                        output[yy * width + xx] = 255
                    }
                }
            }
        }
        return output
    }

    private nonisolated func erode(
        _ source: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: source.count)
        guard width > radius * 2, height > radius * 2 else { return output }
        for y in radius..<(height - radius) {
            for x in radius..<(width - radius) {
                var keep = true
                for yy in (y - radius)...(y + radius) {
                    for xx in (x - radius)...(x + radius)
                    where source[yy * width + xx] == 0 {
                        keep = false
                        break
                    }
                    if !keep { break }
                }
                if keep { output[y * width + x] = 255 }
            }
        }
        return output
    }

    private nonisolated func largestConnectedRegion(
        _ source: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        var visited = [Bool](repeating: false, count: source.count)
        var largest: [Int] = []
        let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in source.indices where source[start] > 0 && !visited[start] {
            var queue = [start]
            visited[start] = true
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                for (dx, dy) in neighbors {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if source[next] > 0, !visited[next] {
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }
            if queue.count > largest.count { largest = queue }
        }

        guard largest.count > width * height / 1_000 else {
            return [UInt8](repeating: 0, count: source.count)
        }
        var output = [UInt8](repeating: 0, count: source.count)
        for index in largest { output[index] = 255 }
        return output
    }

    private nonisolated func summarize(mask: MaskData) throws -> MaskSummary {
        let xs = mask.foregroundPoints.map(\.x)
        let ys = mask.foregroundPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            throw CropFailureReason.subjectNotFound
        }
        let coverage = CGFloat(mask.foregroundPoints.count * 4)
            / CGFloat(mask.width * mask.height)
        guard coverage > 0.008, coverage < 0.94 else {
            throw CropFailureReason.subjectMaskUnreliable
        }
        let centroid = CGPoint(
            x: xs.reduce(0, +) / CGFloat(xs.count),
            y: ys.reduce(0, +) / CGFloat(ys.count)
        )
        let summary = MaskSummary(
            bounds: CGRect(
                x: minX, y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            ),
            centroid: centroid,
            coverage: coverage,
            symmetryAtZero: 0
        )
        let zero = symmetryScore(mask: mask, centroid: centroid, angleDegrees: 0)
        return MaskSummary(
            bounds: summary.bounds,
            centroid: centroid,
            coverage: coverage,
            symmetryAtZero: zero
        )
    }

    private nonisolated func bestStraightening(
        mask: MaskData,
        summary: MaskSummary,
        maximumDegrees: CGFloat
    ) throws -> (angle: CGFloat, score: CGFloat) {
        var bestAngle: CGFloat = 0
        var bestScore = summary.symmetryAtZero
        let limit = min(10, max(0, maximumDegrees))
        var angle = -limit
        while angle <= limit + 0.001 {
            let score = symmetryScore(
                mask: mask,
                centroid: summary.centroid,
                angleDegrees: angle
            )
            if score > bestScore {
                bestScore = score
                bestAngle = angle
            }
            angle += 0.5
        }
        guard bestScore >= 0.42 else {
            throw CropFailureReason.straightenUnreliable
        }
        // Tiny corrections are visually meaningless and can cost valid edge area.
        if abs(bestAngle) < 0.75 { bestAngle = 0 }
        return (bestAngle, bestScore)
    }

    private nonisolated func symmetryScore(
        mask: MaskData,
        centroid: CGPoint,
        angleDegrees: CGFloat
    ) -> CGFloat {
        let radians = angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        var matches = 0
        var samples = 0
        let stride = max(1, mask.foregroundPoints.count / 30_000)

        for index in Swift.stride(
            from: 0,
            to: mask.foregroundPoints.count,
            by: stride
        ) {
            let point = mask.foregroundPoints[index]
            let dx = point.x - centroid.x
            let dy = point.y - centroid.y
            let rotatedX = cosine * dx - sine * dy
            let rotatedY = sine * dx + cosine * dy
            let mirroredX = -rotatedX
            let originalX = cosine * mirroredX + sine * rotatedY + centroid.x
            let originalY = -sine * mirroredX + cosine * rotatedY + centroid.y
            let x = Int(originalX.rounded())
            let yFromBottom = Int(originalY.rounded())
            let y = mask.height - 1 - yFromBottom
            if x >= 0, x < mask.width, y >= 0, y < mask.height,
               mask.pixels[y * mask.width + x] > 0 {
                matches += 1
            }
            samples += 1
        }
        return samples == 0 ? 0 : CGFloat(matches) / CGFloat(samples)
    }

    // MARK: - Rotation and rendering

    private nonisolated func rotatedGeometry(
        sourceSize: CGSize,
        mask: MaskData,
        angleDegrees: CGFloat
    ) -> (subjectRect: CGRect, sourcePolygon: [CGPoint], canvasSize: CGSize) {
        let angle = angleDegrees * .pi / 180
        let canvasSize = Self.rotatedCanvasSize(sourceSize, angle: angle)
        let transform = Self.rotationTransform(
            sourceSize: sourceSize,
            canvasSize: canvasSize,
            angle: angle
        )
        let scaleX = sourceSize.width / CGFloat(mask.width)
        let scaleY = sourceSize.height / CGFloat(mask.height)
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for point in mask.foregroundPoints {
            let sourcePoint = CGPoint(
                x: point.x * scaleX,
                y: point.y * scaleY
            ).applying(transform)
            minX = min(minX, sourcePoint.x)
            minY = min(minY, sourcePoint.y)
            maxX = max(maxX, sourcePoint.x)
            maxY = max(maxY, sourcePoint.y)
        }
        let compensation = max(sourceSize.width, sourceSize.height) * 0.003
        let subject = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).insetBy(dx: -compensation, dy: -compensation)
        let polygon = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: sourceSize.width, y: 0),
            CGPoint(x: sourceSize.width, y: sourceSize.height),
            CGPoint(x: 0, y: sourceSize.height)
        ].map { $0.applying(transform) }
        return (subject, polygon, canvasSize)
    }

    private nonisolated func render(
        image: CGImage,
        analysis: CropAnalysis
    ) throws -> CGImage {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let angle = analysis.rotationDegrees * .pi / 180
        let canvasSize = Self.rotatedCanvasSize(sourceSize, angle: angle)
        let transform = Self.rotationTransform(
            sourceSize: sourceSize,
            canvasSize: canvasSize,
            angle: angle
        )
        let cropRect = analysis.cropRect
        let outputColorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: Int(cropRect.width),
            height: Int(cropRect.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CropFailureReason.cannotCreateImage
        }
        context.interpolationQuality = .high
        context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        context.concatenate(transform)
        context.draw(
            image,
            in: CGRect(origin: .zero, size: sourceSize)
        )
        guard let output = context.makeImage() else {
            throw CropFailureReason.cannotCreateImage
        }
        return output
    }

    private nonisolated func scaledAnalysis(
        _ analysis: CropAnalysis,
        by scale: CGFloat
    ) -> CropAnalysis {
        CropAnalysis(
            sourcePixelSize: CGSize(
                width: analysis.sourcePixelSize.width * scale,
                height: analysis.sourcePixelSize.height * scale
            ),
            rotationDegrees: analysis.rotationDegrees,
            subjectRect: analysis.subjectRect.applying(
                CGAffineTransform(scaleX: scale, y: scale)
            ),
            cropRect: analysis.cropRect.applying(
                CGAffineTransform(scaleX: scale, y: scale)
            ),
            rotatedCanvasSize: CGSize(
                width: analysis.rotatedCanvasSize.width * scale,
                height: analysis.rotatedCanvasSize.height * scale
            ),
            validSourcePolygon: analysis.validSourcePolygon.map {
                CGPoint(x: $0.x * scale, y: $0.y * scale)
            },
            requestedPadding: analysis.requestedPadding,
            actualPadding: analysis.actualPadding,
            symmetryScore: analysis.symmetryScore
        )
    }

    private nonisolated static func rotatedCanvasSize(
        _ size: CGSize,
        angle: CGFloat
    ) -> CGSize {
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        return CGSize(
            width: ceil(size.width * cosine + size.height * sine),
            height: ceil(size.width * sine + size.height * cosine)
        )
    }

    private nonisolated static func rotationTransform(
        sourceSize: CGSize,
        canvasSize: CGSize,
        angle: CGFloat
    ) -> CGAffineTransform {
        CGAffineTransform(
            translationX: canvasSize.width / 2,
            y: canvasSize.height / 2
        )
        .rotated(by: angle)
        .translatedBy(
            x: -sourceSize.width / 2,
            y: -sourceSize.height / 2
        )
    }

    // MARK: - JPEG output

    private nonisolated func writeJPEGAtomically(
        _ image: CGImage,
        sourceURL: URL,
        destinationURL: URL,
        overwrite: Bool,
        quality: CGFloat
    ) throws {
        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw CropFailureReason.cannotWriteImage
        }
        let temporaryURL = parent.appendingPathComponent(
            ".smartcrop-\(UUID().uuidString).jpg"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil
              ) as? [CFString: Any],
              let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CropFailureReason.cannotWriteImage
        }

        var properties = sourceProperties
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              CGImageSourceCreateWithURL(temporaryURL as CFURL, nil) != nil else {
            throw CropFailureReason.cannotWriteImage
        }

        do {
            if overwrite {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            throw CropFailureReason.cannotWriteImage
        }
    }

    // MARK: - Geometry helpers

    private nonisolated static func candidateCenters(
        preferred: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> [CGFloat] {
        let clamped = min(max(preferred, lower), upper)
        guard upper - lower > 0.5 else { return [clamped] }
        return (0...8).map { index in
            lower + (upper - lower) * CGFloat(index) / 8
        } + [clamped]
    }

    private nonisolated static func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private nonisolated static func pointInConvexPolygon(
        _ point: CGPoint,
        polygon: [CGPoint]
    ) -> Bool {
        var sign: CGFloat?
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y)
                - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 0.5 { continue }
            let current = cross > 0 ? CGFloat(1) : CGFloat(-1)
            if let sign, sign != current { return false }
            sign = current
        }
        return true
    }
}
