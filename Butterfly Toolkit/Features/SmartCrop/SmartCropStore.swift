// 管理独立裁剪的逐图草稿、异步预览和批次导出；有界缓存不持有整批原图。
import Foundation
import CoreGraphics
import Observation

nonisolated protocol SmartCropServing: Sendable {
    func preview(url: URL,ratio: CropRatio,adjustment: SmartCropAdjustment,expectedVersion: String?) async throws -> SmartCropPreview
    func export(source: URL,destination: URL,overwrite: Bool,plan: SmartCropPlan) async throws
}

// MARK: - 串行本机分析服务
actor SmartCropService: SmartCropServing {
    private struct Entry {
        var url: URL
        var version: String
        var bounds: CGRect?
        var prepared: PreparedMaskGeometry?
        var original: CGImage
        var size: CGSize
        var message: String?
    }
    private var cached: Entry?

    func preview(url: URL,ratio: CropRatio,adjustment: SmartCropAdjustment,expectedVersion: String? = nil) throws -> SmartCropPreview {
        try Task.checkCancellation()
        let version = try ButterflyCropProcessor.fingerprint(url)
        if let expectedVersion,expectedVersion != version { throw CropFailureReason.sourceChanged }
        let entry: Entry
        if let cached,cached.url == url,cached.version == version,cached.bounds == adjustment.manualBounds { entry = cached }
        else {
            // 开始下一张前释放上张完整蒙版，避免分析峰值随批次增长。
            cached = nil
            let full = try ButterflyCropProcessor.load(url),size = CGSize(width: full.width,height: full.height)
            let prepared: PreparedMaskGeometry?,message: String?
            do {
                if let bounds = adjustment.manualBounds { prepared = try ButterflyCropProcessor.manualGeometry(size: size,version: version,bounds: bounds) }
                else {
                    let mask = try ButterflySubjectDetector().detect(full)
                    prepared = try SpecimenGeometry.prepare(input: ButterflyCropProcessor.input(size: size,version: version),mask: mask)
                }
                message = nil
            } catch is CancellationError { throw CancellationError() }
            catch { prepared = nil; message = error.localizedDescription }
            let thumbnail = try ButterflyCropProcessor.load(url,maximumPixelSize: 2000)
            guard try ButterflyCropProcessor.fingerprint(url) == version else { throw CropFailureReason.sourceChanged }
            entry = Entry(url: url,version: version,bounds: adjustment.manualBounds,prepared: prepared,original: thumbnail,size: size,message: message)
            if (prepared?.estimatedStorageBytes ?? 0) <= 256*1024*1024 { cached = entry }
        }
        try Task.checkCancellation()
        var plan: SmartCropPlan?,image: CGImage?,message = entry.message
        if let prepared = entry.prepared {
            do {
                let result = try ButterflyCropProcessor.plan(prepared: prepared,adjustment: adjustment,ratio: ratio)
                plan = result
                message = result.solution.reason
                if result.solution.isApplicable {
                    image = try ButterflyCropProcessor.render(entry.original,sourceSize: entry.size,solution: result.solution,maximumPixelSize: 1600)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { message = error.localizedDescription }
        }
        return SmartCropPreview(original: entry.original,cropped: image,plan: plan,size: entry.size,version: version,message: message)
    }

    func export(source: URL,destination: URL,overwrite: Bool,plan: SmartCropPlan) throws {
        try ButterflyCropProcessor.export(source: source,destination: destination,overwrite: overwrite,plan: plan)
        if overwrite,cached?.url == source { cached = nil }
    }
}

// MARK: - 界面状态与逐图草稿
@MainActor @Observable final class SmartCropStore {
    struct Record {
        var adjustment = SmartCropAdjustment()
        var version: String?
        var plan: SmartCropPlan?
        var previewID: UUID?
        var outcome: String?
    }
    var files: [URL] = []
    var index = 0
    var ratio: CropRatio = .fiveFour
    var outputFolder: URL?
    var overwrite = false
    var preview: SmartCropPreview?
    var source: SmartCropSource?
    private(set) var thumbnails: [URL: SmartCropSource] = [:]
    var loading = false
    var processing = false
    var completed = 0
    var success = 0
    var skipped = 0
    var failed = 0
    var errorMessage: String?
    private(set) var records: [URL: Record] = [:]
    private var generation = UUID()
    private var previewTask: Task<Void,Never>?
    private var batchTask: Task<Void,Never>?
    private var sourceTask: Task<Void,Never>?
    private var thumbnailTask: Task<Void,Never>?
    private var batchGeneration = UUID()
    private var isVisible = true
    private var sourceURL: URL?
    private var previewCache = SmartCropPreviewCache()
    private let loadSource: @Sendable (URL,Int) async throws -> SmartCropSource
    private let checkVersion: @Sendable (URL) async throws -> String
    private let service: any SmartCropServing
    init(service: any SmartCropServing = SmartCropService(),
         loadSource: @escaping @Sendable (URL,Int) async throws -> SmartCropSource = { try await SmartCropSource.load($0,maximumPixelSize: $1) },
         checkVersion: @escaping @Sendable (URL) async throws -> String = { url in try await Task.detached { try ButterflyCropProcessor.fingerprint(url) }.value }) {
        self.service = service; self.loadSource = loadSource; self.checkVersion = checkVersion
    }
    isolated deinit { previewTask?.cancel(); batchTask?.cancel(); sourceTask?.cancel(); thumbnailTask?.cancel() }
    var currentURL: URL? { files.indices.contains(index) ? files[index] : nil }
    var adjustment: SmartCropAdjustment { currentURL.flatMap { records[$0]?.adjustment } ?? SmartCropAdjustment() }

    func select(_ urls: [URL],output: URL) {
        guard !processing else { return }
        files = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        previewTask?.cancel(); sourceTask?.cancel(); thumbnailTask?.cancel()
        batchGeneration = UUID(); previewCache = SmartCropPreviewCache(); thumbnails = [:]; source = nil
        records = [:]; index = 0; outputFolder = output; completed = 0; success = 0; skipped = 0; failed = 0
        preloadThumbnails()
        refresh()
    }
    func move(_ delta: Int) {
        guard !processing,!files.isEmpty else { return }
        selectIndex(min(files.count-1,max(0,index+delta)))
    }
    func selectIndex(_ value: Int) {
        guard !processing,files.indices.contains(value),value != index else { return }
        index = value; refresh()
    }
    private func preloadThumbnails() {
        thumbnailTask?.cancel()
        let token = batchGeneration,files = files.filter { thumbnails[$0] == nil },loader = loadSource
        thumbnailTask = Task { [weak self] in
            for url in files {
                if Task.isCancelled { return }
                if let value = try? await loader(url,160) {
                    guard !Task.isCancelled,let self,self.batchGeneration == token else { return }
                    self.thumbnails[url] = value
                    if self.currentURL == url,self.source == nil { self.source = value; self.sourceURL = url }
                }
            }
        }
    }
    func setRatio(_ value: CropRatio) {
        guard !processing else { return }
        guard ratio != value else { return }
        ratio = value
        discardPreviews(records.values.compactMap(\.previewID))
        for url in Array(records.keys) { records[url]?.plan = nil; records[url]?.previewID = nil; records[url]?.outcome = nil; records[url]?.adjustment.confirmed = false }
        refresh()
    }
    func edit(_ action: (inout SmartCropAdjustment) -> Void) {
        guard !processing,let url = currentURL else { return }
        var record = records[url] ?? Record()
        discardPreviews([record.previewID].compactMap { $0 })
        record.outcome = nil
        action(&record.adjustment); record.adjustment.confirmed = false; record.plan = nil; record.previewID = nil; records[url] = record
        refresh()
    }
    func confirm() {
        guard !loading,!processing,let url = currentURL,var value = preview,var plan = value.plan,plan.solution.isApplicable else { return }
        plan.needsReview = false; value.plan = plan; preview = value
        var record = records[url] ?? Record(); record.adjustment.confirmed = true; record.plan = plan; records[url] = record
    }
    func reload() {
        guard !processing,let url = currentURL else { return }
        discardPreviews([records[url]?.previewID].compactMap { $0 })
        records[url] = nil; thumbnails[url] = nil; source = nil; sourceURL = nil
        batchGeneration = UUID(); preloadThumbnails(); refresh()
    }
    func refresh() {
        previewTask?.cancel(); sourceTask?.cancel(); generation = UUID(); preview = nil; errorMessage = nil
        guard let url = currentURL else { loading = false; source = nil; return }
        if sourceURL != url || source == nil { source = thumbnails[url] }
        sourceURL = url
        loading = true
        let token = generation,record = records[url] ?? Record(),ratio = ratio,service = service
        let cache = previewCache,loader = loadSource,checkVersion = checkVersion
        sourceTask = Task { [weak self] in
            if let image = try? await loader(url,1600) {
                guard !Task.isCancelled,let self,self.generation == token else { return }
                self.source = image; self.sourceURL = url
            }
        }
        previewTask = Task { [weak self] in
            do {
                var result: SmartCropPreview
                var cacheID = record.previewID
                if let id = cacheID {
                    guard try await checkVersion(url) == record.version else { throw CropFailureReason.sourceChanged }
                    if let saved = try await cache.load(id) { result = saved }
                    else { cacheID = nil; result = try await service.preview(url: url,ratio: ratio,adjustment: record.adjustment,expectedVersion: record.version) }
                } else {
                    result = try await service.preview(url: url,ratio: ratio,adjustment: record.adjustment,expectedVersion: record.version)
                }
                guard !Task.isCancelled,self?.generation == token,self?.currentURL == url else { return }
                if record.adjustment.confirmed { result.plan?.needsReview = false }
                if cacheID == nil { cacheID = try await cache.save(result) }
                guard !Task.isCancelled,let self,self.generation == token,self.currentURL == url else { return }
                self.preview = result; self.loading = false
                self.source = SmartCropSource(image: result.original,size: result.size)
                var updated = record; updated.version = result.version; updated.plan = result.plan; updated.previewID = cacheID; self.records[url] = updated
            } catch {
                guard !Task.isCancelled,let self,self.generation == token else { return }
                self.loading = false; self.errorMessage = error.localizedDescription
                // 原图变化后旧构图不可再用于批次，人工草稿等待用户重新载入确认。
                self.discardPreviews([self.records[url]?.previewID].compactMap { $0 })
                self.records[url]?.plan = nil; self.records[url]?.previewID = nil
            }
        }
    }

    private func discardPreviews(_ ids: [UUID]) {
        let cache = previewCache
        Task { for id in ids { await cache.remove(id) } }
    }

    func resumePanel() {
        isVisible = true
        guard !processing,!files.isEmpty else { return }
        preloadThumbnails(); refresh()
    }

    // MARK: - 批次生命周期
    func start() {
        guard !processing,!loading,!files.isEmpty,overwrite || outputFolder != nil else { return }
        processing = true; completed = 0; success = 0; skipped = 0; failed = 0
        // 覆盖开始后旧缩略图读取即失去归属，不能在源图已更改后回填旧像素。
        if overwrite { thumbnailTask?.cancel(); batchGeneration = UUID() }
        let files = files,records = records,ratio = ratio,folder = outputFolder,overwrite = overwrite,service = service
        let cache = previewCache
        batchTask = Task { [weak self] in
            let sources = Set(files.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
            for url in files {
                if Task.isCancelled || self == nil { break }
                do {
                    let destination = overwrite ? url : folder!.appendingPathComponent(url.lastPathComponent)
                    if !overwrite,sources.contains(destination.standardizedFileURL.resolvingSymlinksInPath()) { throw CropFailureReason.destinationExists }
                    let record = records[url] ?? Record()
                    let plan: SmartCropPlan
                    if let existing = record.plan { plan = existing }
                    else {
                        let result = try await service.preview(url: url,ratio: ratio,adjustment: record.adjustment,expectedVersion: record.version)
                        try Task.checkCancellation()
                        let id = try await cache.save(result)
                        try Task.checkCancellation()
                        var updated = record; updated.version = result.version; updated.plan = result.plan; updated.previewID = id
                        self?.records[url] = updated
                        guard let candidate = result.plan else { throw CropFailureReason.subjectMaskUnreliable }
                        plan = candidate
                    }
                    guard plan.solution.isApplicable,!plan.needsReview else { throw CropFailureReason.needsReview }
                    try Task.checkCancellation()
                    try await service.export(source: url,destination: destination,overwrite: overwrite,plan: plan)
                    self?.success += 1
                    self?.records[url,default: Record()].outcome = "已导出"
                    // 覆盖后旧坐标与源版本立即失效，不能再次套用刚才的旋转。
                    if overwrite {
                        self?.discardPreviews([self?.records[url]?.previewID].compactMap { $0 })
                        self?.records[url] = Record(outcome: "已导出"); self?.thumbnails[url] = nil
                        if self?.currentURL == url { self?.source = nil; self?.sourceURL = nil; self?.preview = nil }
                    }
                } catch is CancellationError { break }
                catch {
                    if let reason = error as? CropFailureReason,
                       [.subjectNotFound,.subjectMaskUnreliable,.destinationExists,.sourceChanged,.needsReview].contains(reason) {
                        self?.skipped += 1; self?.records[url,default: Record()].outcome = reason.localizedDescription
                    } else { self?.failed += 1; self?.records[url,default: Record()].outcome = error.localizedDescription }
                }
                self?.completed += 1
            }
            self?.processing = false
            if overwrite,let self {
                self.batchGeneration = UUID()
                if self.isVisible { self.preloadThumbnails(); self.refresh() }
            }
        }
    }
    func cancel() { batchTask?.cancel() }
    func leavePanel() {
        // 页面消失后撤销结果归属，并停止尚未发布的批次；重新进入不能留下隐藏写入任务。
        isVisible = false
        generation = UUID(); previewTask?.cancel(); batchTask?.cancel(); sourceTask?.cancel(); thumbnailTask?.cancel(); loading = false
    }
}
