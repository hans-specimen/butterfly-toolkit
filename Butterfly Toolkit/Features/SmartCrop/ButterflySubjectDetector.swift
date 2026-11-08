// 使用系统 Vision 或背景色差生成本机主体蒙版，显式处理像素格式与识别质量。
import Foundation
import CoreGraphics
import Vision

nonisolated struct ButterflySubjectDetector {
    func detect(_ image: CGImage) throws -> [UInt8] {
        try Task.checkCancellation()
        guard image.width >= 8,image.height >= 8 else { throw CropFailureReason.subjectNotFound }
        do {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image,orientation: .up,options: [:])
            try handler.perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first,!observation.allInstances.isEmpty else { throw CropFailureReason.subjectNotFound }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances,from: handler)
            guard CVPixelBufferGetWidth(buffer) == image.width,CVPixelBufferGetHeight(buffer) == image.height else { throw CropFailureReason.subjectMaskUnreliable }
            let values = try Self.maskValues(buffer)
            try validate(values,width: image.width,height: image.height)
            return values
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return try backgroundDifferenceMask(for: image)
        }
    }

    static func maskValues(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { throw CropFailureReason.subjectMaskUnreliable }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CropFailureReason.subjectMaskUnreliable }
        let w = CVPixelBufferGetWidth(buffer),h = CVPixelBufferGetHeight(buffer),stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0,count: w*h)
        for y in 0..<h {
            if y % 128 == 0 { try Task.checkCancellation() }
            let row = base.advanced(by: y*stride)
            for x in 0..<w {
                if format == kCVPixelFormatType_OneComponent32Float {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    guard value.isFinite else { throw CropFailureReason.subjectMaskUnreliable }
                    values[y*w+x] = UInt8((max(0,min(1,value))*255).rounded())
                } else { values[y*w+x] = row.assumingMemoryBound(to: UInt8.self)[x] }
            }
        }
        return values
    }

    private func validate(_ values: [UInt8],width: Int,height: Int) throws {
        var strong = 0
        for i in values.indices {
            if i % 65536 == 0 { try Task.checkCancellation() }
            if values[i] >= 16 { strong += 1 }
        }
        let coverage = Double(strong)/Double(values.count)
        guard coverage > 0.008,coverage < 0.94 else { throw CropFailureReason.subjectMaskUnreliable }
        // 大面积触边通常意味着把背景或阴影当成了主体；交给人工范围确认。
        var border = 0
        for x in 0..<width { border += values[x] >= 16 ? 1 : 0; border += values[(height-1)*width+x] >= 16 ? 1 : 0 }
        for y in 0..<height { border += values[y*width] >= 16 ? 1 : 0; border += values[y*width+width-1] >= 16 ? 1 : 0 }
        guard Double(border)/Double(2*(width+height)) < 0.15 else { throw CropFailureReason.subjectMaskUnreliable }
    }

    // MARK: - 纯色背景后备识别
    private func backgroundDifferenceMask(
        for image: CGImage
    ) throws -> [UInt8] {
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
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CropFailureReason.cannotCreateImage
        }
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
            try Task.checkCancellation()
            for y in Swift.stride(from: 0, to: borderDepth, by: sampleStep) {
                appendPixel(x: x, y: y)
                appendPixel(x: x, y: height - 1 - y)
            }
        }
        for y in Swift.stride(from: borderDepth, to: height - borderDepth, by: sampleStep) {
            try Task.checkCancellation()
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
            if y % 32 == 0 { try Task.checkCancellation() }
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

        // 连接鳞片与触角周围的细小断点，再移除孤立的灰尘区域。
        binary = try erode(
            dilate(binary, width: width, height: height, radius: 2),
            width: width,
            height: height,
            radius: 2
        )
        try validate(binary,width: width,height: height)
        return binary
    }

    private func median(_ values: [UInt8]) -> UInt8 {
        values.sorted()[values.count / 2]
    }

    private func colorDistance(
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        background: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> CGFloat {
        // 略微提高亮度差的权重，同时保留色差对浅色翅膀的区分能力。
        let dr = r - background.r
        let dg = g - background.g
        let db = b - background.b
        let luminance = 0.2126 * dr + 0.7152 * dg + 0.0722 * db
        return sqrt(dr * dr + dg * dg + db * db + 0.35 * luminance * luminance)
    }

    private func saturation(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        return maximum == 0 ? 0 : (maximum - minimum) / maximum
    }

    private func dilate(
        _ source: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) throws -> [UInt8] {
        var output = source
        for y in 0..<height {
            if y % 16 == 0 { try Task.checkCancellation() }
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

    private func erode(
        _ source: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: source.count)
        guard width > radius * 2, height > radius * 2 else { return output }
        for y in radius..<(height - radius) {
            if y % 16 == 0 { try Task.checkCancellation() }
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

}
