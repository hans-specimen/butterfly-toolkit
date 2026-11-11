import XCTest
import CoreGraphics
@testable import Butterfly_Toolkit

/// Photoshop operations are injected; commands, state transitions, persistence and (where noted) pixels are real.
@MainActor
final class WorkflowIntegrationTests: XCTestCase {
    func testTwoSpecimensRespectAllFourCheckpointCombinationsAndPairConfirmations() async throws {
        for stackCheck in [false, true] { for matteCheck in [false, true] {
            let f = try ExecutorFixture(checks: stackCheck, count: 2, checkMatte: matteCheck)
            defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
            let e = try await start(f)
            var b = try await e.batch(batchID: f.batch.id)
            if stackCheck {
                XCTAssertTrue(b.activeTasks.allSatisfy { $0[.stack].state == .waitingReview })
                let calls = await f.probe.values()
                XCTAssertEqual(calls.filter { $0 == "stack" }.count, 4)
                XCTAssertFalse(calls.contains("select-subject"))
                do {
                    try await e.continueAfterReview(batchID: b.id, stage: .stack, specimenIDs: [b.specimens[0].id])
                    XCTFail("Partial batch must not bypass the whole-batch checkpoint")
                } catch WorkflowStateError.invalidTransition {}
                try await e.continueAfterReview(batchID: b.id, stage: .stack, specimenIDs: b.specimens.map(\.id))
            }
            b = try await e.batch(batchID: b.id)
            if matteCheck {
                XCTAssertTrue(b.activeTasks.allSatisfy { $0[.matte].state == .waitingReview })
                let calls = await f.probe.values()
                XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 4)
                XCTAssertFalse(calls.contains("analyze"))
                try await e.continueAfterReview(batchID: b.id, stage: .matte, specimenIDs: b.specimens.map(\.id))
            }
            b = try await e.batch(batchID: b.id)
            XCTAssertTrue(b.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
            let front = b.specimens[0].front
            do {
                try await e.confirmGeometry(batchID: b.id, solutions: [front.id: front.geometrySolution!], exportHD: true)
                XCTFail("One face cannot confirm its specimen")
            } catch WorkflowStateError.invalidTransition {}
            try await confirmGeometry(f, e, specimenIndex: 0)
            b = try await e.batch(batchID: b.id)
            XCTAssertEqual(b.specimens[1].front[.geometry].state, .waitingReview)
            XCTAssertEqual(b.specimens[0].front[.png4k].state, .waitingReview)
            let calls = await f.probe.values()
            XCTAssertFalse(calls.contains("render-png4k"))
            do {
                try await e.confirm4K(batchID: b.id, layouts: [front.id: b.specimens[0].front.squareLayout])
                XCTFail("One face cannot confirm 4K")
            } catch WorkflowStateError.invalidTransition {}
            try await confirm4K(f, e, specimenIndex: 0)
            try await confirmGeometry(f, e, specimenIndex: 1)
            try await confirm4K(f, e, specimenIndex: 1)
            b = try await e.batch(batchID: b.id)
            XCTAssertTrue(b.allSucceeded)
            XCTAssertEqual(b.specimens.map(\.baseName), f.batch.specimens.map(\.baseName))
            XCTAssertEqual(b.sideTasks.map(\.sources), f.batch.sideTasks.map(\.sources))
            let disk = try await WorkflowBatchStore().load(from: f.manifest)
            XCTAssertEqual(disk, b)
            for source in f.batch.sideTasks.flatMap({ $0.sources.files }) {
                XCTAssertEqual(try AIFileValidation.hash(source.url.path), source.fingerprint)
            }
        } }
    }

    func testSingleSideFailureBlocksAutomaticAdvanceAndRetryKeepsSuccessfulSides() async throws {
        let f = try ExecutorFixture(checks: false, count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let failedID = f.batch.specimens[0].front.id
        var services = f.services
        let stack = services.stack
        services.stack = { job, owner in
            if owner == failedID { throw WorkflowBridgeError.invalidImage("injected single-side failure") }
            return try await stack(job, owner)
        }
        let e = try await start(f, services: services)
        var b = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(b.task(id: failedID)?[.stack].state, .failed)
        XCTAssertEqual(b.activeTasks.filter { $0[.stack].state == .completed }.count, 3)
        var calls = await f.probe.values()
        XCTAssertFalse(calls.contains("select-subject"))
        let reopened = WorkflowExecutor(services: f.services)
        _ = try await reopened.register(manifestURL: f.manifest)
        try await reopened.retry(batchID: b.id, specimenIDs: [b.specimens[0].id], stage: .stack)
        b = try await reopened.batch(batchID: b.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "stack" }.count, 4, "Only the failed side is stacked after reload")
        XCTAssertEqual(calls.filter { $0 == "select-subject" }.count, 4)
    }

    func testExplicitExclusionKeepsBothFacesAndOriginalNameMappingInSummary() async throws {
        let f = try ExecutorFixture(checks: false, count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let failedID = f.batch.specimens[0].back.id
        var services = f.services
        let stack = services.stack
        services.stack = { job, owner in
            if owner == failedID { throw WorkflowBridgeError.invalidImage("injected") }
            return try await stack(job, owner)
        }
        let e = try await start(f, services: services)
        var b = try await e.batch(batchID: f.batch.id)
        try await e.update(batchID: b.id, event: .excludeSpecimens(ids: [b.specimens[0].id], reason: "本轮明确暂不处理", expectedRevision: b.revision))
        try await e.runPending(batchID: b.id)
        try await confirmGeometry(f, e, specimenIndex: 1)
        try await confirm4K(f, e, specimenIndex: 1)
        b = try await e.batch(batchID: b.id)
        XCTAssertTrue(b.specimens[0].isExcluded)
        XCTAssertTrue([b.specimens[0].front, b.specimens[0].back].allSatisfy { $0[.stack].state == .excluded })
        XCTAssertEqual(b.activeTasks.count, 2)
        XCTAssertEqual(b.specimens[1].baseName, "sample1")
        XCTAssertFalse(b.allSucceeded, "Excluded specimen remains visible and prevents an all-success claim")
        XCTAssertTrue(b.activeTasks.allSatisfy { $0[.png4k].state == .completed })
    }

    func testUnsavedPSDPreventsRefreshAndResumeUntilSavedAndExplicitContinue() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let saved = IntegrationSavedState()
        var services = f.services
        let refresh = services.refresh
        services.refresh = { url, owner, sources in
            if await saved.isUnsaved { throw WorkflowBridgeError.unsavedDocument }
            return try await refresh(url, owner, sources)
        }
        let e = try await start(f, services: services)
        let b = try await e.batch(batchID: f.batch.id), side = b.activeTasks[0]
        _ = try await e.beginManualEditing(batchID: b.id, taskID: side.id)
        await saved.setUnsaved(true)
        do {
            try await e.refreshSavedPSD(batchID: b.id, taskID: side.id, change: .maskOnly)
            XCTFail("Unsaved document refreshed")
        } catch WorkflowBridgeError.unsavedDocument {}
        do {
            try await e.continueAutomatic(batchID: b.id)
            XCTFail("Unsaved document resumed")
        } catch WorkflowBridgeError.unsavedDocument {}
        let blocked = try await e.batch(batchID: b.id)
        XCTAssertTrue(blocked.isPaused)
        XCTAssertEqual(blocked.task(id: side.id)?.snapshot, side.snapshot)
        await saved.setUnsaved(false)
        try await e.refreshSavedPSD(batchID: b.id, taskID: side.id, change: .maskOnly)
        let refreshed = try await e.batch(batchID: b.id)
        XCTAssertTrue(refreshed.isPaused, "Refresh alone does not release the editing lease")
        try await e.continueAutomatic(batchID: b.id)
        let resumed = try await e.batch(batchID: b.id)
        XCTAssertFalse(resumed.isPaused)
    }

    func testRestartAt4KReviewDoesNotRepeatEarlierWorkAndOnly4KChangesInvalidateDescendants() async throws {
        let f = try ExecutorFixture(checks: false, count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let first = try await start(f)
        try await confirmGeometry(f, first)
        let before = try await first.batch(batchID: f.batch.id), callsBefore = await f.probe.values()
        let e = WorkflowExecutor(services: f.services)
        _ = try await e.register(manifestURL: f.manifest)
        try await e.runPending(batchID: before.id)
        let callsAfterReload = await f.probe.values()
        XCTAssertEqual(callsAfterReload, callsBefore)
        try await confirm4K(f, e)
        let completed = try await e.batch(batchID: before.id), callsCompleted = await f.probe.values()
        let hdBefore = completed.activeTasks.map { $0[.hd] }
        let hdHashes = try completed.activeTasks.flatMap(\.artifacts).filter { $0.kind == .hd }.map { try AIFileValidation.hash($0.url.path) }
        try await e.update(batchID: before.id, event: .presetChanged(scope: .png4k, preset: WorkflowPreset(version: 2, fingerprint: "safe-margin384"), expectedRevision: completed.revision))
        try await e.runPending(batchID: before.id)
        try await confirm4K(f, e, margin: 384)
        let changed = try await e.batch(batchID: before.id), callsChanged = await f.probe.values()
        for call in ["stack", "select-subject", "analyze", "apply-save", "render-hd"] {
            XCTAssertEqual(callsChanged.filter { $0 == call }.count, callsCompleted.filter { $0 == call }.count, call)
        }
        XCTAssertEqual(changed.activeTasks.map { $0[.hd] }, hdBefore)
        XCTAssertEqual(try changed.activeTasks.flatMap(\.artifacts).filter { $0.kind == .hd }.map { try AIFileValidation.hash($0.url.path) }, hdHashes)
        XCTAssertTrue(changed.allSucceeded)
        XCTAssertTrue(changed.activeTasks.allSatisfy { $0.squareLayout.safeMargin == 384 })
    }

    func testForeignSameNamedHDIsNeverOverwrittenOrAdopted() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let image = try WorkflowAssetRendererTests.Fixture()
        defer { image.remove() }
        let renderer = WorkflowAssetRenderer(), store = WorkflowArtifactStore()
        let foreign = f.batch.outputDirectory.appendingPathComponent("高清堆栈/sample0_D.jpg")
        var services = f.services
        services.render = { kind, roles, layout, source, watermark, output in
            if kind == .hd { try renderer.renderHD(roles: image.roles, destination: output) }
            else { try await f.services.render(kind, roles, layout, source, watermark, output) }
        }
        services.recover = { artifact in
            try artifact.url == foreign ? store.recover(artifact: artifact) : f.services.recover(artifact)
        }
        services.publish = { temp, artifact in
            try artifact.url == foreign ? store.publish(temp: temp, artifact: artifact) : f.services.publish(temp, artifact)
        }
        let e = try await start(f, services: services)
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renderer.renderHD(roles: image.roles, destination: foreign)
        let bytes = try Data(contentsOf: foreign)
        XCTAssertEqual(try WorkflowRaster.read(foreign).size, image.roles.cropViewport.size)
        try await confirmGeometry(f, e)
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertEqual(b.specimens[0].front[.hd].state, .failed)
        XCTAssertEqual(b.specimens[0].front[.hd].error, WorkflowArtifactError.ownershipConflict.localizedDescription)
        XCTAssertEqual(b.specimens[0].back[.hd].state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.deletingLastPathComponent().appendingPathComponent(".sample0_D.jpg.workflow.json").path))
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        XCTAssertFalse(b.specimens[0].front.artifacts.contains { $0.kind == .hd && $0.state == .completed })
        XCTAssertFalse(b.allSucceeded)
    }

    func testRealRendererAndPublisherFinishWithConfirmedTransparent4K() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let image = try WorkflowAssetRendererTests.Fixture(subject: CGRect(x: 10, y: 10, width: 80, height: 60))
        defer { image.remove() }
        let renderer = WorkflowAssetRenderer(), store = WorkflowArtifactStore()
        var services = f.services
        services.extract = { snapshot in
            var roles = image.roles
            roles.snapshotVersion = snapshot.contentVersion
            roles.cropViewport = CGRect(x: 0, y: 0, width: 100, height: 80)
            return roles
        }
        services.render = { kind, roles, layout, source, watermark, output in
            await f.probe.record("render-\(kind.rawValue)")
            try await Task.detached {
                switch kind {
                case .hd: try renderer.renderHD(roles: XCTUnwrap(roles), destination: output)
                case .png4k: try renderer.render4K(roles: XCTUnwrap(roles), layout: layout, destination: output)
                case .white1k: try renderer.renderWhite1K(source4K: XCTUnwrap(source), destination: output)
                case .footage: try renderer.renderFootage(source4K: XCTUnwrap(source), destination: output)
                case .xianyu:
                    guard let watermark else { throw WorkflowBridgeError.invalidImage("请选择水印文件") }
                    try renderer.renderXianyu(source4K: XCTUnwrap(source), watermark: watermark, destination: output)
                }
            }.value
        }
        services.publish = { try store.publish(temp: $0, artifact: $1) }
        services.recover = { try store.recover(artifact: $0) }
        let e = try await start(f, services: services)
        try await confirmGeometry(f, e)
        try await confirm4K(f, e)
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.allSucceeded)
        for task in b.activeTasks {
            XCTAssertEqual(task[.png4k].state, .completed)
            XCTAssertEqual(Set(task.artifacts.map(\.kind)), [.hd, .png4k])
            let four = try XCTUnwrap(task.artifacts.last { $0.kind == .png4k && $0.state == .completed })
            XCTAssertEqual(try AIFileValidation.hash(four.url.path), four.fileFingerprint)
            let fourPixels = try WorkflowRaster.read(four.url)
            XCTAssertEqual(fourPixels.size, CGSize(width: 4096, height: 4096))
            XCTAssertEqual(Array(fourPixels.pixels.prefix(4)), [0, 0, 0, 0])
            let fourBounds = try XCTUnwrap(bounds(fourPixels, alpha: true))
            XCTAssertEqual(fourBounds.minX, 256, accuracy: 1)
            XCTAssertEqual(fourBounds.maxX, 3840, accuracy: 1)
            XCTAssertEqual(try store.recover(artifact: four), four)
        }
    }

    private func start(_ f: ExecutorFixture, services: WorkflowExecutor.Services? = nil) async throws -> WorkflowExecutor {
        let e = WorkflowExecutor(services: services ?? f.services, coordinator: PhotoshopExecutionCoordinator())
        try await e.register(batch: f.batch, manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        return e
    }
    private func confirmGeometry(_ f: ExecutorFixture, _ e: WorkflowExecutor, specimenIndex: Int? = nil) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        let specimens = specimenIndex.map { [b.specimens[$0]] } ?? b.specimens.filter { !$0.isExcluded }
        let tasks = specimens.flatMap { [$0.front, $0.back] }
        try await e.confirmGeometry(batchID: b.id, solutions: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.geometrySolution!) }), exportHD: true)
    }
    private func confirm4K(_ f: ExecutorFixture, _ e: WorkflowExecutor, specimenIndex: Int? = nil, margin: Int? = nil) async throws {
        let b = try await e.batch(batchID: f.batch.id)
        let specimens = specimenIndex.map { [b.specimens[$0]] } ?? b.specimens.filter { !$0.isExcluded }
        let layouts = Dictionary(uniqueKeysWithValues: specimens.flatMap { [$0.front, $0.back] }.map { task in
            var layout = task.squareLayout
            if let margin { layout.safeMargin = margin }
            return (task.id, layout)
        })
        try await e.confirm4K(batchID: b.id, layouts: layouts)
    }
    private func bounds(_ raster: WorkflowRaster, alpha: Bool) -> CGRect? {
        let w = Int(raster.size.width), h = Int(raster.size.height)
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            let subject = alpha ? raster.pixels[i+3] > 0 : raster.pixels[i] < 254 || raster.pixels[i+1] < 254 || raster.pixels[i+2] < 254
            if subject { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x+1); y1 = max(y1, y+1) }
        } }
        return x1 > x0 ? CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0) : nil
    }
}

private actor IntegrationSavedState {
    var isUnsaved = false
    func setUnsaved(_ value: Bool) { isUnsaved = value }
}
