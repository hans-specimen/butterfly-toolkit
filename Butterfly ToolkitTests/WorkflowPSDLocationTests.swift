// 验证工作 PSD 回到原图子目录，并保持导入、重处理和路径边界一致。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPSDLocationTests: XCTestCase {
    func testManualWorkflowCreatesPSDsInSourceSubdirectoryAndReopens() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        var batch = f.batch
        batch.outputDirectory = batch.sourceDirectory.appendingPathComponent("internal-records")
        let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
        let expected = batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd")
        let executor = WorkflowExecutor(services: f.services)
        try await executor.register(batch: batch,manifestURL: manifest)
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        for task in result.activeTasks {
            XCTAssertEqual(task[.geometry].state,.waitingReview)
            XCTAssertEqual(task.snapshot?.workingURL.deletingLastPathComponent().path,expected.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent("sample0_\(task.side.fileSuffix).psd").path))
        }
        let reopened = try await WorkflowBatchStore().load(from: manifest)
        XCTAssertEqual(reopened,result)
    }

    func testPSDPathsAllowKnownFilesAndOwnedSubdirectoriesOnly() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        var batch = f.batch
        // 内部记录必须与原图路径分开，避免内部目录授权掩盖边界检查。
        batch.outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
        let root = batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd")
        let retry = "重新处理-12345678-1234-1234-1234-123456789ABC"
        for relative in ["sample0_D.psd", "sample0_V.psd", "\(retry)/sample0_D.psd"] {
            XCTAssertNoThrow(try batch.validateOutputURL(root.appendingPathComponent(relative)),relative)
        }
        for relative in ["foreign_D.psd", "sample0_D.jpg", "other/sample0_D.psd",
                         "重新处理-not-a-uuid/sample0_D.psd", "批次-\(UUID())/sample0_D.psd",
                         "\(retry)/other/sample0_D.psd"] {
            XCTAssertThrowsError(try batch.validateOutputURL(root.appendingPathComponent(relative)),relative)
        }
        XCTAssertThrowsError(try batch.validateOutputURL(batch.sourceDirectory.appendingPathComponent("sample0_D.psd")))
        batch.psdBatchSubdirectory = true
        XCTAssertNoThrow(try batch.validateOutputURL(root.appendingPathComponent("批次-\(batch.id)/\(retry)/sample0_V.psd")))
        XCTAssertThrowsError(try batch.validateOutputURL(root.appendingPathComponent("sample0_D.psd")))
        batch.specimens[0].front.stackAttemptURL = batch.outputDirectory.appendingPathComponent("PSD/sample0_D.psd")
        XCTAssertThrowsError(try batch.validate(), "旧内部工作 PSD 不能作为当前格式载入")
    }

    func testPSDSubdirectoryCannotEscapeThroughSymlink() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID())")
        try FileManager.default.createDirectory(at: external,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        var batch = f.batch
        batch.outputDirectory = external.appendingPathComponent("records")
        let root = batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd")
        try FileManager.default.createSymbolicLink(at: root,withDestinationURL: external)
        XCTAssertThrowsError(try batch.validateOutputURL(root.appendingPathComponent("sample0_D.psd")))
    }

    func testImportedPSDWorkingCopyMayMoveButFrozenInputMustNot() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        var batch = f.batch
        batch.outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID())")
        let original = batch.sourceDirectory.appendingPathComponent("input_D.psd")
        let working = batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd/sample0_D.psd")
        batch.specimens[0].front.sources = WorkflowSources(first: WorkflowSourceFile(url: original,fingerprint: "input-hash"))
        batch.specimens[0].front.stackAttemptURL = working
        batch.specimens[0].front.snapshot = ExecutorFixture.snapshot(batch.specimens[0].front.id,working,"saved",roles: false)
        XCTAssertNoThrow(try batch.validate())
        let restored = try JSONDecoder().decode(WorkflowBatch.self,from: JSONEncoder().encode(batch))
        XCTAssertEqual(restored.specimens[0].front.sources.first.url,original)
        XCTAssertEqual(restored.specimens[0].front.snapshot?.workingURL,working)
        batch.specimens[0].front.snapshot?.workingURL = working.deletingLastPathComponent().appendingPathComponent("foreign_D.psd")
        XCTAssertThrowsError(try batch.validate())
    }

    func testPSDLinksCannotAliasOtherFilesOrAnotherBatchInsideSource() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        var batch = f.batch
        let root = batch.sourceDirectory.appendingPathComponent(batch.sourceDirectory.lastPathComponent + "_psd")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let other = batch.sourceDirectory.appendingPathComponent("user-file.psd")
        try Data("user data".utf8).write(to: other)
        let alias = root.appendingPathComponent("sample0_D.psd")
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: other)
        XCTAssertThrowsError(try batch.validateOutputURL(alias))
        let foreign = root.appendingPathComponent("批次-\(UUID())")
        try FileManager.default.createDirectory(at: foreign,withIntermediateDirectories: true)
        batch.psdBatchSubdirectory = true
        let own = root.appendingPathComponent("批次-\(batch.id)")
        try FileManager.default.createSymbolicLink(at: own,withDestinationURL: foreign)
        XCTAssertThrowsError(try batch.validateOutputURL(own.appendingPathComponent("sample0_D.psd")))
    }

    func testNewBatchIsolatesExistingNamesAndKeepsItsDirectoryAfterReload() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        let root = f.batch.sourceDirectory.appendingPathComponent(f.batch.sourceDirectory.lastPathComponent + "_psd")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("sample_D.psd.workflow-owner.json")
        try Data("previous owner".utf8).write(to: existing)
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "sample",output: f.batch.sourceDirectory.appendingPathComponent("records"))
        let expected = root.appendingPathComponent("批次-\(batch.id)",isDirectory: true)
        XCTAssertEqual(batch.generatedPSDDirectory,expected)
        let restored = try JSONDecoder().decode(WorkflowBatch.self,from: JSONEncoder().encode(batch))
        XCTAssertEqual(restored.generatedPSDDirectory,expected)
        XCTAssertNoThrow(try restored.validateOutputURL(expected.appendingPathComponent("sample_V.psd")))
        XCTAssertEqual(try Data(contentsOf: existing),Data("previous owner".utf8))
    }

    func testFrozenAliasCannotRedirectAnyDefaultOutputAfterRepointing() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let alias = f.batch.outputDirectory.appendingPathComponent("选中别名")
        let elsewhere = f.batch.outputDirectory.appendingPathComponent("另一个目录")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.batch.sourceDirectory)
        let draft = try WorkflowBatchDraft.scan(directory: alias)
        let batch = try draft.freeze(names: "sample", output: f.batch.outputDirectory.appendingPathComponent("records"))
        let frozenPSD = batch.generatedPSDDirectory
        let frozenHD = batch.exportDirectory(for: .hd)
        let frozenPNG = batch.exportDirectory(for: .png4k)
        XCTAssertEqual(batch.sourceDirectory, f.batch.sourceDirectory)
        XCTAssertEqual(frozenPSD.lastPathComponent, "选中别名_psd")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: elsewhere)
        let reopened = try JSONDecoder().decode(WorkflowBatch.self, from: JSONEncoder().encode(batch))
        XCTAssertEqual(reopened.generatedPSDDirectory, frozenPSD)
        XCTAssertEqual(reopened.exportDirectory(for: .hd), frozenHD)
        XCTAssertEqual(reopened.exportDirectory(for: .png4k), frozenPNG)
        XCTAssertNoThrow(try reopened.validate())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testInternalWorkCannotEscapeIntoExplicitExportDirectory() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        batch.outputDirectory = f.batch.outputDirectory.appendingPathComponent("internal")
        let export = f.batch.outputDirectory.appendingPathComponent("selected-export")
        try FileManager.default.createDirectory(at: batch.outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        batch.outputLocations = WorkflowOutputLocations(hd: export, png4k: export)
        XCTAssertNoThrow(try batch.validateArtifactURL(export.appendingPathComponent("sample0_D.png"), kind: .png4k))
        try FileManager.default.createSymbolicLink(at: batch.outputDirectory.appendingPathComponent(".work"), withDestinationURL: export)
        XCTAssertThrowsError(try batch.validateArtifactURL(export.appendingPathComponent("sample0_D.png"), kind: .png4k))
        XCTAssertThrowsError(try batch.validateOutputURL(batch.outputDirectory.appendingPathComponent(".work/snapshot.psd")))
        XCTAssertThrowsError(try batch.validate())
    }

    func testImportedSourceCannotBeItsOwnWorkingPSD() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        var batch = f.batch
        let working = batch.generatedPSDDirectory.appendingPathComponent("sample0_D.psd")
        batch.specimens[0].front.sources = WorkflowSources(first: WorkflowSourceFile(url: working, fingerprint: "source"))
        batch.specimens[0].front.stackAttemptURL = working
        XCTAssertThrowsError(try batch.validate())
        batch.specimens[0].front.stackAttemptURL = nil
        batch.specimens[0].front.snapshot = ExecutorFixture.snapshot(batch.specimens[0].front.id, working, "source", roles: false)
        XCTAssertThrowsError(try batch.validate())
    }

    func testImportedPSDFromSourceAliasKeepsCanonicalWorkingIdentity() async throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.sourceDirectory) }
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("input-alias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: f.batch.sourceDirectory)
        defer { try? FileManager.default.removeItem(at: alias) }
        var batch = f.batch; batch.sourceDirectoryName = alias.lastPathComponent
        batch.outputDirectory = f.batch.sourceDirectory.appendingPathComponent("records")
        for side in WorkflowSide.allCases {
            var task = side == .front ? batch.specimens[0].front : batch.specimens[0].back
            let source = f.batch.sourceDirectory.appendingPathComponent("input_\(side.fileSuffix).psd")
            try Data("input".utf8).write(to: source)
            task.sources = WorkflowSources(first: WorkflowSourceFile(url: source,fingerprint: try AIFileValidation.hash(source.path)))
            if side == .front { batch.specimens[0].front = task } else { batch.specimens[0].back = task }
        }
        var services = f.services
        services.adoptStack = { source, id in
            ExecutorFixture.snapshot(id,source.url.resolvingSymlinksInPath(),"input",roles: false)
        }
        let executor = WorkflowExecutor(services: services)
        try await executor.register(batch: batch,manifestURL: batch.outputDirectory.appendingPathComponent("batch.json"))
        try await executor.runPending(batchID: batch.id)
        let result = try await executor.batch(batchID: batch.id)
        for task in result.activeTasks {
            XCTAssertEqual(task[.geometry].state,.waitingReview)
            XCTAssertEqual(task.stackAttemptURL,task.snapshot?.workingURL)
        }
    }
}
