import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPreviewTests: XCTestCase {
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
        let batch = try draft.freeze(names: "first\nsecond",output: root.appendingPathComponent("output"),checkStack: true,checkMatte: false)
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
        XCTAssertThrowsError(try draft.freeze(names: "same\nsame",output: root.appendingPathComponent("output"),checkStack: true,checkMatte: true))
        draft.groups[0].files[0] = nil
        XCTAssertThrowsError(try draft.freeze(names: "first\nsecond",output: root.appendingPathComponent("output"),checkStack: true,checkMatte: true))
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
    func testSavedGeometryStartsAtIncrementalZeroInsteadOfReestimating() {
        let file = WorkflowSourceFile(url: URL(fileURLWithPath: "/tmp/input.jpg"),fingerprint: "hash")
        let sources = WorkflowSources(first: file,second: file,third: file)
        var task = WorkflowSideTask(side: .front,sources: sources)
        task[.geometry].state = .completed
        task.geometryRequest.angleStrategy = .manual(degrees: -14)
        task.geometrySolution = GeometrySolution(sourceVersion: "saved",angleDegrees: 0,rotationPivot: .zero,subjectBounds: CGRect(x: 0,y: 0,width: 20,height: 10),sourceCropRect: CGRect(x: 0,y: 0,width: 30,height: 20),outputSize: CGSize(width: 30,height: 20),actualMargins: WorkflowMargins(left: 0,top: 0,right: 0,bottom: 0),isApplicable: true)
        let specimen = WorkflowSpecimen(baseName: "name",front: task,back: WorkflowSideTask(side: .back,sources: sources))
        let store = PhotoWorkflowStore(); store.batch = WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/tmp"),outputDirectory: URL(fileURLWithPath: "/tmp/output"),specimens: [specimen]); store.currentSpecimenID = specimen.id
        XCTAssertEqual(store.currentRequest.angleStrategy,.manual(degrees: 0))
        XCTAssertFalse(store.canConfirm)
    }

    func testUnrefreshedManualPSDDoesNotReloadOldPreview() {
        let url = URL(fileURLWithPath: "/tmp/missing-old-source.png")
        let file = WorkflowSourceFile(url: url,fingerprint: "old")
        let sources = WorkflowSources(first: file,second: file,third: file)
        var front = WorkflowSideTask(side: .front,sources: sources)
        front.snapshot = PSDSnapshot(taskID: front.id,workingURL: url,snapshotURL: url,contentVersion: "old",pixelSize: CGSize(width: 100,height: 100),structureSummary: "old")
        front.roleImages = RoleImages(snapshotVersion: "old",basePNG: url,cutoutPNG: url,maskPNG: url,pixelSize: CGSize(width: 100,height: 100),coordinateOrigin: .zero,editableExtent: CGRect(x: 0,y: 0,width: 100,height: 100),cropViewport: CGRect(x: 0,y: 0,width: 100,height: 100))
        let specimen = WorkflowSpecimen(baseName: "name",front: front,back: WorkflowSideTask(side: .back,sources: sources))
        let store = PhotoWorkflowStore(); store.batch = WorkflowBatch(sourceDirectory: URL(fileURLWithPath: "/tmp"),outputDirectory: URL(fileURLWithPath: "/tmp/output"),specimens: [specimen]); store.currentSpecimenID = specimen.id; store.selectedSpecimens = [specimen.id]; store.manualTaskID = front.id
        store.prepareSelected()
        XCTAssertTrue(store.loading.isEmpty,"A failed/dirty manual refresh must not resurrect the prior saved preview")
        XCTAssertTrue(store.images.isEmpty); XCTAssertFalse(store.canConfirm)
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
    func testStorePreviewUsesRoleThumbnailAndValidationWithoutDiscardedBitmap() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
        store.stage = .geometry; store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]
        store.prepareSelected()
        try await waitUntil { store.canConfirm }
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
        store.stage = .geometry; store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]
        store.refreshVisibleImage()
        let id = batch.specimens[0].front.id
        let oldTask = try XCTUnwrap(store.previewTasks[id])
        await fulfillment(of: [entered],timeout: 2)
        XCTAssertNotNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertTrue(store.loading.contains(id)); XCTAssertFalse(store.canConfirm)
        batch.specimens[0].front.snapshot?.contentVersion = "new-saved-version"
        batch.specimens[0].front.roleImages?.snapshotVersion = "new-saved-version"
        batch.specimens[0].front.geometrySolution?.sourceVersion = "new-saved-version"
        store.batch = batch; store.prepareSelected()
        try await waitUntil { store.canConfirm }
        let latest = store.solutions[id]
        await probe.release()
        Task { await oldTask.value; finished.fulfill() }
        await fulfillment(of: [finished],timeout: 2)
        XCTAssertEqual(store.solutions[id],latest)
        XCTAssertEqual(store.solutions[id]?.sourceVersion,"new-saved-version")
        XCTAssertTrue(store.canConfirm); XCTAssertTrue(store.loading.isEmpty)
    }
    func testStoreRejectsWrongVersionGeometryEvenWhenThumbnailIsVisible() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let probe = PreviewProbe(),store = PhotoWorkflowStore(previews: probe)
        await probe.returnStaleGeometry()
        store.stage = .geometry; store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]
        store.prepareSelected(); try await waitUntil { store.loading.isEmpty }
        XCTAssertNotNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertFalse(store.canConfirm); XCTAssertTrue(store.solutions.isEmpty)
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
                    store.stage = .geometry; store.batch = batch; store.currentSpecimenID = specimen.id; store.face = task.side
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
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for native store readiness")
    }
    private func imageFixture(specimens: Int = 2,width: Int = 100) throws -> WorkflowBatch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let roleIDs = PSDRoleIdentifiers(originalStackGroup: "original",adjustmentGroup: "adjust",baseLayer: "base",cutoutLayer: "cutout",mask: "mask")
        func side(_ side: WorkflowSide) throws -> WorkflowSideTask {
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
            let version = UUID().uuidString,size = CGSize(width: width,height: 100),viewport = CGRect(origin: .zero,size: size)
            task.snapshot = PSDSnapshot(taskID: task.id,workingURL: base,snapshotURL: base,contentVersion: version,pixelSize: size,roles: roleIDs,structureSummary: "fixture")
            task.roleImages = RoleImages(snapshotVersion: version,basePNG: base,cutoutPNG: cutout,maskPNG: mask,pixelSize: size,coordinateOrigin: .zero,editableExtent: viewport,cropViewport: viewport)
            task.geometrySolution = GeometrySolution(sourceVersion: version,angleDegrees: 0,rotationPivot: CGPoint(x: width/2,y: 50),subjectBounds: CGRect(x: width/3,y: 35,width: 2*width/3-width/3,height: 30),sourceCropRect: viewport,outputSize: size,actualMargins: WorkflowMargins(left: 0.3,top: 0.35,right: 0.3,bottom: 0.35),isApplicable: true)
            for stage in [WorkflowStage.stack,.matte,.geometry,.hd] { task[stage].state = .completed; task[stage].outputVersion = version; task[stage].confirmedVersion = version }
            return task
        }
        return try WorkflowBatch(sourceDirectory: root,outputDirectory: root,specimens: (0..<specimens).map { index in try WorkflowSpecimen(baseName: "specimen-\(index)",front: side(.front),back: side(.back)) })
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
        store.prepareSelected(); try await waitUntil { batch.sideTasks.allSatisfy { store.gates[$0.id]?.canConfirm == true } }
        let b = batch.specimens[1].front.id
        XCTAssertEqual(alphaAtCorner(store.images[b]),255)
        store.stage = .png4k; store.refreshVisibleImage()
        try await waitUntil { store.gates[batch.specimens[0].front.id]?.canConfirm == true }
        store.currentSpecimenID = batch.specimens[1].id; store.prepareSelected()
        try await waitUntil { store.gates[b]?.canConfirm == true }
        XCTAssertEqual(alphaAtCorner(store.images[b]),0,"4K must never display the previous opaque base role")
    }
    func testRemoveThenExcludeFreezesHistoricalMappingWithoutHashingMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...12 { try Data("source".utf8).write(to: root.appendingPathComponent("\(index).jpg")) }
        var draft = try WorkflowBatchDraft.scan(directory: root)
        let removed = draft.groups[0].files[0]!,id = draft.groups[0].id
        draft.groups[0].files[0] = nil; try FileManager.default.removeItem(at: removed); draft.groups[0].excluded = true
        let frozen = try draft.freeze(names: "excluded\nactive",output: root.appendingPathComponent("out"),checkStack: true,checkMatte: true)
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
        let frozen = try draft.freeze(names: "excluded\nactive",output: root.appendingPathComponent("out"),checkStack: true,checkMatte: true)
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
        XCTAssertThrowsError(try draft.freeze(names: "name",output: root,checkStack: true,checkMatte: true))
        draft.groups[0].files[1] = draft.groups[0].files[0]
        XCTAssertThrowsError(try draft.freeze(names: "name",output: root.appendingPathComponent("out"),checkStack: true,checkMatte: true))
    }
}

@MainActor extension WorkflowPreviewTests {
    func testPositionDragIsLiveButDoesNotCommitUntilRelease() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .png4k; store.prepareSelected()
        try await waitUntil { store.canConfirm }
        let committed = store.currentLayout
        store.updateMove(CGSize(width: 120,height: -80))
        XCTAssertEqual(store.currentLayout,committed)
        XCTAssertEqual(store.currentPreviewLayout.center,CGPoint(x: 2168,y: 1968))
        XCTAssertFalse(store.canConfirm)
        store.commitMove(CGSize(width: 120,height: -80))
        XCTAssertEqual(store.currentLayout.center,CGPoint(x: 2168,y: 1968))
        XCTAssertFalse(store.isDragging)
        store.stage = .geometry; let crop = try XCTUnwrap(store.currentSolution).sourceCropRect
        store.updateMove(CGSize(width: 5,height: 7))
        XCTAssertEqual(store.currentSolution?.sourceCropRect,crop)
        XCTAssertEqual(store.currentPreviewSolution?.sourceCropRect,crop.offsetBy(dx: -5,dy: -7))
    }
    func testExplicitDetailDecodeIsCurrentRoleAndCannotEnableStaleConfirmation() async throws {
        let batch = try imageFixture(specimens: 1,width: 3000); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let store = PhotoWorkflowStore(); store.batch = batch; store.currentSpecimenID = batch.specimens[0].id; store.selectedSpecimens = [batch.specimens[0].id]; store.stage = .png4k; store.prepareSelected()
        try await waitUntil { store.canConfirm }
        XCTAssertEqual(store.displayImage(for: batch.specimens[0].front)?.width,2048)
        store.loadCurrentDetail()
        XCTAssertFalse(store.currentDetailReady); XCTAssertFalse(store.canConfirm)
        try await waitUntil { store.currentDetailReady && store.canConfirm }
        XCTAssertEqual(store.displayImage(for: batch.specimens[0].front)?.width,3000)
        XCTAssertEqual(alphaAtCorner(store.displayImage(for: batch.specimens[0].front)),0)
        store.previewMode = "蒙版"; store.stage = .geometry
        XCTAssertNil(store.displayImage(for: batch.specimens[0].front))
        XCTAssertFalse(store.canConfirm)
        try await waitUntil { store.currentDetailReady && store.canConfirm }
        XCTAssertEqual(alphaAtCorner(store.displayImage(for: batch.specimens[0].front)),255)
    }
    func testBatchLifecycleConfiguresLocalEnginePersistsAndProtectsManualLease() async throws {
        let batch = try imageFixture(specimens: 1); defer { try? FileManager.default.removeItem(at: batch.outputDirectory) }
        let manifest = batch.outputDirectory.appendingPathComponent("batch.json")
        try await WorkflowBatchStore().save(batch,to: manifest)
        let engine = batch.outputDirectory.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engine.appendingPathComponent("scripts"),withIntermediateDirectories: true)
        try Data("fixture engine marker".utf8).write(to: engine.appendingPathComponent("scripts/toolkit_bridge.py"))
        let originalGlobal = UserDefaults.standard.string(forKey: "aiEnginePath")
        let store = PhotoWorkflowStore(); store.openBatch(manifest)
        try await waitUntil { !store.busy && store.batch != nil }
        store.configureEngine(engine); try await waitUntil { !store.busy }
        XCTAssertEqual(store.enginePath,engine.path); XCTAssertEqual(store.batch?.isPaused,true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "aiEnginePath"),originalGlobal)
        store.manualTaskID = batch.specimens[0].front.id
        store.closeBatch(); XCTAssertEqual(store.batch?.id,batch.id)
        store.configureEngine(URL(fileURLWithPath: "/tmp/other-engine")); XCTAssertEqual(store.enginePath,engine.path)
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
        let store = PhotoWorkflowStore(); store.batch = batch; store.selectedSpecimens = Set(batch.specimens.map(\.id)); store.currentSpecimenID = batch.specimens[0].id; store.stage = .png4k; store.prepareSelected()
        try await waitUntil { store.canConfirm }
        var visited: Set<UUID> = []
        for specimen in batch.specimens {
            store.currentSpecimenID = specimen.id
            for face in WorkflowSide.allCases {
                store.face = face; store.prepareSelected(); store.loadCurrentDetail()
                let current = try XCTUnwrap(store.currentTask).id
                try await waitUntil { store.currentDetailReady && store.canConfirm }
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
        try await waitUntil { store.images[obsolete]?.width == 2048 && store.canConfirm }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.images[obsolete]?.width,2048,"An obsolete full-detail completion must not repopulate an evicted face")
        XCTAssertFalse(store.detailRequested.contains(obsolete))
        XCTAssertLessThanOrEqual(store.images.values.filter { $0.width > 2048 }.count,1)
    }
}
