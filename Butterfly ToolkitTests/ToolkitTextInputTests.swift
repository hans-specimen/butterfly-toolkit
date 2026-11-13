// 验证名称清单与表格粘贴的边界，以及原始行号的错误提示。
import XCTest
@testable import Butterfly_Toolkit

final class ToolkitTextInputTests: XCTestCase {
    func testPhotoDraftAcceptsTabsAndSpreadsheetLineEnding() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        let batch = try draft.freeze(names: "腊美凤蝶\tPapilio lampsacus\r\n", output: f.batch.outputDirectory.appendingPathComponent("records"))
        XCTAssertEqual(batch.specimens.map(\.baseName), ["腊美凤蝶 Papilio lampsacus"])
    }

    func testPhotoDraftReportsFilenameCharacterBeforeReadingSources() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = (1...6).map { dir.appendingPathComponent("\($0).jpg") }
        let groups = [WorkflowDraftGroup(files: files.map(Optional.some)), WorkflowDraftGroup(files: files.map(Optional.some))]
        let draft = WorkflowBatchDraft(directory: dir, groups: groups, remainder: [], otherFiles: [])
        XCTAssertThrowsError(try draft.freeze(names: "正常\r\n坏/名字", output: dir.appendingPathComponent("records"))) {
            XCTAssertTrue($0.localizedDescription.contains("第 2 行"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("「/」"), $0.localizedDescription)
        }
    }

    func testStandaloneStackReportsOriginalLineAndKeepsNormalizedName() throws {
        let f = try ExecutorFixture()
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let output = f.batch.outputDirectory.appendingPathComponent("stacked")
        let plan = try FocusStackProcessor.makePlan(inputFolder: f.batch.sourceDirectory, outputFolder: output,
                                                   namesText: "\n腊美凤蝶\tPapilio lampsacus\r\n")
        XCTAssertEqual(plan.jobs.first?.destinationURL.lastPathComponent, "腊美凤蝶 Papilio lampsacus_D.psd")
        XCTAssertThrowsError(try FocusStackProcessor.makePlan(inputFolder: f.batch.sourceDirectory, outputFolder: output,
                                                             namesText: "正常\n\n坏\\名字")) {
            XCTAssertTrue($0.localizedDescription.contains("第 3 行"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("「\\」"), $0.localizedDescription)
        }
    }

    func testTableKeepsTabsAndReportsControlCharacterOnOriginalLine() throws {
        let rows = try CardCollectionInfo.parseBatch("74\tGhana\tForest / River\t2026.4\r\n\tGhana\tTown\t2026.5")
        XCTAssertEqual(rows.map(\.info.locality), ["Forest / River", "Town"])
        XCTAssertNil(rows[1].info.wingspan)
        XCTAssertThrowsError(try CardCollectionInfo.parseBatch("Ghana\tForest\t2026.4\n\nGhana\tBad\u{000B}Town\t2026.5")) {
            XCTAssertTrue($0.localizedDescription.contains("第 3 行"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("U+000B"), $0.localizedDescription)
        }
    }

    func testSingleLineInputReportsExtraRowsAndUsesFieldSpecificRules() {
        XCTAssertNil(ToolkitTextInput.singleLineError("Forest / River"))
        XCTAssertThrowsError(try ToolkitTextInput.filenameRows("A/\u{0301}B")) {
            XCTAssertTrue($0.localizedDescription.contains("「/」"), $0.localizedDescription)
        }
        XCTAssertEqual(ToolkitTextInput.singleLineError("Forest / River", filename: true),
                       "含有文件名不能使用的字符「/」。")
        XCTAssertEqual(ToolkitTextInput.singleLineError("正常\r\n多余"),
                       "第 2 行有多余内容，此处只接受一行。")
        XCTAssertTrue(ToolkitTextInput.singleLineError("正常\n\u{000B}")?.contains("第 2 行") == true)
        XCTAssertEqual(ToolkitTextInput.integer("\t500\r\n", in: 1...1000), 500)
        XCTAssertNil(ToolkitTextInput.integer("5\t00", in: 1...1000))
        XCTAssertNil(ToolkitTextInput.integer("500\n600", in: 1...1000))
    }

    func testWorkflowDoesNotSkipBlankOrDuplicateNames() throws {
        let f = try ExecutorFixture(count: 3)
        defer { try? FileManager.default.removeItem(at: f.batch.outputDirectory) }
        let draft = try WorkflowBatchDraft.scan(directory: f.batch.sourceDirectory)
        for names in ["第一只\n\n第三只", "第一只\t一号\n第一只 一号\n第三只"] {
            XCTAssertThrowsError(try draft.specimenNames(names)) {
                XCTAssertTrue($0.localizedDescription.contains("第 2 行"), $0.localizedDescription)
            }
        }
    }

    func testManifestErrorShowsUnderlyingReason() {
        XCTAssertEqual(WorkflowStateError.invalidManifest("工作 PSD 不属于当前批次目录").localizedDescription, "工作 PSD 不属于当前批次目录")
    }
}
