// 用可暂停的服务验证界面任务归属；像素与写入规则另由真实 JPEG 测试覆盖。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class SmartCropStoreTests: XCTestCase {
    func testReturningToCompletedPhotoDoesNotAnalyzeAgain() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service,checkVersion: { $0.path })
        let a = URL(fileURLWithPath: "/tmp/isolated-crop-a.jpg"),b = URL(fileURLWithPath: "/tmp/isolated-crop-b.jpg")
        store.select([a,b],output: URL(fileURLWithPath: "/tmp/isolated-crop-output"))
        try await waitUntil { await service.pendingCount == 1 }
        await service.release(path: a.path)
        try await waitUntil { store.preview?.version == a.path && !store.loading }
        store.move(1)
        try await waitUntil { await service.pendingCount == 1 }
        await service.release(path: b.path)
        try await waitUntil { store.preview?.version == b.path && !store.loading }
        store.move(-1)
        try await waitUntil { store.preview?.version == a.path && !store.loading }
        let count = await service.previewCount
        XCTAssertEqual(count,2)
        store.leavePanel()
        await service.releaseAll()
    }

    func testSourceAndAllThumbnailsLoadBeforeCropCompletes() async throws {
        let service = DelayedCropService(),source = Self.sourceImage()
        let store = SmartCropStore(service: service,loadSource: { _,_ in source },checkVersion: { $0.path })
        let urls = (0..<14).map { URL(fileURLWithPath: "/tmp/crop-\($0).jpg") }
        store.select(urls,output: URL(fileURLWithPath: "/tmp/crop-output"))
        try await waitUntil { store.thumbnails.count == 14 && store.source != nil }
        XCTAssertTrue(store.loading)
        XCTAssertNil(store.preview)
        store.selectIndex(5)
        XCTAssertNotNil(store.source)
        XCTAssertEqual(store.currentURL,store.files[5])
        try await waitUntil { await service.pendingCount == 2 }
        store.leavePanel()
        await service.releaseAll()
    }

    func testBatchAnalysisRemainsAvailableForPreview() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service,checkVersion: { $0.path })
        let url = URL(fileURLWithPath: "/tmp/isolated-crop-batch.jpg")
        store.files = [url]; store.outputFolder = URL(fileURLWithPath: "/tmp/crop-output")
        store.start()
        try await waitUntil { await service.pendingCount == 1 }
        await service.releaseAll()
        try await waitUntil { !store.processing }
        XCTAssertNotNil(store.records[url]?.previewID)
        store.refresh()
        try await waitUntil { !store.loading }
        let count = await service.previewCount
        XCTAssertEqual(count,1)
        store.leavePanel(); await service.releaseAll()
    }

    func testChangedSourceCannotReuseCompletedPreview() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service,checkVersion: { _ in "changed" })
        let url = URL(fileURLWithPath: "/tmp/isolated-crop-changed.jpg")
        store.select([url],output: URL(fileURLWithPath: "/tmp/crop-output"))
        try await waitUntil { await service.pendingCount == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        store.refresh()
        try await waitUntil { !store.loading }
        XCTAssertNil(store.preview)
        XCTAssertNil(store.records[url]?.plan)
        XCTAssertEqual(store.errorMessage,CropFailureReason.sourceChanged.localizedDescription)
        store.leavePanel()
    }

    func testRatioChangeRecomputesCompletedPreview() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service,checkVersion: { $0.path })
        let url = URL(fileURLWithPath: "/tmp/isolated-crop-ratio.jpg")
        store.select([url],output: URL(fileURLWithPath: "/tmp/crop-output"))
        try await waitUntil { await service.pendingCount == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        let previousID = store.records[url]?.previewID
        store.setRatio(.adaptive)
        try await waitUntil { await service.pendingCount == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        let count = await service.previewCount
        XCTAssertEqual(count,2)
        XCTAssertNotEqual(store.records[url]?.previewID,previousID)
        store.leavePanel()
    }

    func testEvictedPreviewRestoresPixelsAndMetadataFromDisk() async throws {
        let cache = SmartCropPreviewCache(),source = Self.sourceImage()
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(try await cache.save(SmartCropPreview(original: source.image,cropped: source.image,
                plan: nil,size: source.size,version: "version-\(index)",message: "message-\(index)")))
        }
        let restored = try await cache.load(ids[0])
        XCTAssertEqual(restored?.version,"version-0")
        XCTAssertEqual(restored?.message,"message-0")
        XCTAssertEqual(restored?.size,source.size)
        XCTAssertEqual(restored?.cropped?.width,100)
        XCTAssertEqual(restored?.cropped?.dataProvider?.data as Data?,source.image.dataProvider?.data as Data?)
    }

    func testReloadUpdatesThumbnailAfterSourceChanges() async throws {
        let service = DelayedCropService(),fixture = SourceFixture(Self.sourceImage())
        let store = SmartCropStore(service: service,loadSource: { _,_ in await fixture.value },checkVersion: { $0.path })
        let url = URL(fileURLWithPath: "/tmp/isolated-crop-reload.jpg")
        store.select([url],output: URL(fileURLWithPath: "/tmp/crop-output"))
        try await waitUntil { let count = await service.pendingCount; return store.thumbnails[url] != nil && count == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        var replacement = Self.sourceImage(); replacement.size = CGSize(width: 200,height: 200)
        await fixture.replace(replacement)
        store.reload()
        try await waitUntil { let count = await service.pendingCount; return store.thumbnails[url]?.size.width == 200 && count == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        XCTAssertEqual(store.thumbnails[url]?.size.width,200)
        store.leavePanel()
    }

    func testCancelledOverwriteRefreshesAlreadyWrittenPhoto() async throws {
        let service = DelayedCropService(),loader = PausedThumbnails(Self.sourceImage())
        let store = SmartCropStore(service: service,loadSource: { _,size in await loader.load(size) },checkVersion: { $0.path })
        let a = URL(fileURLWithPath: "/tmp/overwrite-a.jpg"),b = URL(fileURLWithPath: "/tmp/overwrite-b.jpg")
        store.select([a,b],output: URL(fileURLWithPath: "/tmp/crop-output"))
        try await waitUntil { await service.pendingCount == 1 }
        await service.releaseAll()
        try await waitUntil { !store.loading }
        try await waitUntil { await loader.waiting }
        store.confirm(); store.overwrite = true; store.start()
        try await waitUntil { let exported = await service.exportedCount; let pending = await service.pendingCount; return exported == 1 && pending == 1 }
        await loader.release()
        try await waitUntil { await loader.wasCancelled != nil }
        let cancelledThumbnail = await loader.wasCancelled
        XCTAssertEqual(cancelledThumbnail,true,"覆盖前启动的缩略图读取不得写回")
        store.cancel(); await service.releaseAll()
        try await waitUntil { let count = await service.pendingCount; return !store.processing && store.loading && count == 1 }
        XCTAssertNil(store.preview)
        await service.releaseAll()
        try await waitUntil { !store.loading }
        XCTAssertEqual(store.preview?.version,a.path)
        XCTAssertEqual(store.completed,1)
        store.leavePanel()
    }

    private static func sourceImage() -> SmartCropSource {
        let bytes = Data(repeating: 255,count: 100*100*4)
        let image = CGImage(width: 100,height: 100,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        return SmartCropSource(image: image,size: CGSize(width: 100,height: 100))
    }
    func testLeavingPanelCancelsPendingBatchBeforeExport() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service)
        store.files = [URL(fileURLWithPath: "/tmp/isolated-crop-a.jpg")]
        store.outputFolder = URL(fileURLWithPath: "/tmp/isolated-crop-output")
        store.start()
        try await waitUntil { await service.pendingCount == 1 }
        store.leavePanel()
        await service.releaseAll()
        try await waitUntil { !store.processing }
        let exported = await service.exportedCount
        XCTAssertEqual(exported,0,"离开面板后不得启动导出")
        XCTAssertEqual(store.success,0)
    }

    func testLatePreviewCannotReplaceCurrentPhoto() async throws {
        let service = DelayedCropService(),store = SmartCropStore(service: service)
        let a = URL(fileURLWithPath: "/tmp/isolated-crop-a.jpg"),b = URL(fileURLWithPath: "/tmp/isolated-crop-b.jpg")
        store.select([a,b],output: URL(fileURLWithPath: "/tmp/isolated-crop-output"))
        try await waitUntil { await service.pendingCount == 1 }
        store.move(1)
        try await waitUntil { await service.pendingCount == 2 }
        await service.release(path: b.path)
        try await waitUntil { store.preview?.version == b.path }
        await service.release(path: a.path)
        await Task.yield()
        XCTAssertEqual(store.preview?.version,b.path)
        XCTAssertEqual(store.currentURL,b)
        XCTAssertNil(store.records[a]?.version)
        store.leavePanel()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("异步状态未在期限内完成")
    }
}

private actor DelayedCropService: SmartCropServing {
    private var pending: [String: CheckedContinuation<Void,Never>] = [:]
    private(set) var exportedCount = 0
    private(set) var previewCount = 0
    var pendingCount: Int { pending.count }
    func preview(url: URL,ratio: CropRatio,adjustment: SmartCropAdjustment,expectedVersion: String?) async throws -> SmartCropPreview {
        previewCount += 1
        await withCheckedContinuation { pending[url.path] = $0 }
        // 故意模拟不响应取消的外部操作，界面必须自行阻止旧结果和后续写入。
        let bounds = CGRect(x: 20,y: 20,width: 60,height: 60),size = CGSize(width: 100,height: 100)
        let prepared = try await Task.detached {
            try ButterflyCropProcessor.manualGeometry(size: size,version: url.path,bounds: bounds)
        }.value
        let plan = try await Task.detached {
            try ButterflyCropProcessor.plan(prepared: prepared,adjustment: SmartCropAdjustment(manualBounds: bounds,manualAngle: 0),ratio: ratio)
        }.value
        let bytes = Data(repeating: 255,count: 100*100*4)
        let image = CGImage(width: 100,height: 100,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        return SmartCropPreview(original: image,cropped: image,plan: plan,size: size,version: url.path,message: nil)
    }
    func export(source: URL,destination: URL,overwrite: Bool,plan: SmartCropPlan) async throws { exportedCount += 1 }
    func release(path: String) { pending.removeValue(forKey: path)?.resume() }
    func releaseAll() { let all = pending.values; pending.removeAll(); for continuation in all { continuation.resume() } }
}

private actor SourceFixture {
    var value: SmartCropSource
    init(_ value: SmartCropSource) { self.value = value }
    func replace(_ value: SmartCropSource) { self.value = value }
}

// 暂停首张缩略图读取，模拟覆盖完成之后才返回的旧像素。
private actor PausedThumbnails {
    let value: SmartCropSource
    var continuation: CheckedContinuation<Void,Never>?
    var paused = false
    var wasCancelled: Bool?
    var waiting: Bool { continuation != nil }
    init(_ value: SmartCropSource) { self.value = value }
    func load(_ size: Int) async -> SmartCropSource {
        if size == 160,!paused {
            paused = true
            await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
        }
        return value
    }
    func release() { continuation?.resume(); continuation = nil }
}
