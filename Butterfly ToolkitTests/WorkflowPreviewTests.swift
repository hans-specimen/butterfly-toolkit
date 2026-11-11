import XCTest
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPreviewTests: XCTestCase {
    func testPreviewChoicesAreIndependentForEveryStage() {
        let store = PhotoWorkflowStore()
        store.previewMode = "蒙版"; store.previewBackground = "黑"
        store.stage = .matte
        XCTAssertEqual(store.previewMode,"抠图")
        XCTAssertEqual(store.previewBackground,"天蓝")
        store.previewMode = "蒙版"; store.previewBackground = "白"
        store.stage = .geometry
        XCTAssertEqual(store.previewMode,"底图")
        XCTAssertEqual(store.previewBackground,"棋盘")
        store.previewMode = "抠图"; store.previewBackground = "黑"
        store.stage = .hd
        store.previewMode = "蒙版"; store.previewBackground = "天蓝"
        store.stage = .png4k
        store.previewBackground = "白"
        store.stage = .stack
        XCTAssertEqual(store.previewMode,"蒙版"); XCTAssertEqual(store.previewBackground,"黑")
        store.stage = .matte
        XCTAssertEqual(store.previewMode,"蒙版"); XCTAssertEqual(store.previewBackground,"白")
        store.stage = .geometry
        XCTAssertEqual(store.previewMode,"抠图"); XCTAssertEqual(store.previewBackground,"黑")
        store.stage = .hd
        XCTAssertEqual(store.previewMode,"蒙版"); XCTAssertEqual(store.previewBackground,"天蓝")
        store.stage = .png4k
        XCTAssertEqual(store.previewBackground,"白")
    }

    func testOldPreviewCannotReplaceLatestRequest() {
        var gate = WorkflowPreviewGate()
        let old = gate.begin(sourceVersion: "old")
        let latest = gate.begin(sourceVersion: "latest")
        XCTAssertFalse(gate.accept(token: old, sourceVersion: "old", valid: true))
        XCTAssertFalse(gate.canConfirm)
        XCTAssertTrue(gate.accept(token: latest, sourceVersion: "latest", valid: true))
        XCTAssertTrue(gate.canConfirm)
    }
    func testConfirmationDisabledWhileValidating() {
        var gate = WorkflowPreviewGate()
        let first = gate.begin(sourceVersion: "v1")
        XCTAssertTrue(gate.accept(token: first, sourceVersion: "v1", valid: true))
        _ = gate.begin(sourceVersion: "v1")
        XCTAssertFalse(gate.canConfirm)
        XCTAssertFalse(gate.accept(token: first, sourceVersion: "v1", valid: true))
    }
    func testViewportZoomDoesNotChangeOutput() {
        let viewport = WorkflowPreviewCoordinates(sourceRect: CGRect(x: -300,y: -200,width: 4000,height: 3000),viewSize: CGSize(width: 800,height: 600),zoom: 1)
        var zoomed = viewport; zoomed.zoom = 3
        XCTAssertEqual(viewport.sourceRect,zoomed.sourceRect)
        XCTAssertNotEqual(viewport.viewPoint(CGPoint(x: 100,y: 200)),zoomed.viewPoint(CGPoint(x: 100,y: 200)))
    }
    func testCoordinateRoundTripWithOriginZoomAndRotation() {
        let map = WorkflowPreviewCoordinates(sourceRect: CGRect(x: -300,y: 250,width: 4800,height: 3200),viewSize: CGSize(width: 900,height: 600),zoom: 2.3)
        for point in [CGPoint(x: -100,y: 290),CGPoint(x: 3000,y: 1900)] {
            let rotated = WorkflowPreviewCoordinates.rotate(point,degrees: -12.7,pivot: CGPoint(x: 1800,y: 1600))
            let restored = WorkflowPreviewCoordinates.rotate(map.sourcePoint(map.viewPoint(rotated)),degrees: 12.7,pivot: CGPoint(x: 1800,y: 1600))
            XCTAssertEqual(restored.x,point.x,accuracy: 1e-8); XCTAssertEqual(restored.y,point.y,accuracy: 1e-8)
        }
    }
    func testFrozenGroupingAndContentHashesDoNotShiftAfterExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 1...12 { try Data("source-\(i)".utf8).write(to: root.appendingPathComponent("DSC\(i).JPG")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        XCTAssertEqual(draft.groups[1].files[0]?.lastPathComponent,"DSC7.JPG")
        let secondID = draft.groups[1].id
        draft.groups[0].excluded = true
        let batch = try draft.freeze(names: "first\nsecond",output: root.appendingPathComponent("output"))
        XCTAssertEqual(batch.specimens[1].id,secondID)
        XCTAssertEqual(batch.specimens[1].baseName,"second")
        XCTAssertEqual(batch.specimens[1].front.sources.first.fingerprint,try AIFileValidation.hash(root.appendingPathComponent("DSC7.JPG").path))
        XCTAssertTrue(batch.specimens[0].isExcluded)
    }
    func testGroupingRejectsMissingDuplicateNamesAndForeignOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 1...12 { try Data("source".utf8).write(to: root.appendingPathComponent("\(i).jpg")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        XCTAssertThrowsError(try draft.freeze(names: "same\nsame",output: root.appendingPathComponent("output")))
        draft.groups[0].files[0] = nil
        XCTAssertThrowsError(try draft.freeze(names: "first\nsecond",output: root.appendingPathComponent("output")))
    }
    func testCanvasCoordinatesUseFullNegativeOriginAndCurrentCrop() {
        let url = URL(fileURLWithPath: "/tmp/role.png")
        let roles = RoleImages(snapshotVersion: "v1",basePNG: url,cutoutPNG: url,maskPNG: url,pixelSize: CGSize(width: 100,height: 100),coordinateOrigin: CGPoint(x: -20,y: -30),editableExtent: CGRect(x: -20,y: -30,width: 100,height: 100),cropViewport: CGRect(x: 0,y: 0,width: 35,height: 21))
        var solution = GeometrySolution(sourceVersion: "v1",angleDegrees: 0,rotationPivot: CGPoint(x: 30,y: 20),subjectBounds: CGRect(x: 5,y: 5,width: 20,height: 10),sourceCropRect: roles.cropViewport,outputSize: roles.cropViewport.size,actualMargins: WorkflowMargins(left: 0,top: 0,right: 0,bottom: 0),isApplicable: true)
        var canvas = WorkflowGeometryPreview(image: nil,source: roles,solution: solution,zoom: 1,background: "棋盘")
        XCTAssertEqual(canvas.displayRect,CGRect(x: -100,y: -110,width: 260,height: 260))
        var map = WorkflowPreviewCoordinates(sourceRect: canvas.displayRect,viewSize: CGSize(width: 260,height: 260))
        XCTAssertEqual(map.viewRect(CGRect(origin: roles.coordinateOrigin,size: roles.pixelSize)),CGRect(x: 80,y: 80,width: 100,height: 100))
        XCTAssertEqual(map.viewRect(solution.sourceCropRect),CGRect(x: 100,y: 110,width: 35,height: 21))
        solution.sourceCropRect = CGRect(x: -40,y: -50,width: 35,height: 21)
        canvas.solution = solution
        XCTAssertEqual(canvas.displayRect,CGRect(x: -120,y: -130,width: 280,height: 280),"Canvas must include the current crop outside the saved viewport")
        map = WorkflowPreviewCoordinates(sourceRect: canvas.displayRect,viewSize: CGSize(width: 280,height: 280))
        XCTAssertEqual(map.viewRect(solution.sourceCropRect),CGRect(x: 80,y: 80,width: 35,height: 21))
        XCTAssertEqual(map.viewRect(CGRect(origin: roles.coordinateOrigin,size: roles.pixelSize)),CGRect(x: 100,y: 100,width: 100,height: 100))
    }
    func testManualInspectionPreviewUsesSavedCanvasInsteadOfHiddenLayerExtent() {
        let url = URL(fileURLWithPath: "/tmp/role.png")
        let roles = RoleImages(snapshotVersion: "saved",basePNG: url,cutoutPNG: url,maskPNG: url,pixelSize: CGSize(width: 500,height: 400),coordinateOrigin: CGPoint(x: -100,y: -80),editableExtent: CGRect(x: -100,y: -80,width: 500,height: 400),cropViewport: CGRect(x: 0,y: 0,width: 200,height: 180))
        let preview = WorkflowGeometryPreview(image: nil,source: roles,solution: nil,zoom: 1,background: "棋盘",savedCanvasOnly: true)
        XCTAssertEqual(preview.displayRect,CGRect(x: -80,y: -80,width: 360,height: 340))
    }
    func testSavedGeometryPreviewUsesSavedCanvasWithoutReestimating() {
        let file = WorkflowSourceFile(url: URL(fileURLWithPath: "/tmp/input.jpg"),fingerprint: "hash")
        let sources = WorkflowSources(first: file,second: file,third: file)
        var task = WorkflowSideTask(side: .front,sources: sources)
        task[.geometry].state = .completed
        task.geometryRequest.angleStrategy = .manual(degrees: -14)
        task.geometrySolution = GeometrySolution(sourceVersion: "saved",angleDegrees: 0,rotationPivot: .zero,subjectBounds: CGRect(x: 0,y: 0,width: 20,height: 10),sourceCropRect: CGRect(x: 0,y: 0,width: 30,height: 20),outputSize: CGSize(width: 30,height: 20),actualMargins: WorkflowMargins(left: 0,top: 0,right: 0,bottom: 0),isApplicable: true)
        let specimen = WorkflowSpecimen(baseName: "name",front: task,back: WorkflowSideTask(side: .back,sources: sources))
        let store = PhotoWorkflowStore(); store.batch = WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/private/tmp"),sourceDirectoryName: "tmp",outputDirectory: URL(fileURLWithPath: "/tmp/output"),specimens: [specimen]); store.currentSpecimenID = specimen.id
        XCTAssertEqual(store.currentPreviewSolution?.angleDegrees,0)
        XCTAssertFalse(previewReady(store))
    }

    func testManualRepairCannotConfirmBeforeRefreshingSavedPSD() {
        let url = URL(fileURLWithPath: "/tmp/missing-old-source.png")
        let file = WorkflowSourceFile(url: url,fingerprint: "old")
        let sources = WorkflowSources(first: file,second: file,third: file)
        var front = WorkflowSideTask(side: .front,sources: sources)
        front.snapshot = PSDSnapshot(taskID: front.id,workingURL: url,snapshotURL: url,contentVersion: "old",pixelSize: CGSize(width: 100,height: 100),structureSummary: "old")
        front.roleImages = RoleImages(snapshotVersion: "old",basePNG: url,cutoutPNG: url,maskPNG: url,pixelSize: CGSize(width: 100,height: 100),coordinateOrigin: .zero,editableExtent: CGRect(x: 0,y: 0,width: 100,height: 100),cropViewport: CGRect(x: 0,y: 0,width: 100,height: 100))
        let specimen = WorkflowSpecimen(baseName: "name",front: front,back: WorkflowSideTask(side: .back,sources: sources))
        let store = PhotoWorkflowStore(); store.batch = WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/private/tmp"),sourceDirectoryName: "tmp",outputDirectory: URL(fileURLWithPath: "/tmp/output"),specimens: [specimen]); store.currentSpecimenID = specimen.id; store.selectedSpecimens = [specimen.id]; store.manualTaskID = front.id
        XCTAssertFalse(store.canFinalize)
        XCTAssertTrue(store.images.isEmpty); XCTAssertFalse(previewReady(store))
    }

}

@MainActor extension WorkflowPreviewTests {
    private actor PreviewProbe: WorkflowPreviewServing {
        let service = WorkflowPreviewService()
        var calls: [String] = []
        var holdFirstGeometry = false
        var staleGeometry = false
        var held: CheckedContinuation<Void,Never>?
        var entered: XCTestExpectation?
        func hold(_ expectation: XCTestExpectation) { holdFirstGeometry = true; entered = expectation }
        func returnStaleGeometry() { staleGeometry = true }
        func release() { held?.resume(); held = nil }
        func values() -> [String] { calls }
        func image(url: URL,version: String,maximumPixelSize: Int) async throws -> CGImage {
            calls.append("image")
            return try await service.image(url: url,version: version,maximumPixelSize: maximumPixelSize)
        }
        func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution?) async throws -> GeometrySolution {
            calls.append("geometry")
            var solution = try await service.geometry(source: source,request: request,savedCandidate: savedCandidate)
            if staleGeometry { solution.sourceVersion = "stale-result" }
            if holdFirstGeometry {
                holdFirstGeometry = false
                await withCheckedContinuation { held = $0; entered?.fulfill() }
            }
            return solution
        }

    }
    func testCurrentFaceCanBeConfirmedBeforePreviewEvenWhenOtherFaceFailed() async throws {
        var batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        batch.specimens[0].front[.geometry].state = .waitingReview
        batch.specimens[0].front[.geometry].confirmedVersion = nil
        batch.specimens[0].back[.geometry].state = .failed
        batch.specimens[0].back[.geometry].confirmedVersion = nil
        let store = PhotoWorkflowStore()
        store.batch = batch; store.currentSpecimenID = batch.specimens[0].id
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(store.canFinalize)
        XCTAssertEqual(store.stage,.hd)
        store.face = .back
        XCTAssertFalse(store.canFinalize)
        XCTAssertEqual(store.stage,.geometry)
    }
    func testOpeningExportDoesNotDecodeSelectedFaces() async throws {
        var batch = try imageFixture(specimens: 2)
        defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(), store = PhotoWorkflowStore(previews: probe)
        store.batch = batch
        store.currentSpecimenID = batch.specimens[0].id
        store.selectedSpecimens = Set(batch.specimens.map(\.id))
        store.stage = .png4k
        store.prepareSelected()
        store.refreshVisibleImage()
        for preview in Array(store.previewTasks.values) { await preview.value }
        let calls = await probe.values()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(store.images.isEmpty)
    }

    func testExportDecodesOnlyFacesRequestedByTheUser() async throws {
        var batch = try imageFixture(specimens: 2)
        defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(), store = PhotoWorkflowStore(previews: probe)
        let front = batch.specimens[0].front, back = batch.specimens[0].back
        store.batch = batch
        store.currentSpecimenID = batch.specimens[0].id
        store.selectedSpecimens = Set(batch.specimens.map(\.id))
        store.stage = .png4k
        store.loadCurrentExportPreview()
        await store.previewTasks[front.id]?.value
        let image = try XCTUnwrap(store.displayImage(for: front))
        let gate = store.gates[front.id]?.token
        let solution = store.solutions[front.id]
        var layout = store.currentLayout; layout.safeMargin = 300
        store.editLayout(layout)
        XCTAssertNil(store.displayImage(for: back))

        store.face = .back
        store.refreshVisibleImage()
        XCTAssertNil(store.previewTasks[back.id])
        store.loadCurrentExportPreview()
        await store.previewTasks[back.id]?.value
        XCTAssertEqual(Set(store.images.keys), [front.id, back.id])
        XCTAssertTrue(store.displayImage(for: front) === image)
        XCTAssertEqual(store.gates[front.id]?.token, gate)
        XCTAssertEqual(store.solutions[front.id], solution)
        XCTAssertEqual(store.layouts[front.id], layout)
        let calls = await probe.values()
        XCTAssertEqual(calls.filter { $0 == "image" }.count, 2)
    }

    func testSwitchingBetweenConfirmedAndEditingFacesKeepsReviewOpen() throws {
        var batch = try imageFixture(specimens: 1)
        defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        batch.specimens[0].back[.geometry].state = .waitingReview
        batch.specimens[0].back[.geometry].confirmedVersion = nil
        let store = PhotoWorkflowStore()
        store.batch = batch
        store.currentSpecimenID = batch.specimens[0].id
        store.stage = .hd
        store.face = .back
        XCTAssertEqual(store.stage, .hd)
        store.face = .front
        XCTAssertEqual(store.stage, .hd)
    }

    func testFailedMatteWithWorkingPSDCanStillOpenForManualRepair() throws {
        var batch = try imageFixture(specimens: 1)
        defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        batch.specimens[0].front[.matte].state = .failed
        batch.specimens[0].front[.geometry].state = .pending
        let store = PhotoWorkflowStore()
        store.batch = batch
        store.currentSpecimenID = batch.specimens[0].id
        store.stage = .hd
        XCTAssertTrue(store.canOpenPSD)
        XCTAssertFalse(store.canFinalize)
        store.selectedTaskIDs = [batch.specimens[0].front.id]
        XCTAssertTrue(store.selectedReviewTaskIDs.isEmpty)
    }

    func testStorePreviewUsesRoleThumbnailAndValidationWithoutDiscardedBitmap() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
        store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .geometry
        store.prepareSelected()
        try await waitUntil { batch.sideTasks.allSatisfy { store.gates[$0.id]?.canConfirm == true && !store.loading.contains($0.id) } }
        let calls = await probe.values()
        XCTAssertEqual(calls.filter { $0 == "image" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "geometry" }.count,2)
        XCTAssertEqual(calls.filter { $0 == "discarded-bitmap" }.count,0)
        for task in batch.sideTasks {
            let expected = try await probe.service.image(url: task.roleImages!.basePNG,version: task.snapshot!.contentVersion,maximumPixelSize: 2048)
            XCTAssertTrue(store.displayImage(for: task) === expected)
            XCTAssertEqual(store.displayImage(for: task)?.width,100,"Canvas receives the full role thumbnail, not a cropped bitmap")
            XCTAssertEqual(store.solutions[task.id]?.sourceVersion,task.snapshot?.contentVersion)
        }
        XCTAssertTrue(store.loading.isEmpty)
    }
    func testDelayedGeometryCannotReplaceNewSavedVersionOrEnableConfirmationEarly() async throws {
        var batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
        let entered = expectation(description: "Old geometry result held"),finished = expectation(description: "Store consumed the old completion")
        await probe.hold(entered)
        store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .geometry
        store.refreshVisibleImage()
        let id = batch.specimens[0].front.id
        let oldTask = try XCTUnwrap(store.previewTasks[id])
        await fulfillment(of: [entered],timeout: 2)
        XCTAssertNotNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertTrue(store.loading.contains(id)); XCTAssertFalse(previewReady(store))
        batch.specimens[0].front.snapshot?.contentVersion = "new-saved-version"
        batch.specimens[0].front.roleImages?.snapshotVersion = "new-saved-version"
        batch.specimens[0].front.geometrySolution?.sourceVersion = "new-saved-version"
        store.batch = batch; store.prepareSelected()
        try await waitUntil { previewReady(store) }
        let latest = store.solutions[id]
        await probe.release()
        Task { await oldTask.value; finished.fulfill() }
        await fulfillment(of: [finished],timeout: 2)
        XCTAssertEqual(store.solutions[id],latest)
        XCTAssertEqual(store.solutions[id]?.sourceVersion,"new-saved-version")
        XCTAssertTrue(previewReady(store)); XCTAssertTrue(store.loading.isEmpty)
    }
    func testStoreRejectsWrongVersionGeometryEvenWhenThumbnailIsVisible() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
        await probe.returnStaleGeometry()
        store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .geometry
        store.prepareSelected(); try await waitUntil { store.loading.isEmpty }
        XCTAssertNotNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertFalse(previewReady(store)); XCTAssertTrue(store.solutions.isEmpty)
        XCTAssertNotNil(store.error)
    }
    func testRealStorePreviewTimingWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let batchPath = env["WORKFLOW_PREVIEW_BATCH"],let evidencePath = env["WORKFLOW_PREVIEW_EVIDENCE"] else { throw XCTSkip("Real store preview benchmark is opt-in") }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        var rows: [[String:Any]] = []
        for specimen in batch.specimens where !specimen.isExcluded {
            for task in [specimen.front,specimen.back] {
                for repetition in 1...3 {
                    let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
                    store.batch = batch; store.currentSpecimenID = specimen.id; store.face = task.side; store.stage = .geometry
                    var row: [String:Any] = ["face":"\(specimen.baseName)_\(task.side.fileSuffix)","repetition":repetition]
                    for phase in ["cold","warm"] {
                        let oldCount = await probe.values().count,started = Date()
                        store.refreshVisibleImage()
                        for _ in 0..<6000 {
                            if !store.loading.contains(task.id) { break }
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        row[phase + "Seconds"] = Date().timeIntervalSince(started)
                        let calls = Array((await probe.values()).dropFirst(oldCount))
                        row[phase + "DiscardedBitmaps"] = calls.filter { $0 == "discarded-bitmap" }.count
                        XCTAssertEqual(calls.filter { $0 == "image" }.count,1)
                        XCTAssertEqual(calls.filter { $0 == "geometry" }.count,1)
                        XCTAssertEqual(store.gates[task.id]?.canConfirm,true,store.error ?? "Preview validation incomplete")
                        XCTAssertEqual(store.solutions[task.id]?.sourceVersion,task.snapshot?.contentVersion)
                        XCTAssertNotNil(store.displayImage(for: task))
                    }
                    rows.append(row)
                    try JSONSerialization.data(withJSONObject: rows,options: [.prettyPrinted,.sortedKeys]).write(to: evidence.appendingPathComponent("timings.json"))
                }
            }
        }
    }
    private func loadGeometryPreview(_ store: PhotoWorkflowStore) async throws {
        store.stage = .geometry
        store.prepareSelected()
        try await waitUntil { store.currentSpecimen.map { specimen in
            [specimen.front,specimen.back].allSatisfy { store.gates[$0.id]?.canConfirm == true && !store.loading.contains($0.id) }
        } == true }
    }
    private func previewReady(_ store: PhotoWorkflowStore) -> Bool {
        guard let task = store.currentTask else { return false }
        return store.displayImage(for: task) != nil && store.gates[task.id]?.canConfirm == true && !store.loading.contains(task.id)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for native store readiness")
    }
    private func imageFixture(specimens: Int = 2,width: Int = 100) throws -> WorkflowBatch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let batchID = UUID()
        let roleIDs = PSDRoleIdentifiers(originalStackGroup: "original",adjustmentGroup: "adjust",baseLayer: "base",cutoutLayer: "cutout",mask: "mask")
        func side(_ side: WorkflowSide, index: Int) throws -> WorkflowSideTask {
            let folder = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            func write(_ name: String,_ kind: Int) throws -> URL {
                let url = folder.appendingPathComponent(name+".png")
                var bytes = [UInt8](repeating: 0,count: width*100*4)
                for y in 0..<100 { for x in 0..<width {
                    let index = (y*width+x)*4,inside = x >= width/3 && x < 2*width/3 && y >= 35 && y < 65
                    let alpha: UInt8 = kind == 1 && !inside ? 0 : 255
                    let value: UInt8 = kind == 2 ? (inside ? 255 : 0) : (alpha == 0 ? 0 : 160)
                    bytes[index] = value; bytes[index+1] = value; bytes[index+2] = value; bytes[index+3] = alpha
                } }
                let image = CGImage(width: width,height: 100,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
                let dest = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(dest,image,nil); guard CGImageDestinationFinalize(dest) else { throw WorkflowBridgeError.invalidImage("fixture") }; return url
            }
            let base = try write("base",0),cutout = try write("cutout",1),mask = try write("mask",2)
            let source = try WorkflowSourceFile(url: base,fingerprint: AIFileValidation.hash(base.path))
            var task = WorkflowSideTask(side: side,sources: WorkflowSources(first: source,second: source,third: source))
            let version = String(repeating: UUID().uuidString.replacingOccurrences(of: "-",with: "").lowercased(),count: 2),size = CGSize(width: width,height: 100),viewport = CGRect(origin: .zero,size: size)
            let working = root.appendingPathComponent(root.lastPathComponent + "_psd/specimen-\(index)_\(side.fileSuffix).psd")
            let accepted = root.appendingPathComponent(".work/accepted-final/\(task.id)/\(version).psd")
            task.snapshot = PSDSnapshot(taskID: task.id,workingURL: working,snapshotURL: accepted,contentVersion: version,pixelSize: size,roles: roleIDs,structureSummary: "fixture",finalRoles: FinalPSDIdentifiers(adjustmentGroup: "adjust",baseLayer: "base",cutoutLayer: "cutout"))
            task.acceptedFinalPSD = WorkflowAcceptedFinalPSD(taskID: task.id,sourceRevision: 1,workingURL: working,snapshotURL: accepted,contentVersion: version)
            task.roleImages = RoleImages(snapshotVersion: version,basePNG: base,cutoutPNG: cutout,maskPNG: mask,pixelSize: size,coordinateOrigin: .zero,editableExtent: viewport,cropViewport: viewport,isFinalized: true)
            task.geometrySolution = GeometrySolution(sourceVersion: version,angleDegrees: 0,rotationPivot: CGPoint(x: width/2,y: 50),subjectBounds: CGRect(x: width/3,y: 35,width: 2*width/3-width/3,height: 30),sourceCropRect: viewport,outputSize: size,actualMargins: WorkflowMargins(left: 0.3,top: 0.35,right: 0.3,bottom: 0.35),isApplicable: true)
            for stage in [WorkflowStage.stack,.matte,.geometry,.hd] { task[stage].state = .completed; task[stage].outputVersion = version; task[stage].confirmedVersion = version }
            return task
        }
        return try WorkflowBatch(id: batchID,sourceDirectory: root.resolvingSymlinksInPath(),sourceDirectoryName: root.lastPathComponent,outputDirectory: root,specimens: (0..<specimens).map { index in try WorkflowSpecimen(baseName: "specimen-\(index)",front: side(.front,index: index),back: side(.back,index: index)) })
    }
    private func alphaAtCorner(_ image: CGImage?) -> UInt8? {
        guard let image else { return nil }; var bytes = [UInt8](repeating: 0,count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress,width: 1,height: 1,bitsPerComponent: 8,bytesPerRow: 4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        }; return bytes[3]
    }
    func testSwitchSpecimenOn4KPageRefreshesActualCutoutRole() async throws {
        let batch = try imageFixture(); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.selectedSpecimens = Set(batch.specimens.map(\.id)); store.currentSpecimenID = batch.specimens[0].id; store.stage = .geometry
        store.prepareSelected(); try await waitUntil { previewReady(store) }
        let b = batch.specimens[1].front.id
        XCTAssertNil(store.images[b])
        store.stage = .png4k; store.loadCurrentExportPreview()
        try await waitUntil { previewReady(store) }
        store.currentSpecimenID = batch.specimens[1].id; store.prepareSelected()
        XCTAssertNil(store.displayImage(for: batch.specimens[1].front))
        store.loadCurrentExportPreview()
        try await waitUntil { previewReady(store) }
        XCTAssertEqual(alphaAtCorner(store.images[b]),0,"4K must never display the previous opaque base role")
    }
    func testRemoveThenExcludeFreezesHistoricalMappingWithoutHashingMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...12 { try Data("source".utf8).write(to: root.appendingPathComponent("\(index).jpg")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        let removed = draft.groups[0].files[0]!,id = draft.groups[0].id
        draft.groups[0].files[0] = nil; try FileManager.default.removeItem(at: removed); draft.groups[0].excluded = true
        let frozen = try draft.freeze(names: "excluded\nactive",output: root.appendingPathComponent("out"))
        let restored = try JSONDecoder().decode(WorkflowBatch.self,from: JSONEncoder().encode(frozen)); try restored.validate()
        XCTAssertEqual(restored.specimens[0].id,id); XCTAssertEqual(restored.specimens[0].baseName,"excluded")
        XCTAssertEqual(restored.specimens[0].front.sources.first.url,removed.resolvingSymlinksInPath())
        XCTAssertTrue(restored.specimens[0].front.sources.files.allSatisfy { $0.fingerprint.isEmpty })
        var active = restored; active.specimens[1].front.sources.first.fingerprint = ""
        XCTAssertThrowsError(try active.validate())
    }
    func testExcludedHistoricalReferencesFollowReplacementRemovalAndFaceSwap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...12 { try Data("source".utf8).write(to: root.appendingPathComponent("\(index).jpg")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        let replacement = root.appendingPathComponent("replacement.jpg")
        draft.groups[0].files[0] = replacement
        draft.groups[0].files[0] = nil
        draft.groups[0].swapFaces(); draft.groups[0].excluded = true
        let frozen = try draft.freeze(names: "excluded\nactive",output: root.appendingPathComponent("out"))
        XCTAssertEqual(frozen.specimens[0].back.sources.first.url,replacement)
        XCTAssertTrue(frozen.specimens[0].back.sources.first.fingerprint.isEmpty)
        var reactivated = frozen; reactivated.specimens[0].exclusionReason = nil
        XCTAssertThrowsError(try reactivated.validate())
    }
    func testNonemptyOutputAndDuplicateActiveSourceSlotsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...6 { try Data("source".utf8).write(to: root.appendingPathComponent("\(index).jpg")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        XCTAssertThrowsError(try draft.freeze(names: "name",output: root))
        draft.groups[0].files[1] = draft.groups[0].files[0]
        XCTAssertThrowsError(try draft.freeze(names: "name",output: root.appendingPathComponent("out")))
    }
}

@MainActor extension WorkflowPreviewTests {
    func testPositionDragIsLiveButDoesNotCommitUntilRelease() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .png4k; store.loadCurrentExportPreview()
        try await waitUntil { previewReady(store) }
        let committed = store.currentLayout
        store.updateMove(CGSize(width: 120,height: -80))
        XCTAssertEqual(store.currentLayout,committed)
        XCTAssertEqual(store.currentPreviewLayout.center,CGPoint(x: 2168,y: 1968))
        XCTAssertTrue(store.isDragging)
        store.commitMove(CGSize(width: 120,height: -80))
        XCTAssertEqual(store.currentLayout.center,CGPoint(x: 2168,y: 1968))
        XCTAssertFalse(store.isDragging)
        store.stage = .geometry; let crop = try XCTUnwrap(store.currentSolution).sourceCropRect
        store.updateMove(CGSize(width: 5,height: 7))
        XCTAssertEqual(store.currentSolution?.sourceCropRect,crop)
        XCTAssertEqual(store.currentPreviewSolution?.sourceCropRect,crop)
        XCTAssertFalse(store.isDragging,"Rotation/crop changes belong to Photoshop")
    }
    func testExplicitDetailDecodeIsCurrentRoleAndCannotEnableStaleConfirmation() async throws {
        let batch = try imageFixture(specimens: 1,width: 3000); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .png4k; store.loadCurrentExportPreview()
        try await waitUntil { previewReady(store) }
        XCTAssertEqual(store.displayImage(for: batch.specimens[0].front)?.width,2048)
        store.loadCurrentDetail()
        XCTAssertFalse(store.currentDetailReady); XCTAssertFalse(previewReady(store))
        try await waitUntil { store.currentDetailReady && previewReady(store) }
        XCTAssertEqual(store.displayImage(for: batch.specimens[0].front)?.width,3000)
        XCTAssertEqual(alphaAtCorner(store.displayImage(for: batch.specimens[0].front)),0)
        store.stage = .geometry; store.previewMode = "蒙版"
        XCTAssertNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertFalse(previewReady(store))
        try await waitUntil { store.currentDetailReady && previewReady(store) }
        XCTAssertEqual(alphaAtCorner(store.displayImage(for: batch.specimens[0].front)),255)
    }
    func testBatchLifecyclePersistsAndProtectsManualLease() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
        try await WorkflowBatchStore().save(batch,to: manifest)
        let engine = batch.outputDirectory.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("scripts"),withIntermediateDirectories: true)
        try Data("fixture engine marker".utf8).write(to: engine.appendingPathComponent("scripts/toolkit_bridge.py"))
        let originalGlobal = UserDefaults.standard.string(forKey: "aiEnginePath")
        let store = PhotoWorkflowStore(); store.openBatch(manifest)
        try await waitUntil { !store.busy && store.batch != nil }
        XCTAssertEqual(UserDefaults.standard.string(forKey: "aiEnginePath"),originalGlobal)
        store.manualTaskID = batch.specimens[0].front.id
        store.closeBatch(); XCTAssertEqual(store.batch?.id,batch.id)
        XCTAssertEqual(store.manualTaskID,batch.specimens[0].front.id)
        store.manualTaskID = nil; store.closeBatch(); try await waitUntil { !store.busy && store.batch == nil }
        let saved = try await WorkflowBatchStore().load(from: manifest)
        XCTAssertTrue(saved.isPaused); XCTAssertEqual(saved.specimens.map(\.id),batch.specimens.map(\.id))
        store.openBatch(manifest); try await waitUntil { !store.busy && store.batch != nil }
        XCTAssertEqual(store.batch?.id,batch.id)
    }
}

@MainActor extension WorkflowPreviewTests {
    func testDetailOwnershipStaysBoundedAcrossFacesAndSpecimens() async throws {
        let batch = try imageFixture(specimens: 3,width: 3000); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.selectedSpecimens = Set(batch.specimens.map(\.id)); store.currentSpecimenID = batch.specimens[0].id; store.stage = .png4k; store.loadCurrentExportPreview()
        try await waitUntil { previewReady(store) }
        var visited: Set<UUID> = []
        for specimen in batch.specimens {
            store.currentSpecimenID = specimen.id
            for face in WorkflowSide.allCases {
                store.face = face; store.loadCurrentExportPreview()
                try await waitUntil { self.previewReady(store) }
                store.loadCurrentDetail()
                let current = try XCTUnwrap(store.currentTask).id
                try await waitUntil { store.currentDetailReady && previewReady(store) }
                XCTAssertEqual(store.detailRequested,[current])
                XCTAssertLessThanOrEqual(store.images.values.filter { $0.width > 2048 }.count,1,"The store must not retain a full image for every previously inspected face")
                let prior = visited.subtracting([current])
                try await waitUntil { prior.allSatisfy { store.images[$0]?.width == 2048 } }
                visited.insert(current)
            }
        }
        store.face = .front; store.loadCurrentDetail()
        let obsolete = try XCTUnwrap(store.currentTask).id
        store.face = .back
        try await waitUntil { store.images[obsolete]?.width == 2048 && previewReady(store) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.images[obsolete]?.width,2048,"An obsolete full-detail completion must not repopulate an evicted face")
        XCTAssertFalse(store.detailRequested.contains(obsolete))
        XCTAssertLessThanOrEqual(store.images.values.filter { $0.width > 2048 }.count,1)
    }
}

@MainActor extension WorkflowPreviewTests {
    private actor GeometrySources {
        var versions: [String] = []
        func record(_ source: RoleImages) { versions.append(source.snapshotVersion) }
    }
    func testOnlyVisibleSpecimenPreparesWhileOtherSpecimensAreSelected() async throws {
        let batch = try imageFixture(specimens: 3); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = GeometrySources()
        let cache = WorkflowGeometryCache(prepare: { source in
            await probe.record(source)
            return try WorkflowGeometryCacheTests.prepare(source)
        })
        let store = PhotoWorkflowStore(geometry: cache)
        store.batch = batch
        store.currentSpecimenID = batch.specimens[2].id; store.selectedSpecimens = Set(batch.specimens.map(\.id)); store.stage = .geometry
        store.prepareSelected(); try await waitUntil { [batch.specimens[2].front,batch.specimens[2].back].allSatisfy { store.gates[$0.id]?.canConfirm == true } }
        let versions = await probe.versions
        XCTAssertEqual(Set(versions.prefix(2)),Set([batch.specimens[2].front, batch.specimens[2].back].map { $0.roleImages!.snapshotVersion }))
        XCTAssertEqual(versions.count,2)
        for task in [batch.specimens[2].front,batch.specimens[2].back] {
            XCTAssertNotNil(store.displayImage(for: task)); XCTAssertTrue(store.gates[task.id]?.canConfirm == true)
            XCTAssertEqual(store.solutions[task.id]?.sourceVersion,task.snapshot?.contentVersion)
        }
        let retained = await cache.retainedCount; XCTAssertEqual(retained,2)
        XCTAssertNil(store.images[batch.specimens[0].front.id])
    }
    func testBatchSwitchAndCloseClearSharedGeometryCache() async throws {
        let first = try imageFixture(specimens: 1),second = try imageFixture(specimens: 1)
        defer { try? FileManager.default.removeItem(at: first.outputDirectory); try? FileManager.default.removeItem(at: second.outputDirectory) }
        let cache = WorkflowGeometryCache(),store = PhotoWorkflowStore(geometry: cache)
        for batch in [first,second] {
            let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
            try await WorkflowBatchStore().save(batch,to: manifest)
            store.openBatch(manifest)
            try await waitUntil { !store.busy && store.batch?.id == batch.id }
            try await loadGeometryPreview(store)
            let count = await cache.retainedCount
            XCTAssertEqual(count,2,"Switching must discard the previous batch's entries")
        }
        store.closeBatch(); try await waitUntil { !store.busy && store.batch == nil }
        let count = await cache.retainedCount,bytes = await cache.retainedBytes
        XCTAssertEqual(count,0); XCTAssertEqual(bytes,0)
    }
}

// Hold only this actor during the reset test, exposing the otherwise tiny removeAll await window.
extension WorkflowGeometryCache {
    func holdForLifecycleTest(entered: XCTestExpectation,release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now()+5)
    }
}

@MainActor extension WorkflowPreviewTests {
    func testPreviewControlsCannotRestartOldBatchWhileCacheClears() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
        try await WorkflowBatchStore().save(batch,to: manifest)
        let cache = WorkflowGeometryCache(),store = PhotoWorkflowStore(geometry: cache)
        store.openBatch(manifest)
        try await waitUntil { !store.busy && store.batch != nil }
        try await loadGeometryPreview(store)
        XCTAssertEqual(store.gates.count,2)
        let entered = expectation(description: "Cache actor held"),release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let held = Task { await cache.holdForLifecycleTest(entered: entered,release: release) }
        await fulfillment(of: [entered],timeout: 2)
        store.closeBatch()
        try await waitUntil { store.gates.isEmpty }
        XCTAssertNotNil(store.batch,"The old batch is still selected while removeAll waits")
        store.face = .back; store.refreshVisibleImage(); store.prepareSelected(); store.loadCurrentDetail()
        XCTAssertTrue(store.previewTasks.isEmpty,"UI controls must not restart old previews during reset")
        XCTAssertTrue(store.gates.isEmpty)
        release.signal(); await held.value
        try await waitUntil { !store.busy && store.batch == nil }
        XCTAssertTrue(store.previewTasks.isEmpty); XCTAssertTrue(store.gates.isEmpty)
        let count = await cache.retainedCount; XCTAssertEqual(count,0)
    }
}


@MainActor extension WorkflowPreviewTests {
    private actor SnapshotGate {
        let entered: XCTestExpectation
        var waiting: CheckedContinuation<Void,Never>?
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func hold() async { await withCheckedContinuation { waiting = $0; entered.fulfill() } }
        func release() { waiting?.resume(); waiting = nil }
    }
    func testDelayedSnapshotCannotRestoreClosedOrReplacedBatchOrError() async throws {
        for action in ["switch","close","error"] {
            let first = try imageFixture(specimens: 1),second = try imageFixture(specimens: 1)
            defer { try? FileManager.default.removeItem(at: first.outputDirectory); try? FileManager.default.removeItem(at: second.outputDirectory) }
            let cache = WorkflowGeometryCache(),store = PhotoWorkflowStore(geometry: cache)
            let firstManifest = first.outputDirectory.appendingPathComponent("batch.json")
            let secondManifest = second.outputDirectory.appendingPathComponent("batch.json")
            try await WorkflowBatchStore().save(first,to: firstManifest)
            try await WorkflowBatchStore().save(second,to: secondManifest)
            store.openBatch(firstManifest); try await waitUntil { !store.busy && store.batch?.id == first.id }
            try await loadGeometryPreview(store)
            let entered = expectation(description: "Old snapshot captured"),gate = SnapshotGate(entered)
            defer { Task { await gate.release() } }
            let oldRead = Task {
                await store.sync { executor,id in
                    let value = try await executor.batch(batchID: id)
                    await gate.hold()
                    if action == "error" { throw WorkflowBridgeError.staleSource }
                    return value
                }
            }
            await fulfillment(of: [entered],timeout: 2)
            let expected: UUID?
            if action == "close" { store.closeBatch(); expected = nil }
            else { store.openBatch(secondManifest); expected = second.id }
            try await waitUntil { !store.busy && store.batch?.id == expected && store.loading.isEmpty }
            if expected != nil { try await loadGeometryPreview(store) }
            let ids = Set(store.gates.keys),paused = store.batch?.isPaused
            store.error = "Current session message"
            await gate.release(); await oldRead.value
            try await waitUntil { store.loading.isEmpty }
            XCTAssertEqual(store.batch?.id,expected,action)
            XCTAssertEqual(store.batch?.isPaused,paused,action)
            XCTAssertEqual(Set(store.gates.keys),ids,action)
            XCTAssertEqual(store.error,"Current session message",action)
            let count = await cache.retainedCount
            XCTAssertEqual(count,action == "close" ? 0 : 2,action)
        }
    }
}
