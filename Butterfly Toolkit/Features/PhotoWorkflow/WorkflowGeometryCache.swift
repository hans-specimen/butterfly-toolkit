// 按保存版本与坐标信息缓存蒙版分析，合并并发准备请求，并限制会话内缓存占用。

import Foundation
import CoreGraphics

/// 仅在当前会话缓存蒙版和背景的准备分析，最终构图仍按每次请求计算。
actor WorkflowGeometryCache {
    // MARK: - 缓存身份与容量
    typealias Prepare = @Sendable (RoleImages) async throws -> PreparedMaskGeometry
    private struct Key: Hashable {
        let finalized: Bool
        let version: String
        let mask: String
        let base: String
        let coordinates: [Double]
        init(_ source: RoleImages) {
            finalized = source.isFinalized == true
            version = source.snapshotVersion
            mask = source.maskPNG.standardizedFileURL.resolvingSymlinksInPath().path
            base = source.basePNG.standardizedFileURL.resolvingSymlinksInPath().path
            let extent = source.editableExtent,viewport = source.cropViewport
            coordinates = [source.pixelSize.width,source.pixelSize.height,source.coordinateOrigin.x,source.coordinateOrigin.y,
                extent.minX,extent.minY,extent.width,extent.height,viewport.minX,viewport.minY,viewport.width,viewport.height]
        }
    }
    private struct Entry {
        let analysis: PreparedMaskGeometry
        var use: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<PreparedMaskGeometry,Error>
    }
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let prepare: Prepare
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var generation: UInt64 = 0
    private var clock: UInt64 = 0
    // 清空缓存时保留串行队尾，避免新旧代次的准备工作同时执行。
    private var tail: Task<Void,Never>?
    private var tailID: UUID?
    private(set) var retainedBytes = 0
    private(set) var pendingRequestCount = 0
    var retainedCount: Int { entries.count }

    init(maximumEntries: Int = 4,maximumBytes: Int = 512 * 1024 * 1024,
         prepare: @escaping Prepare = { source in
             if source.isFinalized == true {
                 let raster = try WorkflowRaster.read(source.cutoutPNG)
                 guard raster.size == source.pixelSize,raster.orientation == 1 else { throw WorkflowBridgeError.invalidStructure }
                 let alpha = stride(from: 3,to: raster.pixels.count,by: 4).map { raster.pixels[$0] }
                 return try SpecimenGeometry.prepare(input: GeometryImageInput(sourceVersion: source.snapshotVersion,
                     sourcePixelSize: source.pixelSize,coordinateOrigin: source.coordinateOrigin,cropViewport: source.cropViewport),mask: alpha)
             }
             return try MaskGeometryProcessor().prepare(input: MaskGeometryInput(sourceVersion: source.snapshotVersion,
                 sourcePixelSize: source.pixelSize,maskURL: source.maskPNG,validBackgroundAlphaURL: source.basePNG,
                 coordinateOrigin: source.coordinateOrigin,cropViewport: source.cropViewport))
         }) {
        self.maximumEntries = max(0,maximumEntries); self.maximumBytes = max(0,maximumBytes); self.prepare = prepare
    }

    // MARK: - 合并准备与按请求求解
    func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution? = nil) async throws -> GeometrySolution {
        try Task.checkCancellation()
        pendingRequestCount += 1
        defer { pendingRequestCount -= 1 }
        let key = Key(source),analysis: PreparedMaskGeometry
        if var entry = entries[key] {
            clock &+= 1; entry.use = clock; entries[key] = entry; analysis = entry.analysis
        } else {
            let epoch = generation,flight: Flight
            if let existing = flights[key] { flight = existing }
            else {
                let previous = tail,prepare = prepare,id = UUID()
                let work = Task.detached(priority: .userInitiated) {
                    await previous?.value
                    return try await prepare(source)
                }
                flight = Flight(id: id,task: work); flights[key] = flight
                tail = Task.detached { _ = try? await work.value }; tailID = id
            }
            do { analysis = try await flight.task.value }
            catch {
                finish(key: key,id: flight.id,epoch: epoch)
                throw error
            }
            // await 期间缓存可能已清空；旧代次结果可服务旧请求，但不能重新写回缓存。
            if generation == epoch,flights[key]?.id == flight.id {
                insert(analysis,key: key)
            }
            finish(key: key,id: flight.id,epoch: epoch)
        }
        // 取消某个等待者不会取消其他预览或确认操作共享的准备任务。
        try Task.checkCancellation()
        let solution = try await Task.detached(priority: .userInitiated) {
            if source.isFinalized == true {
                return GeometrySolution(sourceVersion: source.snapshotVersion,angleDegrees: 0,
                    rotationPivot: CGPoint(x: source.cropViewport.midX,y: source.cropViewport.midY),subjectBounds: analysis.support.bounds,
                    sourceCropRect: source.cropViewport,outputSize: source.cropViewport.size,
                    actualMargins: WorkflowMargins(left: 0,top: 0,right: 0,bottom: 0),isApplicable: true,
                    reason: analysis.support.detachedDetailCount > 0 ? "最终透明图含分离细节，请检查 4K 预览" : nil)
            }
            if let savedCandidate { return try analysis.validate(solution: savedCandidate) }
            return try analysis.analyze(request: request)
        }.value
        try Task.checkCancellation()
        return solution
    }
    func removeAll() async {
        generation &+= 1; entries.removeAll(); retainedBytes = 0; flights.removeAll()
    }
    private func finish(key: Key,id: UUID,epoch: UInt64) {
        if generation == epoch,flights[key]?.id == id { flights[key] = nil }
        if tailID == id { tail = nil; tailID = nil }
    }
    // MARK: - 按最近使用顺序淘汰
    // 同时约束条目数和保留字节，单项超预算时直接放弃缓存。
    private func insert(_ analysis: PreparedMaskGeometry,key: Key) {
        let bytes = analysis.estimatedStorageBytes
        guard maximumEntries > 0,bytes <= maximumBytes else { return }
        while entries.count >= maximumEntries || retainedBytes > maximumBytes - bytes {
            guard let oldest = entries.min(by: { $0.value.use < $1.value.use }) else { break }
            retainedBytes -= oldest.value.analysis.estimatedStorageBytes; entries[oldest.key] = nil
        }
        clock &+= 1; entries[key] = Entry(analysis: analysis,use: clock); retainedBytes += bytes
    }
}
