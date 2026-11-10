// 验证诊断与保存版本绑定，以及历史记录兼容；不调用 Photoshop。
import XCTest
@testable import Butterfly_Toolkit

final class WorkflowCleanupReportTests: XCTestCase {
    func testOldRecordWithoutCleanupReportLoads() throws {
        let json = """
        {"taskID":"00000000-0000-0000-0000-000000000001","workingURL":"file:///tmp/a.psd","snapshotURL":"file:///tmp/b.psd","contentVersion":"old","pixelSize":[100,100],"structureSummary":"old"}
        """
        let snapshot = try JSONDecoder().decode(PSDSnapshot.self,from: Data(json.utf8))
        XCTAssertNil(snapshot.cleanupReportURL)
        XCTAssertNil(try snapshot.validatedCleanupReport())
        let matte = """
        {"inputPNGFingerprint":"i","alphaURL":"file:///tmp/a.png","alphaFingerprint":"a","cutoutURL":"file:///tmp/c.png","cutoutFingerprint":"c","orientation":1,"pixelSize":[100,100]}
        """
        XCTAssertNil(try JSONDecoder().decode(MatteArtifact.self,from: Data(matte.utf8)).cleanupAlgorithmVersion)
    }
    func testChangedSaveAndChangedReportCannotReuseDiagnostics() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.0) }
        var snapshot = PSDSnapshot(taskID: UUID(),workingURL: f.0,snapshotURL: f.0,contentVersion: "auto-save",pixelSize: CGSize(width: 100,height: 100),structureSummary: "auto")
        snapshot = snapshot.attachingCleanup(from: f.1)
        XCTAssertEqual(try snapshot.validatedCleanupReport()?.removedPixelCount,10)
        snapshot.contentVersion = "manual-save"
        XCTAssertNil(try snapshot.validatedCleanupReport())
        snapshot.contentVersion = "auto-save"
        try Data("changed".utf8).write(to: XCTUnwrap(f.1.cleanupReportURL))
        XCTAssertThrowsError(try snapshot.validatedCleanupReport())
    }
    func testReportRegionFollowsAutomaticCropAndRotation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.0) }
        let old = PSDSnapshot(taskID: UUID(),workingURL: f.0,snapshotURL: f.0,contentVersion: "before",pixelSize: CGSize(width: 100,height: 100),structureSummary: "auto").attachingCleanup(from: f.1)
        let solution = GeometrySolution(sourceVersion: "before",angleDegrees: 90,rotationPivot: CGPoint(x: 50,y: 50),subjectBounds: CGRect(x: 20,y: 20,width: 60,height: 60),sourceCropRect: CGRect(x: 10,y: 10,width: 80,height: 80),outputSize: CGSize(width: 80,height: 80),actualMargins: WorkflowMargins(left: 0.1,top: 0.1,right: 0.1,bottom: 0.1),isApplicable: true)
        var saved = old; saved.contentVersion = "after"
        saved = saved.carryingCleanup(from: old,geometry: solution)
        XCTAssertNotNil(try saved.validatedCleanupReport())
        let region = CGRect(x: 10,y: 20,width: 5,height: 10)
        let displayed = saved.cleanupDisplayBounds(region)
        XCTAssertEqual(displayed.minX,60,accuracy: 1e-8); XCTAssertEqual(displayed.minY,0,accuracy: 1e-8)
        XCTAssertEqual(displayed.width,10,accuracy: 1e-8); XCTAssertEqual(displayed.height,5,accuracy: 1e-8)
    }
    func testResultStatesDistinguishWarningsFromFailure() {
        let fit = GeometrySolution(sourceVersion: "s",angleDegrees: 0,rotationPivot: .zero,subjectBounds: CGRect(x: 10,y: 10,width: 80,height: 80),sourceCropRect: CGRect(x: 0,y: 0,width: 100,height: 100),outputSize: CGSize(width: 100,height: 100),actualMargins: WorkflowMargins(left: 0.1,top: 0.1,right: 0.1,bottom: 0.1),isApplicable: true)
        XCTAssertEqual(WorkflowCleanupStatus.title(solution: fit,report: nil,targetMargin: 0.1),"已裁切")
        var reduced = fit; reduced.actualMargins.left = 0.05
        XCTAssertEqual(WorkflowCleanupStatus.title(solution: reduced,report: nil,targetMargin: 0.1),"已裁切 · 留白不足")
        let uncertain = MaskCleanupReport(algorithmVersion: 1,removedPixelCount: 0,regions: [MaskCleanupRegion(bounds: .zero,pixelCount: 1,decision: .uncertain,reason: .ambiguousConnection)])
        XCTAssertEqual(WorkflowCleanupStatus.title(solution: fit,report: uncertain,targetMargin: 0.1),"已裁切 · 残留待检查")
        var invalid = fit; invalid.isApplicable = false
        XCTAssertEqual(WorkflowCleanupStatus.title(solution: invalid,report: uncertain,targetMargin: 0.1),"自动裁切未应用")
    }
    private func fixture() throws -> (URL,MatteArtifact) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-report-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let url = root.appendingPathComponent("report.json")
        let report = MaskCleanupReport(algorithmVersion: MaskResidueCleanup.algorithmVersion,removedPixelCount: 10,regions: [],pixelSize: CGSize(width: 100,height: 100))
        try JSONEncoder().encode(report).write(to: url)
        return (root,MatteArtifact(inputPNGFingerprint: "i",alphaURL: root,alphaFingerprint: "a",cutoutURL: root,cutoutFingerprint: "c",orientation: 1,pixelSize: report.pixelSize,cleanupReportURL: url,cleanupReportFingerprint: try AIFileValidation.hash(url.path),cleanupAlgorithmVersion: report.algorithmVersion))
    }
}
