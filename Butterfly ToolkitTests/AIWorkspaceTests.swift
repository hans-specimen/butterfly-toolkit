import XCTest
import SwiftUI
@testable import Butterfly_Toolkit

@MainActor
final class AIMaterialListLayoutTests: XCTestCase {
    func testRowsKeepTheirHeightWhenOffscreenCellsAreCreated() async throws {
        let store = AIWorkspaceStore()
        store.samples = (0..<30).map { index in
            var sample = AISample.fixture
            sample.id = "row-\(index)"
            sample.name = "SC10169_黄顶图蛱蝶雌 Callicore astarte casta_\(index)"
            return sample
        }
        let host = NSHostingView(rootView: AISamplesView(store: store, navigate: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
        let table = try XCTUnwrap(tables(in: host).first)
        let before = (0..<30).map { table.rect(ofRow: $0) }
        XCTAssertGreaterThanOrEqual(before[0].height, 52, "Rows must fit their thumbnail and padding")
        for row in 0..<30 { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let after = (0..<30).map { table.rect(ofRow: $0) }
        for row in 0..<30 {
            XCTAssertEqual(before[row].height, before[0].height, accuracy: 0.5, "Offscreen rows must not use a different estimated height")
            XCTAssertEqual(after[row].minY, before[row].minY, accuracy: 0.5, "Creating cells must not shift later rows")
        }
        store.setMaterialSelection(Set(store.pairedSamples.map(\.id)))
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        for row in 0..<30 {
            XCTAssertEqual(table.rect(ofRow: row).height, before[0].height, accuracy: 0.5,
                           "Selection updates must not reset the native row height or clip thumbnails")
        }
    }
}

final class AIWorkspaceTests: XCTestCase {
    @MainActor
    func testSelectAllTrainingSamplesRechecksFilesAndKeepsOnlyEligible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIWorkspaceStore(); store.workspacePath = directory.path
        for index in 0..<4 {
            var sample = AISample.fixture; sample.id = "bulk-\(index)"
            sample.original = directory.appendingPathComponent("original-\(index)").path
            sample.reference = directory.appendingPathComponent("answer-\(index)").path
            for path in [sample.original, sample.reference!] { try Data("data".utf8).write(to: URL(fileURLWithPath: path)) }
            sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
            if index == 1 { sample.answerConfirmed = false }
            if index == 2 { sample.alignment = "misaligned" }
            if index == 3 { try Data("changed".utf8).write(to: URL(fileURLWithPath: sample.reference!)) }
            store.samples.append(sample)
        }
        store.curation.imported = store.samples
        store.trainingSelection = ["stale"]
        await store.selectAllForTraining()
        XCTAssertEqual(store.trainingSelection, ["bulk-0"])
        XCTAssertFalse(store.busy)
    }
    @MainActor
    func testStartTrainingSendsSelectionAndConsumesPersistedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [".venv/bin", "scripts"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        let executable = root.appendingPathComponent(".venv/bin/python")
        let script = #"""
        #!/bin/sh
        echo '{"event":"training","trainingRun":{"id":"job","name":"test","status":"running","step":0,"totalSteps":2,"epoch":0,"epochs":2,"sampleCount":1,"createdAt":"now","outputDirectory":"/tmp/job","message":"working"}}'
        echo '{"event":"completed","trainingRun":{"id":"job","name":"test","status":"completed","step":2,"totalSteps":2,"epoch":2,"epochs":2,"sampleCount":1,"createdAt":"now","outputDirectory":"/tmp/job","message":"done","modelPath":"/tmp/model"},"trainingRuns":[{"id":"job","name":"test","status":"completed","step":2,"totalSteps":2,"epoch":2,"epochs":2,"sampleCount":1,"createdAt":"now","outputDirectory":"/tmp/job","message":"done","modelPath":"/tmp/model"}]}'
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: root.appendingPathComponent("scripts/toolkit_bridge.py"))
        let store = AIWorkspaceStore(); store.enginePath = root.path; store.workspacePath = root.appendingPathComponent("footage").path
        store.catalog = AICatalog(schemaVersion: 1, model: AIModel(name: "base", revision: "test", available: true, inputSize: 2048, numericStatus: "passed", qualitySummary: "", testedSamples: 0), samples: [], runPath: "")
        store.samples = [.fixture]; store.curation.imported = store.samples
        store.trainingSelection = [AISample.fixture.id]; store.trainingEpochs = 2
        XCTAssertTrue(store.canStartTraining)
        store.startTraining()
        XCTAssertTrue(store.isTraining)
        await store.trainingOperation?.value
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.currentTraining?.status, "completed")
        XCTAssertEqual(store.trainedModels.count, 1)
        let requests = try FileManager.default.contentsOfDirectory(at: store.workspaceURL.appendingPathComponent("outputs/toolkit-ai/requests"), includingPropertiesForKeys: nil)
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(requests.first))) as? [String: Any]
        XCTAssertEqual(request?["sampleIDs"] as? [String], [AISample.fixture.id])
        XCTAssertEqual(request?["epochs"] as? Int, 2)
        XCTAssertEqual(request?["device"] as? String, "cpu")
    }
    func testTrainingProgressEventDecodesAndOnlyCompletedVersionsAreUsable() throws {
        let json = #"{"event":"training","trainingRun":{"id":"job","name":"test","status":"running","step":2,"totalSteps":6,"epoch":1,"epochs":3,"sampleCount":2,"createdAt":"now","outputDirectory":"/tmp/job","message":"training","loss":0.12}}"#
        let event = try JSONDecoder().decode(AIEvent.self, from: Data(json.utf8))
        var run = try XCTUnwrap(event.trainingRun)
        XCTAssertEqual(run.progress, 1.0 / 3, accuracy: 0.001)
        XCTAssertFalse(run.isUsable)
        run.status = "completed"; run.modelPath = "/tmp/decoder.safetensors"
        XCTAssertTrue(run.isUsable)
        run.status = "cancelled"
        XCTAssertFalse(run.isUsable)
    }

    func testNewPSDNeedsExplicitAnswerConfirmationEvenWhenAligned() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "psd/example", "name": "PSD", "original": "/tmp/original.png", "reference": "/tmp/answer.png",
            "width": 40, "height": 32, "color": "sRGB", "alignment": "aligned", "alignmentNote": "checked", "rois": [],
            "answerConfirmed": false
        ])
        let sample = try JSONDecoder().decode(AISample.self, from: data)
        let record = AISampleCuration(specimenGroup: "B1", groupConfirmed: true)
        XCTAssertFalse(record.canTrain(sample), "Automatic alignment must not approve the quality of an AI or manual answer")
    }
    func testOnlyAlignmentAndExplicitAnswerConfirmationAreRequired() {
        var sample = AISample.fixture
        let record = AISampleCuration()
        XCTAssertTrue(record.canTrain(sample))
        sample.answerConfirmed = false
        XCTAssertFalse(record.canTrain(sample))
        sample.answerConfirmed = nil
        XCTAssertFalse(record.canTrain(sample))
        sample.answerConfirmed = true
        sample.alignment = "misaligned"
        XCTAssertFalse(record.canTrain(sample))
        sample.alignment = "unverified"
        XCTAssertFalse(record.canTrain(sample))
        sample.alignment = "aligned"
        sample.reference = nil
        XCTAssertFalse(record.canTrain(sample))
    }

    @MainActor
    func testLegacyGroupAndUseDoNotRestrictTraining() {
        let store = AIWorkspaceStore()
        let sample = AISample.fixture
        store.samples = [sample]
        XCTAssertEqual(store.trainingCandidates.map(\.id), [sample.id])
        store.curation.samples[sample.id] = AISampleCuration(specimenGroup: "old", groupConfirmed: true)
        store.curation.groupUses["old"] = .excluded
        XCTAssertTrue(store.canTrain(sample))
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
                 alignmentNote: "已核对", rois: [], answerConfirmed: true)
    }
}

@MainActor
final class AIFileProtectionTests: XCTestCase {
    func testBatchConfirmationChecksEverySelectedAnswerAndPersistsValidOnes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIWorkspaceStore(); store.workspacePath = directory.path
        for index in 0..<6 {
            var sample = AISample.fixture
            sample.id = "sample-\(index)"; sample.name = sample.id; sample.answerConfirmed = index == 2
            sample.original = directory.appendingPathComponent("original-\(index).png").path
            sample.reference = directory.appendingPathComponent("answer-\(index).png").path
            for path in [sample.original, sample.reference!] { try Data("initial".utf8).write(to: URL(fileURLWithPath: path)) }
            sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
            if index == 4 { sample.alignment = "misaligned" }
            store.samples.append(sample)
        }
        store.curation.imported = store.samples
        try Data("changed".utf8).write(to: URL(fileURLWithPath: store.samples[3].reference!))
        store.setMaterialSelection(Set(store.samples.prefix(5).map(\.id)))
        await store.confirmSelectedAnswers()
        XCTAssertEqual(store.samples.map { $0.answerConfirmed }, [true, true, true, false, false, false])
        XCTAssertEqual(store.trainingCandidates.map(\.id), ["sample-0", "sample-1", "sample-2"])
        XCTAssertTrue(store.error?.contains("sample-3") == true)
        XCTAssertTrue(store.error?.contains("sample-4") == true)
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.materialSelection.count, 5)
        let saved = try AIFileValidation.readCuration(engine: directory, samples: [])
        XCTAssertEqual(saved.imported.map { $0.answerConfirmed }, [true, true, true, false, false, false])
    }

    func testBatchConfirmationDoesNotApproveWhenSavingFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sample = AISample.fixture; sample.answerConfirmed = false
        sample.original = directory.appendingPathComponent("original.png").path
        sample.reference = directory.appendingPathComponent("answer.png").path
        for path in [sample.original, sample.reference!] { try Data("initial".utf8).write(to: URL(fileURLWithPath: path)) }
        sample.sourceHashes = try AIFileValidation.sourceHashes(sample)
        let store = AIWorkspaceStore(); store.workspacePath = sample.original
        store.samples = [sample]; store.curation.imported = [sample]
        store.setMaterialSelection([sample.id])
        await store.confirmSelectedAnswers()
        XCTAssertEqual(store.samples[0].answerConfirmed, false)
        XCTAssertEqual(store.curation.imported[0].answerConfirmed, false)
        XCTAssertTrue(store.trainingCandidates.isEmpty)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.busy)
    }

    func testMaterialSelectionKeepsPreviewStableAndExcludesUnpairedImages() {
        let store = AIWorkspaceStore()
        var second = AISample.fixture; second.id = "back"
        var unpaired = AISample.fixture; unpaired.id = "original-only"; unpaired.reference = nil
        store.samples = [AISample.fixture, second, unpaired]
        store.selectedID = second.id
        store.setMaterialSelection(Set(store.samples.map(\.id)))
        XCTAssertEqual(store.materialSelection, ["front", "back"])
        XCTAssertEqual(store.selectedID, "back", "Selecting a range/all must keep the current preview")
        store.setMaterialSelection(["front"])
        XCTAssertEqual(store.selectedID, "front")
        store.setMaterialSelection([])
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.trainingSelection.isEmpty, "List selection must not select samples for training")
    }

    func testMaterialSelectionDropsMissingIDsInDisplayOrder() {
        let store = AIWorkspaceStore()
        var second = AISample.fixture; second.id = "back"
        store.samples = [AISample.fixture, second]
        store.setMaterialSelection(["front", "back", "deleted"])
        XCTAssertEqual(store.selectedID, "front")
        store.samples = [second]
        store.setMaterialSelection(store.materialSelection)
        XCTAssertEqual(store.materialSelection, ["back"])
        XCTAssertEqual(store.selectedID, "back")
    }

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
        case "$8" in *bad.jpg) echo '{"event":"error","message":"损坏图片"}'; exit 1;; esac
        echo '{"event":"imported","sample":\(encoded)}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data().write(to: directory.appendingPathComponent("scripts/toolkit_bridge.py"))
        let store = AIWorkspaceStore(); store.enginePath = directory.path; store.workspacePath = directory.path
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
    func testMaterialWorkspaceDoesNotFallBackToOldProjectLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = directory.appendingPathComponent("engine/outputs/toolkit-ai")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var library = AICuration(); library.imported = [.fixture]
        try JSONEncoder().encode(library).write(to: old.appendingPathComponent("workspace.json"))
        let loaded = try AIFileValidation.readCuration(engine: directory.appendingPathComponent("engine"), samples: [], workspace: directory.appendingPathComponent("materials"))
        XCTAssertTrue(loaded.imported.isEmpty)
    }

    func testMaterialWorkspaceFiltersOldExternalEntriesButKeepsItsOwn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let records = directory.appendingPathComponent("outputs/toolkit-ai")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var local = AISample.fixture; local.id = "local"
        local.original = directory.appendingPathComponent("original.png").path
        local.reference = directory.appendingPathComponent("answer.png").path
        local.prediction = "/outside/old-prediction.png"
        local.predictionAlpha = "/outside/old-alpha.png"
        for path in [local.original, local.reference!] { try Data("local".utf8).write(to: URL(fileURLWithPath: path)) }
        local.sourceHashes = try AIFileValidation.sourceHashes(local)
        var library = AICuration(); library.imported = [.fixture, local]
        library.samples["front"] = AISampleCuration(specimenGroup: "old", groupConfirmed: true)
        library.samples["local"] = AISampleCuration(specimenGroup: "new", groupConfirmed: true)
        try JSONEncoder().encode(library).write(to: records.appendingPathComponent("workspace.json"))
        let loaded = try AIFileValidation.readCuration(engine: directory.appendingPathComponent("engine"), samples: [], workspace: directory)
        XCTAssertEqual(loaded.imported.map(\.id), ["local"])
        XCTAssertNil(loaded.imported[0].prediction)
        XCTAssertNil(loaded.imported[0].predictionAlpha)
        XCTAssertNil(loaded.samples["front"])
        XCTAssertNotNil(loaded.samples["local"])
    }
    @MainActor
    func testSelectingTrainingSampleRechecksAnswerAndAlpha() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sample = AISample.fixture
        sample.original = directory.appendingPathComponent("original.png").path
        sample.reference = directory.appendingPathComponent("answer.png").path
        sample.alpha = directory.appendingPathComponent("alpha.png").path
        for path in [sample.original, sample.reference!, sample.alpha!] { try Data("initial".utf8).write(to: URL(fileURLWithPath: path)) }
        sample.sourceHashes = try AIFileValidation.sourceHashes(sample); sample.answerConfirmed = true
        let store = AIWorkspaceStore(); store.workspacePath = directory.path
        store.samples = [sample]; store.curation.imported = [sample]
        store.curation.samples[sample.id] = AISampleCuration(specimenGroup: "B1", groupConfirmed: true)
        store.curation.groupUses["B1"] = .training
        await store.selectForTraining(sample, enabled: true)
        XCTAssertTrue(store.trainingSelection.contains(sample.id))
        try Data("modified".utf8).write(to: URL(fileURLWithPath: sample.alpha!))
        await store.refreshTrainingEligibility()
        XCTAssertFalse(store.trainingSelection.contains(sample.id))
        XCTAssertFalse(store.canTrain(store.samples[0]))
        XCTAssertEqual(store.samples[0].answerConfirmed, false)
    }

    func testCorrectionReuseDependsOnOriginalAndPredictionContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sample = AISample.fixture
        sample.original = directory.appendingPathComponent("original.png").path
        sample.prediction = directory.appendingPathComponent("AI.png").path
        for path in [sample.original, sample.prediction!] { try Data("old".utf8).write(to: URL(fileURLWithPath: path)) }
        let oldKey = try AIFileValidation.correctionKey(sample)
        try Data("new".utf8).write(to: URL(fileURLWithPath: sample.prediction!))
        XCTAssertNotEqual(try AIFileValidation.correctionKey(sample), oldKey)
    }
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
