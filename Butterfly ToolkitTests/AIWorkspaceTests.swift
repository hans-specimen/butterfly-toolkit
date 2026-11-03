import XCTest
@testable import Butterfly_Toolkit

final class AIWorkspaceTests: XCTestCase {
    func testAlignedAnswerAndConfirmedGroupAreRequired() {
        var sample = AISample.fixture
        var record = AISampleCuration()
        XCTAssertFalse(record.canTrain(sample))
        record.specimenGroup = "SC1"
        record.groupConfirmed = true
        XCTAssertTrue(record.canTrain(sample))
        sample.alignment = "misaligned"
        XCTAssertFalse(record.canTrain(sample))
        sample.alignment = "unverified"
        XCTAssertFalse(record.canTrain(sample))
        sample.alignment = "aligned"
        sample.reference = nil
        XCTAssertFalse(record.canTrain(sample))
    }

    func testAllViewsOfASpecimenShareOneUse() {
        var library = AICuration()
        library.samples["front"] = AISampleCuration(specimenGroup: "SC1", groupConfirmed: true)
        library.samples["back"] = AISampleCuration(specimenGroup: "SC1", groupConfirmed: true)
        library.samples["crop"] = AISampleCuration(specimenGroup: "SC1", groupConfirmed: true)
        library.groupUses["SC1"] = .validation
        XCTAssertEqual(library.use(for: "front"), .validation)
        XCTAssertEqual(library.use(for: "back"), .validation)
        XCTAssertEqual(library.use(for: "crop"), .validation)
        XCTAssertEqual(library.use(for: "unknown"), .unassigned)
    }

    func testViewportPreservesOriginalCoordinatesAcrossPanels() {
        var viewport = AIViewport()
        viewport.center = CGPoint(x: 900, y: 700)
        viewport.zoom = 2
        let size = CGSize(width: 400, height: 300)
        let rect = viewport.imageRect(image: CGSize(width: 2000, height: 1000), panel: size)
        XCTAssertEqual(rect.width, 800)
        XCTAssertEqual(rect.midX, 240)
        XCTAssertEqual(rect.midY, 70)
        viewport.move(translation: CGSize(width: 40, height: -20), scale: 0.4, start: viewport.center)
        XCTAssertEqual(viewport.center.x, 800)
        XCTAssertEqual(viewport.center.y, 750)
    }
}

extension AISample {
    static var fixture: AISample {
        AISample(id: "front", name: "测试", original: "/tmp/original.png", reference: "/tmp/manual.png", alpha: nil,
                 prediction: nil, predictionAlpha: nil, width: 2000, height: 1000, color: "sRGB", alignment: "aligned",
                 alignmentNote: "已核对", rois: [])
    }
}

@MainActor
final class AIFileProtectionTests: XCTestCase {
    func testImportKeepsSuccessfulImageWhenAnotherFileFailsAndPersistsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.png")
        try Data("pixels".utf8).write(to: original)
        var sample = AISample.fixture
        sample.id = "new-original"; sample.original = original.path; sample.reference = nil; sample.alignment = "not_applicable"
        sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
        let encoded = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        let executable = directory.appendingPathComponent(".venv/bin/python")
        try """
        #!/bin/sh
        case "$6" in *bad.jpg) echo '{"event":"error","message":"损坏图片"}'; exit 1;; esac
        echo '{"event":"imported","sample":\(encoded)}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: directory.appendingPathComponent("scripts/toolkit_bridge.py"))
        let store = AIWorkspaceStore(); store.enginePath = directory.path
        store.catalog = AICatalog(schemaVersion: 1, model: AIModel(name: "base", revision: "fixed", available: true,
            inputSize: 2048, numericStatus: "unverified", qualitySummary: "待检查", testedSamples: 0), samples: [], runPath: "")
        await store.importImages([directory.appendingPathComponent("good.png"), directory.appendingPathComponent("bad.jpg")])
        XCTAssertEqual(store.samples.map(\.id), [sample.id])
        XCTAssertEqual(store.selectedID, sample.id)
        XCTAssertTrue(store.pairedSamples.isEmpty)
        XCTAssertTrue(store.error?.contains("损坏图片") == true)
        XCTAssertFalse(store.busy)
        let saved = try AIFileValidation.readCuration(engine: directory, samples: [])
        XCTAssertEqual(saved.imported.map(\.id), [sample.id])
    }

    func testExportRefusesExistingFileAndKeepsBothFilesIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("AI.png"), original = directory.appendingPathComponent("原图.png")
        try Data("AI".utf8).write(to: source); try Data("original".utf8).write(to: original)
        XCTAssertThrowsError(try AIWorkspaceStore.copyResult(from: source, to: original, protectedPaths: [original.path]))
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("AI".utf8))
        let output = directory.appendingPathComponent("新结果.png")
        try AIWorkspaceStore.copyResult(from: source, to: output, protectedPaths: [original.path])
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: source))
        XCTAssertThrowsError(try AIWorkspaceStore.copyResult(from: source, to: output, protectedPaths: []))
    }

    func testMissingEngineHasReadableError() async {
        do {
            _ = try await AIProcessRunner().run(engine: URL(fileURLWithPath: "/does-not-exist"), arguments: ["catalog"]) { _ in }
            XCTFail("Missing engine accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Python")) }
    }

    func testProcessReadsUTF8ErrorAfterLargeStderrWithoutBlocking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent(".venv/bin/python")
        try """
        #!/bin/sh
        /usr/bin/head -c 1000000 /dev/zero >&2
        echo '{"event":"error","message":"原图缺失，请重新选择"}'
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: directory.appendingPathComponent("scripts/toolkit_bridge.py"))
        do {
            _ = try await AIProcessRunner().run(engine: directory, arguments: ["infer"]) { _ in }
            XCTFail("Failed process accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "原图缺失，请重新选择") }
    }
}


final class AIAssetFreshnessTests: XCTestCase {
    @MainActor
    func testUnpairedImportPersistsWithoutBecomingTrainingMaterial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.png")
        try Data("original".utf8).write(to: original)
        var sample = AISample.fixture
        sample.id = "unpaired"; sample.original = original.path; sample.reference = nil
        sample.alignment = "not_applicable"
        sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
        XCTAssertEqual(sample.sourceHashes?.count, 1)
        XCTAssertEqual(AIFileValidation.revalidateImported(sample).alignment, "not_applicable")
        var library = AICuration(); library.imported = [sample]
        let restored = try JSONDecoder().decode(AICuration.self, from: JSONEncoder().encode(library))
        let store = AIWorkspaceStore(); store.samples = [.fixture] + restored.imported
        XCTAssertEqual(store.pairedSamples.map(\.id), ["front"])
        XCTAssertFalse(store.canTrain(restored.imported[0]))
        store.samples = restored.imported; store.selectedID = sample.id
        store.selectPairedSampleIfAvailable()
        XCTAssertEqual(store.selectedID, sample.id, "Visiting an empty training library must not strand existing cutout images")
        store.samples.append(.fixture)
        store.selectPairedSampleIfAvailable()
        XCTAssertEqual(store.selectedID, "front")
        try Data("changed".utf8).write(to: original)
        XCTAssertTrue(AIFileValidation.revalidateImported(sample).alignmentNote.contains("待抠"))
    }

    func testChangedOrMissingImportedAnswerLosesAlignmentApproval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.png"), reference = directory.appendingPathComponent("foreground.png")
        try Data("original".utf8).write(to: original); try Data("reference".utf8).write(to: reference)
        var sample = AISample.fixture
        sample.original = original.path; sample.reference = reference.path
        sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
        XCTAssertEqual(AIFileValidation.revalidateImported(sample).alignment, "aligned")
        try Data("changed".utf8).write(to: reference)
        XCTAssertEqual(AIFileValidation.revalidateImported(sample).alignment, "unverified")
        try FileManager.default.removeItem(at: reference)
        XCTAssertEqual(AIFileValidation.revalidateImported(sample).alignment, "unverified")
    }

    func testStaleInputOrMissingAlphaInvalidatesSavedPrediction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.png"), prediction = directory.appendingPathComponent("predicted.png"), alpha = directory.appendingPathComponent("alpha.png")
        try Data("original".utf8).write(to: original); try Data("prediction".utf8).write(to: prediction); try Data("alpha".utf8).write(to: alpha)
        var sample = AISample.fixture; sample.original = original.path
        let output = try AIFileValidation.captureOutput(prediction: prediction.path, alpha: alpha.path, original: original.path)
        XCTAssertTrue(AIFileValidation.outputIsCurrent(output, sample: sample))
        try Data("new source".utf8).write(to: original)
        XCTAssertFalse(AIFileValidation.outputIsCurrent(output, sample: sample))
        try Data("original".utf8).write(to: original)
        try FileManager.default.removeItem(at: alpha)
        XCTAssertFalse(AIFileValidation.outputIsCurrent(output, sample: sample))
    }
}
