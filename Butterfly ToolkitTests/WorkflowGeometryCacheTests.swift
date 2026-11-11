import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor final class WorkflowGeometryCacheTests: XCTestCase {
    func testInapplicableSavedPreviewReanalyzesWithoutClaimingSourceChanged() async throws {
        let f = try MaskGeometryProcessorTests.Fixture(width: 100,height: 100,subject: CGRect(x: 0,y: 0,width: 100,height: 100))
        defer { f.remove() }
        let roles = Self.roles(f.input),cache = WorkflowGeometryCache(prepare: Self.prepare)
        let preview = WorkflowPreviewService(geometry: cache)
        var saved = try Self.prepare(roles).analyze(request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        saved.isApplicable = false
        do {
            let result = try await preview.geometry(source: roles,request: GeometryRequest(angleStrategy: .manual(degrees: 0)),savedCandidate: saved)
            XCTAssertNotNil(result.reason); XCTAssertFalse(result.isApplicable)
            XCTAssertEqual(result.sourceCropRect,roles.cropViewport)
        } catch { XCTFail("An already inapplicable preview is a diagnostic, not a stale-source error: \(error)") }
        do { _ = try await cache.geometry(source: roles,request: GeometryRequest(),savedCandidate: saved); XCTFail("Strict apply validation accepted an inapplicable solution") } catch {}
        saved.sourceVersion = "stale"
        do { _ = try await preview.geometry(source: roles,request: GeometryRequest(),savedCandidate: saved); XCTFail("Stale preview accepted") } catch {}
    }
    func testConcurrentRequestsJoinOnePreparation() async throws {
        let f = try MaskGeometryProcessorTests.Fixture(width: 100,height: 100,subject: CGRect(x: 35,y: 35,width: 30,height: 30))
        defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe(blocked: true)
        let cache = WorkflowGeometryCache(maximumBytes: 0,prepare: { roles in
            await probe.record()
            return try Self.prepare(roles)
        })
        async let first = cache.geometry(source: roles,request: GeometryRequest(angleStrategy: .manual(degrees: 0)))
        async let second = cache.geometry(source: roles,request: GeometryRequest(angleStrategy: .manual(degrees: 10)))
        try await waitUntil { await cache.pendingRequestCount == 2 }
        await probe.release()
        let (a,b) = try await (first,second)
        XCTAssertNotEqual(a.angleDegrees,b.angleDegrees)
        let count = await probe.count
        XCTAssertEqual(count,1)
    }
    nonisolated static func roles(_ input: MaskGeometryInput) -> RoleImages {
        RoleImages(snapshotVersion: input.sourceVersion,basePNG: input.validBackgroundAlphaURL,cutoutPNG: input.maskURL,maskPNG: input.maskURL,pixelSize: input.sourcePixelSize,coordinateOrigin: input.coordinateOrigin,editableExtent: CGRect(origin: input.coordinateOrigin,size: input.sourcePixelSize),cropViewport: input.cropViewport)
    }
    nonisolated static func prepare(_ roles: RoleImages) throws -> PreparedMaskGeometry {
        try MaskGeometryProcessor().prepare(input: MaskGeometryInput(sourceVersion: roles.snapshotVersion,sourcePixelSize: roles.pixelSize,maskURL: roles.maskPNG,validBackgroundAlphaURL: roles.basePNG,coordinateOrigin: roles.coordinateOrigin,cropViewport: roles.cropViewport))
    }
    func testPreviewAndConfirmationPrepareSameSourceOnce() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe()
        let cache = WorkflowGeometryCache(prepare: { roles in await probe.record(); return try Self.prepare(roles) })
        let preview = WorkflowPreviewService(geometry: cache)
        let services = WorkflowExecutor.Services.live(bridge: PhotoshopWorkflowBridge(workspace: f.directory),geometry: cache)
        let request = GeometryRequest(angleStrategy: .manual(degrees: 0))
        let first = try await preview.geometry(source: roles,request: request)
        let validated = try await services.validateGeometry(roles,first)
        XCTAssertEqual(first,validated)
        let changed = GeometryRequest(targetMargin: 0.2,angleStrategy: .manual(degrees: 10))
        let actual = try await services.analyze(roles,changed)
        XCTAssertEqual(actual,try Self.prepare(roles).analyze(request: changed))
        XCTAssertNotEqual(actual,first)
        let count = await probe.count; XCTAssertEqual(count,1)
    }
    func testGeometryKeyIncludesRolePathsExtentOriginAndViewport() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),prepared = try Self.prepare(roles),probe = PreparationProbe()
        let cache = WorkflowGeometryCache(maximumEntries: 20,prepare: { _ in await probe.record(); return prepared })
        var variants = [roles]
        var changed = roles; changed.snapshotVersion += "2"; variants.append(changed)
        changed = roles; changed.maskPNG = f.directory.appendingPathComponent("other-mask.png"); variants.append(changed)
        changed = roles; changed.basePNG = f.directory.appendingPathComponent("other-base.png"); variants.append(changed)
        changed = roles; changed.pixelSize.width += 1; variants.append(changed)
        changed = roles; changed.coordinateOrigin.x -= 20; variants.append(changed)
        changed = roles; changed.editableExtent.size.height += 1; variants.append(changed)
        changed = roles; changed.cropViewport.origin.y += 1; variants.append(changed)
        for source in variants { _ = try await cache.geometry(source: source,request: request) }
        let count = await probe.count; XCTAssertEqual(count,variants.count)
        let alias = f.directory.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: roles.maskPNG)
        changed = roles; changed.maskPNG = alias; changed.cutoutPNG = alias
        _ = try await cache.geometry(source: changed,request: request)
        let afterAlias = await probe.count; XCTAssertEqual(afterAlias,count,"Canonical paths coalesce; cutout is not geometry input")
    }
    func testLRUEvictsOneEntryAndHonorsByteBudget() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),prepared = try Self.prepare(roles)
        XCTAssertEqual(prepared.estimatedStorageBytes,2*100*100+4*100*MemoryLayout<Int>.stride)
        for budget in [prepared.estimatedStorageBytes*4,prepared.estimatedStorageBytes*2] {
            let probe = PreparationProbe(),cache = WorkflowGeometryCache(maximumEntries: 4,maximumBytes: budget,prepare: { _ in await probe.record(); return prepared })
            let capacity = budget/prepared.estimatedStorageBytes
            func source(_ index: Int) -> RoleImages { var s = roles; s.snapshotVersion = String(index); return s }
            for index in 0..<capacity { _ = try await cache.geometry(source: source(index),request: request) }
            _ = try await cache.geometry(source: source(0),request: request) // Refresh the oldest.
            _ = try await cache.geometry(source: source(capacity),request: request)
            _ = try await cache.geometry(source: source(0),request: request)
            let beforeMiss = await probe.count; XCTAssertEqual(beforeMiss,capacity+1)
            _ = try await cache.geometry(source: source(1),request: request)
            let afterMiss = await probe.count; XCTAssertEqual(afterMiss,capacity+2)
            let bytes = await cache.retainedBytes,count = await cache.retainedCount
            XCTAssertLessThanOrEqual(bytes,budget); XCTAssertEqual(count,capacity)
        }
        let probe = PreparationProbe(),cache = WorkflowGeometryCache(maximumBytes: prepared.estimatedStorageBytes-1,prepare: { _ in await probe.record(); return prepared })
        for _ in 0..<2 { _ = try await cache.geometry(source: roles,request: request) }
        let count = await probe.count,bytes = await cache.retainedBytes
        XCTAssertEqual(count,2); XCTAssertEqual(bytes,0)
        let transparent = try MaskGeometryProcessorTests.Fixture(width: 100,height: 100,subject: CGRect(x: 35,y: 35,width: 30,height: 30),background: { $0[0] = 0 })
        defer { transparent.remove() }
        XCTAssertEqual(try Self.prepare(Self.roles(transparent.input)).estimatedStorageBytes,prepared.estimatedStorageBytes+101*101*MemoryLayout<UInt32>.stride)
    }
    func testCancelledWaiterDoesNotCancelSharedPreparation() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe(blocked: true)
        let cache = WorkflowGeometryCache(maximumBytes: 0,prepare: { source in await probe.record(); return try Self.prepare(source) })
        let first = Task { try await cache.geometry(source: roles,request: request) }
        let second = Task { try await cache.geometry(source: roles,request: request) }
        try await waitUntil { await cache.pendingRequestCount == 2 }
        first.cancel(); await probe.release()
        do { _ = try await first.value; XCTFail("Cancelled waiter must not publish") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let result = try await second.value; XCTAssertTrue(result.isApplicable)
        let count = await probe.count; XCTAssertEqual(count,1)
    }
    func testDifferentKeysPrepareSerially() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe(blocked: true)
        var other = roles; other.snapshotVersion += "2"
        let secondSource = other
        let cache = WorkflowGeometryCache(prepare: { source in await probe.record(); return try Self.prepare(source) })
        let first = Task { try await cache.geometry(source: roles,request: request) }
        try await waitUntil { await probe.count == 1 }
        let second = Task { try await cache.geometry(source: secondSource,request: request) }
        try await waitUntil { await cache.pendingRequestCount == 2 }
        let during = await probe.count; XCTAssertEqual(during,1)
        await probe.release(); _ = try await first.value; _ = try await second.value
        let after = await probe.count; XCTAssertEqual(after,2)
    }
    func testOldPreparationCannotRepopulateClearedCache() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe(blocked: true)
        let cache = WorkflowGeometryCache(prepare: { source in await probe.record(); return try Self.prepare(source) })
        let old = Task { try await cache.geometry(source: roles,request: request) }
        try await waitUntil { await probe.count == 1 }
        await cache.removeAll()
        let fresh = Task { try await cache.geometry(source: roles,request: request) }
        try await waitUntil { await cache.pendingRequestCount == 2 }
        let during = await probe.count; XCTAssertEqual(during,1,"Clearing must not permit overlapping preparations")
        await probe.release(); _ = try await old.value; _ = try await fresh.value
        _ = try await cache.geometry(source: roles,request: request)
        let count = await probe.count,retained = await cache.retainedCount
        XCTAssertEqual(count,2); XCTAssertEqual(retained,1)
        await cache.removeAll()
        let empty = await cache.retainedBytes; XCTAssertEqual(empty,0)
    }
    func testFailedPreparationCanBeRetried() async throws {
        let f = try fixture(); defer { f.remove() }
        let roles = Self.roles(f.input),probe = PreparationProbe()
        let cache = WorkflowGeometryCache(prepare: { source in
            await probe.record()
            if await probe.count == 1 { throw WorkflowBridgeError.staleSource }
            return try Self.prepare(source)
        })
        do { _ = try await cache.geometry(source: roles,request: request); XCTFail("Expected failure") } catch {}
        let result = try await cache.geometry(source: roles,request: request)
        XCTAssertTrue(result.isApplicable)
    }
    private var request: GeometryRequest { GeometryRequest(angleStrategy: .manual(degrees: 0)) }
    private func fixture() throws -> MaskGeometryProcessorTests.Fixture {
        try MaskGeometryProcessorTests.Fixture(width: 100,height: 100,subject: CGRect(x: 35,y: 35,width: 30,height: 30))
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for cache request")
        throw WorkflowBridgeError.staleSource
    }
    func testRealSharedGeometryTimingWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let batchPath = env["WORKFLOW_GEOMETRY_BATCH"],let evidencePath = env["WORKFLOW_GEOMETRY_EVIDENCE"] else { throw XCTSkip("Real geometry cache benchmark is opt-in") }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        var rows: [[String:Any]] = []
        for repetition in 1...3 {
            let probe = PreparationProbe()
            let cache = WorkflowGeometryCache(prepare: { source in await probe.record(); return try Self.prepare(source) })
            let preview = WorkflowPreviewService(geometry: cache)
            let services = WorkflowExecutor.Services.live(bridge: PhotoshopWorkflowBridge(workspace: evidence),geometry: cache)
            for phase in ["preview","confirmation","revisit"] {
                for task in batch.activeTasks {
                    let roles = try XCTUnwrap(task.roleImages),saved = try XCTUnwrap(task.geometrySolution)
                    let started = Date(),solution: GeometrySolution
                    if phase == "confirmation" { solution = try await services.validateGeometry(roles,saved) }
                    else { solution = try await preview.geometry(source: roles,request: task.geometryRequest,savedCandidate: saved) }
                    let seconds = Date().timeIntervalSince(started)
                    let name = task.snapshot!.workingURL.deletingPathExtension().lastPathComponent
                    let row: [String:Any] = ["repetition":repetition,"phase":phase,"face":name,"seconds":seconds,
                        "preparations":await probe.count,"retainedBytes":await cache.retainedBytes,"solution":try JSONSerialization.jsonObject(with: JSONEncoder().encode(solution))]
                    rows.append(row)
                    XCTAssertTrue(solution.isApplicable)
                    XCTAssertEqual(solution.sourceVersion,roles.snapshotVersion)
                }
            }
            try JSONSerialization.data(withJSONObject: rows,options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent("timings.json"))
        }
    }
}

private actor PreparationProbe {
    private(set) var count = 0
    private var blocked: Bool
    private var waiters: [CheckedContinuation<Void,Never>] = []
    init(blocked: Bool = false) { self.blocked = blocked }
    func record() async {
        count += 1
        if blocked { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        blocked = false
        for waiter in waiters { waiter.resume() }; waiters.removeAll()
    }
}
