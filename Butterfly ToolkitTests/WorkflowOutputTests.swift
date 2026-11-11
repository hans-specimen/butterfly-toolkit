import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowOutputTests: XCTestCase {
    func testDraftFreezesCropChoicesForEveryFaceAndAutomaticProcessingReadsThem() async throws {
        let f = try ExecutorFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let request = GeometryRequest(ratio: .fiveByFour,targetMargin: 0.16)
        let batch = try draft.freeze(names: "first\nsecond",output: f.batch.sourceDirectory.appendingPathComponent("output"),geometryRequest: request)
        XCTAssertEqual(batch.activeTasks.count,4)
        for task in batch.activeTasks {
            XCTAssertEqual(task.geometryRequest.ratio,.fiveByFour)
            XCTAssertEqual(task.geometryRequest.targetMargin,0.16)
            XCTAssertEqual(task.geometryRequest.angleStrategy,.automaticWingTips)
        }
        var services = f.services
        services.analyze = { roles, received in
            XCTAssertEqual(received.ratio,.fiveByFour)
            XCTAssertEqual(received.targetMargin,0.16)
            await f.probe.record("analyze-frozen-request")
            return ExecutorFixture.solution(roles.snapshotVersion)
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch,manifestURL: batch.outputDirectory.appendingPathComponent("batch.json"))
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.geometry].state == .waitingReview })
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "analyze-frozen-request" }.count,4)
    }

    func testDraftCropDefaultsKeepExistingCallersCompatible() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "sample",output: f.batch.sourceDirectory.appendingPathComponent("output"))
        for task in batch.activeTasks {
            XCTAssertEqual(task.geometryRequest.ratio,.adaptive)
            XCTAssertEqual(task.geometryRequest.targetMargin,0.1)
            XCTAssertEqual(task.geometryRequest.angleStrategy,.automaticWingTips)
        }
    }

    func testSkipPolicyAtPublicationPreservesReappearedOwnedFile() throws {
        let f = try WorkflowAssetRendererTests.Fixture(); defer { f.remove() }
        let store = WorkflowArtifactStore()
        let original = try store.publish(temp: f.roles.basePNG,artifact: f.artifact)
        let bytes = try Data(contentsOf: original.url)
        var next = f.artifact; next.sourceFingerprint = "new-version"
        XCTAssertThrowsError(try store.publish(temp: f.roles.cutoutPNG,artifact: next,overwriteExisting: false)) { error in
            XCTAssertEqual(error as? WorkflowArtifactError,.existingOutputSkipped)
        }
        XCTAssertEqual(try Data(contentsOf: original.url),bytes)
        XCTAssertEqual(try store.recover(artifact: f.artifact),original)
        XCTAssertEqual(try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact,overwriteExisting: false),original)
    }

    func testPublicationDecodesCandidateOnceAndVerifiesCopiedBytes() throws {
        let f = try WorkflowAssetRendererTests.Fixture(); defer { f.remove() }
        let probe = WorkflowDecodeProbe(),store = WorkflowArtifactStore(read: probe.read)
        let result = try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)
        XCTAssertEqual(probe.urls,[f.roles.cutoutPNG],"The identical sibling must not be decoded again")
        XCTAssertEqual(try Data(contentsOf: result.url),try Data(contentsOf: f.roles.cutoutPNG))
        XCTAssertEqual(result.fileFingerprint,try AIFileValidation.hash(result.url.path))
    }
    func testPublicationRejectsCandidateChangedDuringValidation() throws {
        let f = try WorkflowAssetRendererTests.Fixture(); defer { f.remove() }
        let candidate = f.roles.cutoutPNG,replacement = f.roles.basePNG
        let store = WorkflowArtifactStore(read: { url in
            let raster = try WorkflowRaster.read(url)
            if url == candidate { try Data(contentsOf: replacement).write(to: url) }
            return raster
        })
        XCTAssertThrowsError(try store.publish(temp: candidate,artifact: f.artifact)) { error in
            XCTAssertEqual(error as? WorkflowArtifactError,.fingerprintMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.artifact.url.path))
    }
    func testPublicationRejectsTamperedCopyAndRetainsPreviousOutput() throws {
        let f = try WorkflowAssetRendererTests.Fixture(); defer { f.remove() }
        let original = try WorkflowArtifactStore().publish(temp: f.roles.basePNG,artifact: f.artifact)
        let before = try Data(contentsOf: original.url)
        let receiptURL = f.root.appendingPathComponent(".published.png.workflow.json"),receipt = try Data(contentsOf: receiptURL)
        let replacement = f.roles.basePNG
        let store = WorkflowArtifactStore(copy: { source,destination in
            try FileManager.default.copyItem(at: source,to: destination)
            try Data(contentsOf: replacement).write(to: destination)
        })
        var next = f.artifact; next.sourceFingerprint = "new-source"
        XCTAssertThrowsError(try store.publish(temp: f.roles.cutoutPNG,artifact: next)) { error in
            XCTAssertEqual(error as? WorkflowArtifactError,.fingerprintMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: original.url),before)
        XCTAssertEqual(try Data(contentsOf: receiptURL),receipt)
        XCTAssertEqual(try WorkflowArtifactStore().recover(artifact: f.artifact),original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".publish-") })
    }
    func testPublicationRejectsSymlinkCopyEvenWithIdenticalBytes() throws {
        let f = try WorkflowAssetRendererTests.Fixture(); defer { f.remove() }
        let store = WorkflowArtifactStore(copy: { source,destination in
            try FileManager.default.createSymbolicLink(at: destination,withDestinationURL: source)
        })
        XCTAssertThrowsError(try store.publish(temp: f.roles.cutoutPNG,artifact: f.artifact)) { error in
            XCTAssertEqual(error as? WorkflowArtifactError,.ownershipConflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.artifact.url.path))
    }

    func testPSDIsCreatedBesideInputPhotos() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        batch.outputDirectory = batch.sourceDirectory.appendingPathComponent("internal-records")
        batch.outputLocations = WorkflowOutputLocations()
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: batch.outputDirectory.appendingPathComponent("batch.json"))
        try await e.runPending(batchID: batch.id)
        let b = try await e.batch(batchID: batch.id)
        for task in b.activeTasks {
            XCTAssertEqual(task.snapshot?.workingURL.deletingLastPathComponent().path, b.generatedPSDDirectory.path)
        }
    }

    func testWorkflowEndsAt4KWithoutRenderingDerivatives() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: f.batch, manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        var b = try await e.batch(batchID: f.batch.id)
        try await e.confirmSavedTasks(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)))
        try await e.requestExports(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)), kinds: [.hd], policy: .overwrite, layouts: [:])
        b = try await e.batch(batchID: b.id)
        try await e.requestExports(batchID: b.id, taskIDs: Set(b.activeTasks.map(\.id)), kinds: [.png4k], policy: .overwrite, layouts: [:])
        b = try await e.batch(batchID: b.id)
        XCTAssertTrue(b.allSucceeded)
        XCTAssertNil(b.currentStage)
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("render-white1k"))
        XCTAssertFalse(calls.contains("render-xianyu"))
        XCTAssertFalse(calls.contains("render-footage"))
    }

    func testChangingCompleted4KDirectoryAllowsImmediateConfirmation() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        try await e.confirmSavedTasks(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)))
        try await e.requestExports(batchID: batch.id, taskIDs: Set(batch.activeTasks.map(\.id)), kinds: [.png4k], policy: .overwrite, layouts: [:])
        let before = try await e.batch(batchID: batch.id)
        let folder = batch.sourceDirectory.appendingPathComponent("changed-4k")
        try await e.setExportDirectory(batchID: batch.id, kind: .png4k, directory: folder)
        try await e.requestExports(batchID: batch.id, taskIDs: Set(before.activeTasks.map(\.id)), kinds: [.png4k], policy: .overwrite, layouts: [:])
        let after = try await e.batch(batchID: batch.id)
        XCTAssertTrue(after.allSucceeded)
        for task in after.activeTasks {
            XCTAssertEqual(task.artifacts.last { $0.kind == .png4k }?.url.deletingLastPathComponent().path, folder.path)
        }
        for task in before.activeTasks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.artifacts.first { $0.kind == .png4k }!.url.path))
        }
    }


    func testChosenOutputDirectoryRejectsNestedSymlinkEscape() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let root = f.batch.outputDirectory
        let export = root.appendingPathComponent("export"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: export.appendingPathComponent("escape"), withDestinationURL: outside)
        var batch = f.batch; batch.outputLocations = WorkflowOutputLocations(hd: export, png4k: export)
        XCTAssertNoThrow(try batch.validateArtifactURL(export.appendingPathComponent("test.png"), kind: .png4k))
        XCTAssertThrowsError(try batch.validateArtifactURL(export.appendingPathComponent("escape/test.png"), kind: .png4k))
    }

}
