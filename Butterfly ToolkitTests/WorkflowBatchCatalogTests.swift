// 验证历史批次识别与删除边界，所有文件都在独立临时目录。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowBatchCatalogTests: XCTestCase {
    func testListsExistingBatchesByProgressBeforeRecencyAndUsesOnlyPrimaryManifests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var review = try fixture.batch("厄瓜多尔安蛱蝶")
        for side in WorkflowSide.allCases { try fixture.setGeometry(.waitingReview, for: side, in: &review) }
        let reviewURL = try fixture.write(review, time: 100)
        try Data(contentsOf: reviewURL).write(to: reviewURL.deletingLastPathComponent().appendingPathComponent("batch-recover.json"))

        var done = try fixture.batch("腊美凤蝶")
        done.selectedExportKinds = [.png4k]
        for side in WorkflowSide.allCases { try fixture.setGeometry(.completed, for: side, in: &done) }
        done.specimens[0].front[.hd].state = .completed
        done.specimens[0].front[.hd].outputVersion = "hd"
        done.specimens[0].back[.png4k].state = .completed
        done.specimens[0].back[.png4k].outputVersion = "png4k"
        done.specimens[0].back[.png4k].confirmedVersion = "png4k"
        try done.validate()
        let doneURL = try fixture.write(done, time: 200)

        let records = try await fixture.catalog.list()
        XCTAssertEqual(records.map(\.id), [reviewURL, doneURL])
        XCTAssertEqual(records.map(\.title), ["厄瓜多尔安蛱蝶", "腊美凤蝶"])
        XCTAssertEqual(records.map(\.progress), ["2 面待检查", "2 面已导出"])
        XCTAssertEqual(records.first?.specimenCount, 1)
        XCTAssertEqual(records.first?.sourceDirectory, review.sourceDirectory)
    }

    func testShowsUnreadableAndOldSchemaAndFindsValidPreviousManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let recoverable = try fixture.batch("可恢复批次")
        let recoverableURL = try fixture.write(recoverable, time: 100)
        try Data(contentsOf: recoverableURL).write(to: recoverableURL.appendingPathExtension("previous"))
        var invalid = recoverable
        invalid.specimens[0].baseName = "invalid/name"
        let invalidData = try JSONEncoder().encode(invalid)
        try invalidData.write(to: recoverableURL)
        var old = try fixture.batch("旧版批次")
        old.schemaVersion -= 1
        let oldURL = try fixture.write(old, time: 200)
        let corruptURL = try fixture.write(fixture.batch("损坏批次"), time: 300)
        try Data("broken".utf8).write(to: corruptURL)

        let records = try await fixture.catalog.list()
        XCTAssertEqual(records.first?.id, recoverableURL)
        XCTAssertEqual(records.first?.title, "可恢复批次")
        XCTAssertEqual(records.first?.canOpen, true)
        XCTAssertEqual(records.first { $0.id == oldURL }?.title, "旧版批次")
        XCTAssertEqual(records.first { $0.id == oldURL }?.canOpen, false)
        XCTAssertEqual(records.first { $0.id == corruptURL }?.canOpen, false)
        XCTAssertEqual(try Data(contentsOf: recoverableURL), invalidData)
    }

    func testDeleteRemovesCachesAndRecoveryCopiesButPreservesInputOutputAndOtherBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let batch = try fixture.batch("待删除批次")
        let manifest = try fixture.write(batch, time: 100)
        try Data(contentsOf: manifest).write(to: manifest.appendingPathExtension("previous"))
        try Data(contentsOf: manifest).write(to: batch.outputDirectory.appendingPathComponent("batch-recover.json"))
        let cache = batch.outputDirectory.appendingPathComponent(".work/role-cache/temporary.png")
        try fixture.makeFile(cache)
        let original = batch.activeTasks[0].sources.first.url
        let working = batch.generatedPSDDirectory.appendingPathComponent("sample0_D.psd")
        let exported = try XCTUnwrap(batch.exportDirectory(for: .png4k)).appendingPathComponent("sample0_D.png")
        for url in [working, exported] { try fixture.makeFile(url) }
        let other = try fixture.write(fixture.batch("另一批"), time: 200)
        let records = try await fixture.catalog.list()

        try await fixture.catalog.delete(try XCTUnwrap(records.first { $0.id == manifest }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.outputDirectory.path))
        for url in [original, working, exported, other] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        let remaining = try await fixture.catalog.list()
        XCTAssertEqual(remaining.map(\.id), [other])
    }

    func testDeleteRejectsOtherBatchExportPathAndWorkspaceLinks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = try fixture.batch("待删除批次")
        let manifest = try fixture.write(target, time: 100)
        let rows = try await fixture.catalog.list()
        let record = try XCTUnwrap(rows.first)
        var other = try fixture.batch("另一批")
        let aliased = URL(fileURLWithPath: target.outputDirectory.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        other.outputLocations = WorkflowOutputLocations(png4k: aliased.appendingPathComponent(".work/export"))
        let otherManifest = try fixture.write(other, time: 200)
        await assertDeleteFails(fixture, record)
        try FileManager.default.removeItem(at: otherManifest)

        let work = target.outputDirectory.appendingPathComponent(".work")
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: target.sourceDirectory)
        await assertDeleteFails(fixture, record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.activeTasks[0].sources.first.url.path))
    }

    func testDeletingLegacyBatchPreservesPSDStoredBesideInternalCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var old = try fixture.batch("旧版批次")
        old.schemaVersion -= 1
        let manifest = try fixture.write(old, time: 100)
        let psd = old.outputDirectory.appendingPathComponent("PSD/sample0_D.psd")
        let cache = old.outputDirectory.appendingPathComponent(".work/snapshot.psd")
        for file in [psd, cache] { try fixture.makeFile(file) }
        let records = try await fixture.catalog.list()
        XCTAssertEqual(records.first?.specimenCount, 1)
        try await fixture.catalog.delete(try XCTUnwrap(records.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(try Data(contentsOf: psd), Data("keep".utf8))
    }

    func testDeleteProtectsBatchOpenedInAnotherWindowThenClosesCurrentBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let batch = try fixture.batch("正在打开的批次")
        let manifest = try fixture.write(batch, time: 100)
        let records = try await fixture.catalog.list()
        let record = try XCTUnwrap(records.first)
        let first = PhotoWorkflowStore(batchCatalog: fixture.catalog)
        let second = PhotoWorkflowStore(batchCatalog: fixture.catalog)
        first.openBatch(manifest)
        let deadline = ContinuousClock.now + .seconds(4)
        while first.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.batch?.id, batch.id)
        do {
            try await second.deleteBatch(record)
            XCTFail("Deleted a batch open in another window")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        try await first.deleteBatch(record)
        XCTAssertNil(first.batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    private func assertDeleteFails(_ fixture: Fixture, _ record: WorkflowBatchCatalog.Record, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await fixture.catalog.delete(record)
            XCTFail("Deleted an unsafe directory", file: file, line: line)
        } catch {}
    }

    private struct Fixture {
        let home: URL
        let managed: URL
        let catalog: WorkflowBatchCatalog

        init() throws {
            home = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
            managed = home.appendingPathComponent("PhotoWorkflow", isDirectory: true)
            catalog = WorkflowBatchCatalog(storageRoot: managed)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        }

        func batch(_ name: String) throws -> WorkflowBatch {
            let input = home.appendingPathComponent(name, isDirectory: true)
            let sources = try (0..<6).map { index in
                let url = input.appendingPathComponent("\(index).jpg")
                try makeFile(url)
                return WorkflowSourceFile(url: url, fingerprint: "source-\(index)")
            }
            let specimen = WorkflowSpecimen(baseName: "sample0",
                front: WorkflowSideTask(side: .front, sources: .init(first: sources[0], second: sources[1], third: sources[2])),
                back: WorkflowSideTask(side: .back, sources: .init(first: sources[3], second: sources[4], third: sources[5])))
            let output = managed.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            return WorkflowBatch(sourceDirectory: input, sourceDirectoryName: name, outputDirectory: output, specimens: [specimen])
        }

        func setGeometry(_ status: WorkflowStatus, for side: WorkflowSide, in batch: inout WorkflowBatch) throws {
            let path = batch.generatedPSDDirectory.appendingPathComponent("sample0_\(side.fileSuffix).psd")
            let key: WritableKeyPath<WorkflowSpecimen, WorkflowSideTask> = side == .front ? \.front : \.back
            var task = batch.specimens[0][keyPath: key]
            let hash = String(repeating: "a", count: 64)
            var snapshot = ExecutorFixture.snapshot(task.id, path, hash, roles: true)
            snapshot.snapshotURL = batch.outputDirectory.appendingPathComponent(".work/snapshot.psd")
            task.snapshot = snapshot
            task[.geometry].state = status
            task[.geometry].outputVersion = hash
            if status == .completed {
                task[.geometry].confirmedVersion = hash
                let accepted = batch.acceptedFinalURL(taskID: task.id, contentVersion: hash)
                try makeFile(accepted)
                task.acceptedFinalPSD = WorkflowAcceptedFinalPSD(taskID: task.id, sourceRevision: task.sourceRevision,
                    workingURL: path, snapshotURL: accepted, contentVersion: hash)
            }
            batch.specimens[0][keyPath: key] = task
        }

        func write(_ batch: WorkflowBatch, time: TimeInterval) throws -> URL {
            let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
            try makeFile(manifest, data: JSONEncoder().encode(batch))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: manifest.path)
            return manifest
        }

        func makeFile(_ url: URL, data: Data = Data("keep".utf8)) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: home) }
    }
}
