// 验证标本多选、按可见列表全选和逐面操作之间的对应关系。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowQueueSelectionTests: XCTestCase {
    func testClickModifiersKeepTheFirstSelectedSpecimenInPreview() throws {
        let fixture = try ExecutorFixture(count: 5)
        defer { try? FileManager.default.removeItem(at: fixture.batch.outputDirectory) }
        let store = PhotoWorkflowStore()
        store.batch = fixture.batch
        let ids = fixture.batch.specimens.map(\.id)

        XCTAssertFalse(store.hasExplicitQueueSelection)
        store.selectSpecimen(ids[0])
        XCTAssertTrue(store.hasExplicitQueueSelection)
        store.selectSpecimen(ids[1], modifiers: .command)
        store.selectSpecimen(ids[4], modifiers: .command)
        XCTAssertEqual(store.selectedSpecimens, [ids[0], ids[1], ids[4]])
        XCTAssertEqual(store.currentSpecimenID, ids[0])

        store.selectSpecimen(ids[1])
        store.selectSpecimen(ids[0], modifiers: .command)
        XCTAssertEqual(store.currentSpecimenID, ids[1])
        store.setFaceSelected(fixture.batch.specimens[1].front.id, selected: false)
        store.selectSpecimen(ids[3], modifiers: .shift)
        XCTAssertEqual(store.selectedSpecimens, Set(ids[1...3]))
        XCTAssertFalse(store.selectedTaskIDs.contains(fixture.batch.specimens[1].front.id))
        XCTAssertTrue(store.selectedTaskIDs.contains(fixture.batch.specimens[2].front.id))
        XCTAssertEqual(store.currentSpecimenID, ids[1])
        store.selectSpecimen(ids[1], modifiers: .command)
        XCTAssertEqual(store.currentSpecimenID, ids[2])
    }

    func testAllSelectsOnlyVisibleEligibleSpecimensAndTheirFaces() throws {
        let fixture = try ExecutorFixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.batch.outputDirectory) }
        var batch = fixture.batch
        batch.specimens[0].front[.stack].state = .failed
        batch.specimens[1].back[.matte].state = .failed
        batch.specimens[3].front[.stack].state = .failed
        batch.specimens[3].exclusionReason = "已排除"
        let store = PhotoWorkflowStore()
        store.batch = batch
        let specimens = batch.specimens

        store.selectSpecimen(specimens[2].id)
        store.queueFilter = "失败"
        store.selectAllVisibleSpecimens()
        XCTAssertEqual(store.selectedSpecimens, [specimens[0].id, specimens[1].id])
        XCTAssertEqual(store.selectedTaskIDs, Set(specimens.prefix(2).flatMap { [$0.front.id, $0.back.id] }))
        XCTAssertEqual(store.currentSpecimenID, specimens[0].id)
        XCTAssertTrue(store.allVisibleSpecimensSelected)

        store.setFaceSelected(specimens[0].front.id, selected: false)
        XCTAssertFalse(store.allVisibleSpecimensSelected)
        store.selectSpecimen(specimens[1].id, modifiers: .command)
        XCTAssertEqual(store.selectedTaskIDs, [specimens[0].back.id])
        store.selectAllVisibleSpecimens()
        XCTAssertTrue(store.selectedTaskIDs.contains(specimens[0].front.id))
    }

    func testDraftBulkExclusionPreservesSlotsAndNames() throws {
        let fixture = try ExecutorFixture(count: 3)
        defer { try? FileManager.default.removeItem(at: fixture.batch.outputDirectory) }
        let store = PhotoWorkflowStore()
        store.scan(fixture.batch.sourceDirectory)
        store.names = "一\n二\n三"
        let groups = try XCTUnwrap(store.draft?.groups)
        store.selectDraftSpecimen(groups[2].id, modifiers: .command)
        XCTAssertEqual(store.draftSelectedIDs, [groups[0].id, groups[2].id])
        store.setDraftExclusion(true, for: Set(store.draftSelectedIDs))
        XCTAssertEqual(store.draft?.groups.map(\.excluded), [true, false, true])
        XCTAssertEqual(store.draft?.groups.map(\.files), groups.map(\.files))
        XCTAssertEqual(store.names, "一\n二\n三")
        store.selectAllDraftSpecimens()
        XCTAssertEqual(store.draftSelectedIDs.first, groups[0].id)
        store.setDraftExclusion(false, for: Set(store.draftSelectedIDs))
        XCTAssertEqual(store.draft?.groups.map(\.excluded), [false, false, false])
    }
}
