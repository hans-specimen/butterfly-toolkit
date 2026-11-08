// 会话内保留已完成预览：小图提前加载，结果存入专属临时目录，避免整批解码图常驻内存。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct SmartCropSource: Sendable {
    var image: CGImage
    var size: CGSize

    static func load(_ url: URL,maximumPixelSize: Int) async throws -> Self {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try ButterflyCropProcessor.load(url,maximumPixelSize: maximumPixelSize)
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
                  let w = info[kCGImagePropertyPixelWidth] as? Int,let h = info[kCGImagePropertyPixelHeight] as? Int else { throw CropFailureReason.cannotReadImage }
            let orientation = info[kCGImagePropertyOrientation] as? Int ?? 1
            let size = [5,6,7,8].contains(orientation) ? CGSize(width: h,height: w) : CGSize(width: w,height: h)
            try Task.checkCancellation()
            return Self(image: image,size: size)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

actor SmartCropPreviewCache {
    private struct Entry {
        var plan: SmartCropPlan?
        var size: CGSize
        var version: String
        var message: String?
        var hasCrop: Bool
    }
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toolkit-crop-preview-\(UUID())")
    private var entries: [UUID: Entry] = [:]
    private var hot: [(UUID,SmartCropPreview)] = []
    deinit { try? FileManager.default.removeItem(at: directory) }

    func save(_ value: SmartCropPreview) throws -> UUID {
        try Task.checkCancellation()
        let id = UUID(),folder = directory.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        do {
            try write(value.original,to: folder.appendingPathComponent("original.png"))
            if let cropped = value.cropped { try write(cropped,to: folder.appendingPathComponent("crop.png")) }
            try Task.checkCancellation()
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        entries[id] = Entry(plan: value.plan,size: value.size,version: value.version,message: value.message,hasCrop: value.cropped != nil)
        remember(id,value)
        return id
    }
    func load(_ id: UUID) throws -> SmartCropPreview? {
        if let value = hot.first(where: { $0.0 == id })?.1 { remember(id,value); return value }
        guard let entry = entries[id] else { return nil }
        let folder = directory.appendingPathComponent(id.uuidString)
        let value = SmartCropPreview(original: try read(folder.appendingPathComponent("original.png")),
            cropped: entry.hasCrop ? try read(folder.appendingPathComponent("crop.png")) : nil,
            plan: entry.plan,size: entry.size,version: entry.version,message: entry.message)
        remember(id,value); return value
    }
    func remove(_ id: UUID) {
        entries[id] = nil; hot.removeAll { $0.0 == id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }
    private func remember(_ id: UUID,_ value: SmartCropPreview) {
        hot.removeAll { $0.0 == id }; hot.append((id,value))
        // 缓存的是缩小预览，不是原片；限制数量和解码字节，磁盘结果不会因淘汰而重算。
        func cost() -> Int { hot.reduce(0) { $0+$1.1.original.bytesPerRow*$1.1.original.height+($1.1.cropped.map { $0.bytesPerRow*$0.height } ?? 0) } }
        while hot.count > 3 || cost() > 96*1024*1024 { hot.removeFirst() }
    }
    private func write(_ image: CGImage,to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else { throw CropFailureReason.cannotWriteImage }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw CropFailureReason.cannotWriteImage }
    }
    private func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CropFailureReason.cannotReadImage }
        return image
    }
}
