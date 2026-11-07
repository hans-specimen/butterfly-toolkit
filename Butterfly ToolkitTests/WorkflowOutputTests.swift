import XCTest
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowOutputTests: XCTestCase {
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
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        batch.outputDirectory = batch.sourceDirectory.appendingPathComponent("internal-records")
        batch.outputLocations = WorkflowOutputLocations()
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: batch.outputDirectory.appendingPathComponent("batch.json"))
        try await e.runPending(batchID: batch.id)
        let b = try await e.batch(batchID: batch.id)
        for task in b.activeTasks {
            XCTAssertEqual(task.snapshot?.workingURL.deletingLastPathComponent().path, b.sourceDirectory.path)
        }
    }

    func testWorkflowEndsAt4KWithoutRenderingDerivatives() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: f.batch, manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        var b = try await e.batch(batchID: f.batch.id)
        try await e.confirmGeometry(batchID: b.id, solutions: Dictionary(uniqueKeysWithValues: b.activeTasks.map { ($0.id, $0.geometrySolution!) }), exportHD: true)
        b = try await e.batch(batchID: b.id)
        try await e.confirm4K(batchID: b.id, layouts: Dictionary(uniqueKeysWithValues: b.activeTasks.map { ($0.id, $0.squareLayout) }))
        b = try await e.batch(batchID: b.id)
        XCTAssertTrue(b.allSucceeded)
        XCTAssertNil(b.currentStage)
        let calls = await f.probe.values()
        XCTAssertFalse(calls.contains("render-white1k"))
        XCTAssertFalse(calls.contains("render-xianyu"))
        XCTAssertFalse(calls.contains("render-footage"))
    }
    func testNoCheckpointsRunsThroughBothExports() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        batch.checkGeometry = false; batch.check4K = false
        batch.outputLocations = WorkflowOutputLocations(hd: batch.sourceDirectory.appendingPathComponent("hd-export"), png4k: batch.sourceDirectory.appendingPathComponent("4k-export"))
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        let result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.allSucceeded)
        for task in result.activeTasks {
            XCTAssertEqual(task.artifacts.count, 2)
            for artifact in task.artifacts {
                XCTAssertEqual(artifact.url.deletingLastPathComponent().path, batch.exportDirectory(for: artifact.kind)?.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
            }
        }
    }

    func testMissingDirectoriesMayBeChosenAtExportSteps() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.outputLocations = WorkflowOutputLocations()
        XCTAssertNoThrow(try batch.validateStart())
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        var result = try await e.batch(batchID: batch.id)
        try await e.confirmGeometry(batchID: batch.id, solutions: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id, $0.geometrySolution!) }), exportHD: true)
        result = try await e.batch(batchID: batch.id)
        XCTAssertEqual(result.currentStage, .hd)
        XCTAssertTrue(result.activeTasks.allSatisfy { $0[.hd].state == .pending })
        let hd = batch.sourceDirectory.appendingPathComponent("selected-hd")
        try await e.setExportDirectory(batchID: batch.id, kind: .hd, directory: hd)
        try await e.runPending(batchID: batch.id)
        result = try await e.batch(batchID: batch.id)
        XCTAssertEqual(result.currentStage, .png4k)
        do {
            try await e.confirm4K(batchID: batch.id, layouts: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id, $0.squareLayout) }))
            XCTFail("Missing 4K directory accepted")
        } catch {}
        try await e.setExportDirectory(batchID: batch.id, kind: .png4k, directory: batch.sourceDirectory.appendingPathComponent("selected-4k"))
        try await e.confirm4K(batchID: batch.id, layouts: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id, $0.squareLayout) }))
        result = try await e.batch(batchID: batch.id)
        XCTAssertTrue(result.allSucceeded)
    }

    func testDisablingAllCheckpointsRequiresBothDirectoriesAtStart() throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.checkGeometry = false; batch.check4K = false
        batch.outputLocations = WorkflowOutputLocations()
        XCTAssertThrowsError(try batch.validateStart())
        batch.outputLocations?.hd = batch.sourceDirectory
        XCTAssertThrowsError(try batch.validateStart())
        batch.outputLocations?.png4k = batch.sourceDirectory
        XCTAssertNoThrow(try batch.validateStart())
        batch.outputLocations = WorkflowOutputLocations(); batch.checkAfterMatte = true
        XCTAssertNoThrow(try batch.validateStart())
    }

    func testChangingCompleted4KDirectoryAllowsImmediateConfirmation() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch; batch.checkGeometry = false; batch.check4K = false
        let e = WorkflowExecutor(services: f.services)
        try await e.register(batch: batch, manifestURL: f.manifest)
        try await e.runPending(batchID: batch.id)
        let before = try await e.batch(batchID: batch.id)
        let folder = batch.sourceDirectory.appendingPathComponent("changed-4k")
        try await e.setExportDirectory(batchID: batch.id, kind: .png4k, directory: folder)
        try await e.confirm4K(batchID: batch.id, layouts: Dictionary(uniqueKeysWithValues: before.activeTasks.map { ($0.id, $0.squareLayout) }))
        let after = try await e.batch(batchID: batch.id)
        XCTAssertTrue(after.allSucceeded)
        for task in after.activeTasks {
            XCTAssertEqual(task.artifacts.last { $0.kind == .png4k }?.url.deletingLastPathComponent().path, folder.path)
        }
        for task in before.activeTasks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: task.artifacts.first { $0.kind == .png4k }!.url.path))
        }
    }

    func testMatteFailureRetainsTemporaryPNGsAndSuccessCleansOnlyManagedFiles() async throws {
        let f = try ExecutorFixture(checks: false)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let root = f.batch.outputDirectory
        let managed = root.appendingPathComponent(".work/data/processed/input.png")
        let alpha = root.appendingPathComponent(".work/AI/result/alpha.png")
        let cutout = root.appendingPathComponent(".work/AI/result/cutout.png")
        let external = root.appendingPathComponent("keep.png")
        try Data("external".utf8).write(to: external)
        var services = f.services
        services.exportStack = { snapshot in
            try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("input".utf8).write(to: managed)
            return StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: managed, fingerprint: "input", pixelSize: snapshot.pixelSize, orientation: 1, colorProfile: "sRGB", validBackgroundAlphaURL: external)
        }
        services.infer = { input in
            try FileManager.default.createDirectory(at: alpha.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("alpha".utf8).write(to: alpha); try Data("cutout".utf8).write(to: cutout)
            return MatteArtifact(inputPNGFingerprint: input.fingerprint, alphaURL: alpha, alphaFingerprint: "alpha", cutoutURL: cutout, cutoutFingerprint: "cutout", orientation: 1, pixelSize: input.pixelSize)
        }
        let install = services.install
        services.install = { saved, matte in
            guard await f.probe.values().contains("allow-install") else { throw WorkflowBridgeError.invalidImage("injected") }
            return try await install(saved, matte)
        }
        let e = WorkflowExecutor(services: services)
        try await e.register(batch: f.batch, manifestURL: f.manifest)
        try await e.runPending(batchID: f.batch.id)
        for url in [managed, alpha, cutout, external] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        await f.probe.record("allow-install")
        try await e.retry(batchID: f.batch.id, specimenIDs: f.batch.specimens.map(\.id), stage: .matte)
        for url in [managed, alpha, cutout] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
        let b = try await e.batch(batchID: f.batch.id)
        XCTAssertTrue(b.activeTasks.allSatisfy { $0.stackPNG == nil && $0.matteArtifact == nil && $0.snapshot?.roles != nil })
        let reloaded = WorkflowExecutor(services: services)
        _ = try await reloaded.register(manifestURL: f.manifest)
        try await reloaded.runPending(batchID: b.id)
        let calls = await f.probe.values()
        XCTAssertEqual(calls.filter { $0 == "install" }.count, 2)
    }

    func testChosenOutputDirectoryRejectsNestedSymlinkEscape() throws {
        let f = try ExecutorFixture(checks: false)
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

    func testGeometryAnd4KCheckpointCombinationsRespectReviewChoices() async throws {
        for geometryCheck in [false, true] {
            for fourKCheck in [false, true] {
                let f = try ExecutorFixture(checks: false)
                defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
                var batch = f.batch; batch.checkGeometry = geometryCheck; batch.check4K = fourKCheck
                let e = WorkflowExecutor(services: f.services)
                try await e.register(batch: batch, manifestURL: f.manifest)
                try await e.runPending(batchID: batch.id)
                var result = try await e.batch(batchID: batch.id)
                if geometryCheck {
                    XCTAssertEqual(result.currentStage, .geometry)
                    let calls = await f.probe.values(); XCTAssertFalse(calls.contains("apply-save"))
                    try await e.confirmGeometry(batchID: batch.id, solutions: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id, $0.geometrySolution!) }), exportHD: true)
                    result = try await e.batch(batchID: batch.id)
                }
                if fourKCheck {
                    XCTAssertEqual(result.currentStage, .png4k)
                    let calls = await f.probe.values(); XCTAssertFalse(calls.contains("render-png4k"))
                    try await e.confirm4K(batchID: batch.id, layouts: Dictionary(uniqueKeysWithValues: result.activeTasks.map { ($0.id, $0.squareLayout) }))
                    result = try await e.batch(batchID: batch.id)
                }
                XCTAssertTrue(result.allSucceeded)
            }
        }
    }

}
