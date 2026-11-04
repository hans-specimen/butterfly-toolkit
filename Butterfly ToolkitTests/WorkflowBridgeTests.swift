import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

@MainActor
final class WorkflowBridgeTests: XCTestCase {
    actor Gate {
        var entered: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        func suspend() async { entered.append(1); await withCheckedContinuation { release = $0 } }
        func finish() { release?.resume(); release = nil }
        func append(_ value: Int) { entered.append(value) }
        func values() -> [Int] { entered }
    }
    func testPhotoshopLeaseSurvivesAwait() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate()
        let first = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let second = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertEqual(before, [1])
        await gate.finish(); try await first.value; try await second.value
        let after = await gate.values(); XCTAssertEqual(after, [1, 2])
    }
    func testManualEditingBlocksAutomaticWrites() async throws {
        let lease = PhotoshopExecutionCoordinator(), owner = UUID(), gate = Gate()
        try await lease.beginManualEditing(owner: owner)
        let automatic = Task { try await lease.run(owner: owner) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertTrue(before.isEmpty)
        await lease.endManualEditing(owner: UUID())
        let stillBlocked = await gate.values(); XCTAssertTrue(stillBlocked.isEmpty)
        await lease.endManualEditing(owner: owner); try await automatic.value
        let after = await gate.values(); XCTAssertEqual(after, [2])
    }
    func testManualRequestTakesPriorityAfterCurrentOperation() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate(), owner = UUID()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let queued = Task { await gate.append(9); try await lease.run(owner: UUID()) { await gate.append(2) } }
        while !(await gate.values()).contains(9) { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        let manual = Task { await gate.append(8); try await lease.beginManualEditing(owner: owner); await gate.append(3) }
        while !(await gate.values()).contains(8) { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        await gate.finish(); try await current.value; try await manual.value
        let before = await gate.values(); XCTAssertFalse(before.contains(2))
        await lease.endManualEditing(owner: owner); try await queued.value
    }
    func testCancelledQueuedOperationNeverWritesAndReleasesLease() async throws {
        let lease = PhotoshopExecutionCoordinator(), gate = Gate()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        let cancelled = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        cancelled.cancel(); await gate.finish(); try await current.value
        do { try await cancelled.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        try await lease.run(owner: UUID()) { await gate.append(3) }
        let values = await gate.values(); XCTAssertEqual(values, [1,3])
    }
    func testCancelledWriterFinishesBeforeManualContinueWithoutReleasingReservation() async throws {
        let lease = PhotoshopExecutionCoordinator(),owner = UUID(),gate = Gate()
        try await lease.beginManualEditing(owner: owner)
        let finished = expectation(description: "Cancelled queued writer finishes while editing remains reserved")
        let cancelled = Task {
            do { try await lease.run(owner: owner) { await gate.append(99) }; XCTFail("Cancelled write ran") }
            catch is CancellationError { finished.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        for _ in 0..<100 { await Task.yield() }
        cancelled.cancel()
        await fulfillment(of: [finished], timeout: 1.0)
        let next = Task { try await lease.run(owner: owner) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertTrue(before.isEmpty,"Cancellation must not release manual reservation")
        await lease.endManualEditing(owner: owner); await cancelled.value; try await next.value
    }
    func testCancelledInFlightOperationRetainsLeaseUntilItActuallyFinishes() async throws {
        let lease = PhotoshopExecutionCoordinator(),gate = Gate()
        let current = Task { try await lease.run(owner: UUID()) { await gate.suspend() } }
        while await gate.values().isEmpty { await Task.yield() }
        current.cancel()
        let next = Task { try await lease.run(owner: UUID()) { await gate.append(2) } }
        for _ in 0..<100 { await Task.yield() }
        let before = await gate.values(); XCTAssertEqual(before,[1])
        await gate.finish(); try await current.value; try await next.value
    }
    func testStackRefusesUnknownExistingPSDWithoutChangingIt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("unknown.psd")
        try Data("user-edited".utf8).write(to: document)
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in XCTFail("Existing PSD must not open"); return "" })
        let job = FocusStackJob(id: 0,sourceFiles: [document,document,document],destinationURL: document,butterflyName: "sample",side: "F")
        do { _ = try await bridge.stack(job: job,owner: UUID()); XCTFail("Unknown PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.ownershipConflict) }
        XCTAssertEqual(try Data(contentsOf: document),Data("user-edited".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.appendingPathExtension("workflow-owner.json").path))
    }
    func testUnsavedPSDRejectsRefresh() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID()
        try Data("saved".utf8).write(to: document)
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            throw WorkflowBridgeError.unsavedDocument
        })
        do { _ = try await bridge.refreshSavedPSD(document: document, owner: owner); XCTFail("Unsaved accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError, .unsavedDocument) }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["owned.psd"], "No snapshot may be created during an unsaved edit")
    }
    func testInvalidMatteResultsCannotSucceed() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.png")
        try png(inputURL, width: 2, height: 2, pixels: [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255])
        let input = StackPNG(snapshotVersion: "saved", pngURL: inputURL, fingerprint: try AIFileValidation.hash(inputURL.path), pixelSize: CGSize(width: 2,height: 2), orientation: 1, colorProfile: "sRGB")
        let alpha = directory.appendingPathComponent("alpha.png"), cutout = directory.appendingPathComponent("cutout.png")
        try png(alpha, width: 2, height: 2, pixels: [255,255,255,255, 0,0,0,255, 255,255,255,255, 0,0,0,255])
        try png(cutout, width: 2, height: 2, pixels: [255,0,0,255, 0,0,0,0, 0,0,255,255, 0,0,0,0])
        let record = directory.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: ["inputSha256": input.fingerprint]).write(to: record)
        let event = AIEvent(event: "completed", input: inputURL.path, prediction: cutout.path, predictionAlpha: alpha.path)
        let service = WorkflowMatteService(engine: directory, workspace: directory, device: "cpu", run: { _, _ in event })
        _ = try await service.infer(input: input)
        let wrongInputEvent = AIEvent(event: "completed",input: "/other-source.png",prediction: cutout.path,predictionAlpha: alpha.path)
        let wrongInput = WorkflowMatteService(engine: directory,workspace: directory,run: { _,_ in wrongInputEvent })
        await rejects { _ = try await wrongInput.infer(input: input) }
        let missingAlphaEvent = AIEvent(event: "completed",input: inputURL.path,prediction: cutout.path)
        let missingAlpha = WorkflowMatteService(engine: directory,workspace: directory,run: { _,_ in missingAlphaEvent })
        await rejects { _ = try await missingAlpha.infer(input: input) }
        try JSONSerialization.data(withJSONObject: ["inputSha256": "other-input"]).write(to: record)
        await rejects { _ = try await service.infer(input: input) }
        try JSONSerialization.data(withJSONObject: ["inputSha256": input.fingerprint]).write(to: record)
        // The alpha is flipped but the cutout remains at its original coordinates.
        try png(alpha, width: 2, height: 2, pixels: [0,0,0,255,255,255,255,255,0,0,0,255,255,255,255,255])
        await rejects { _ = try await service.infer(input: input) }
        try png(alpha, width: 1, height: 1, pixels: [255,255,255,255])
        await rejects { _ = try await service.infer(input: input) }
        try Data("unreadable".utf8).write(to: alpha)
        await rejects { _ = try await service.infer(input: input) }
        try FileManager.default.removeItem(at: alpha)
        await rejects { _ = try await service.infer(input: input) }
    }
    func testSavedRefreshCanReadWithinManualLeaseWithoutReleasingIt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID(), lease = PhotoshopExecutionCoordinator(), gate = Gate()
        try Data("saved".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner": owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, coordinator: lease, scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        try await lease.beginManualEditing(owner: owner)
        let writer = Task { try await lease.run(owner: UUID()) { await gate.append(1) } }
        let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
        XCTAssertEqual(try Data(contentsOf: snapshot.snapshotURL), Data("saved".utf8))
        let before = await gate.values(); XCTAssertTrue(before.isEmpty)
        await lease.endManualEditing(owner: owner); try await writer.value
        let after = await gate.values(); XCTAssertEqual(after, [1])
    }
    func testRefreshRejectsAFileChangingDuringSavedRead() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID(), count = Gate()
        try Data("saved".utf8).write(to: document)
        try JSONSerialization.data(withJSONObject: ["owner": owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            await count.append(1)
            if await count.values().count == 2 { try Data("being-saved".utf8).write(to: document) }
            return "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        await rejects { _ = try await bridge.refreshSavedPSD(document: document, owner: owner) }
        let files = FileManager.default.enumerator(atPath: directory.path)!.allObjects as! [String]
        XCTAssertFalse(files.contains { $0.hasPrefix("snapshots/") && $0.hasSuffix(".psd") })
    }
    func testSavedRefreshRejectsDeletedRoleIdentity() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"), owner = UUID()
        try Data("saved".utf8).write(to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup: "1",adjustmentGroup: "2",baseLayer: "3",cutoutLayer: "4",mask: "4:mask")
        var ownership = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roles)) as! [String: Any]
        ownership = ["owner":owner.uuidString,"roles":ownership]
        try JSONSerialization.data(withJSONObject: ownership).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory, scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"deleted-role\"}"
        })
        do { _ = try await bridge.refreshSavedPSD(document: document,owner: owner); XCTFail("Deleted role accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.invalidStructure) }
    }
    func testCrashAdoptionRequiresOrderedSourcesAndInitialContentHash() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"),owner = UUID()
        try Data("initial-stack".utf8).write(to: document)
        let initialHash = try AIFileValidation.hash(document.path)
        var sources: [WorkflowSourceFile] = []
        for index in 0..<3 {
            let source = directory.appendingPathComponent("source-\(index).jpg")
            try Data("source-\(index)".utf8).write(to: source)
            sources.append(try WorkflowSourceFile(url: source.resolvingSymlinksInPath(),fingerprint: AIFileValidation.hash(source.path)))
        }
        let sourceRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sources))
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,"sources":sourceRecord,"initialStackVersion":initialHash]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace: directory,scriptRunner: { _ in
            "{\"width\":2,\"height\":2,\"profile\":\"sRGB\",\"summary\":\"stack\"}"
        })
        let snapshot = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: sources)
        XCTAssertEqual(snapshot.contentVersion,initialHash)
        await rejects { _ = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: Array(sources.reversed())) }
        try Data("foreign-file-at-same-path".utf8).write(to: document)
        await rejects { _ = try await bridge.refreshSavedPSD(document: document,owner: owner,expectedSources: sources) }
        // Legitimate later saved edits use normal refresh, not initial-stack crash adoption.
        let human = try await bridge.refreshSavedPSD(document: document,owner: owner)
        XCTAssertNotEqual(human.contentVersion,initialHash)
        XCTAssertEqual(try Data(contentsOf: snapshot.snapshotURL),Data("initial-stack".utf8))
    }
    func testRecordedMattePublicationRecoversAfterPSDWasSavedBeforeOwnershipFinalization() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("owned.psd"),source = directory.appendingPathComponent("source.psd"),result = directory.appendingPathComponent("immutable-result.psd"),owner = UUID()
        try Data("old-stack".utf8).write(to: source);try Data("installed-matte".utf8).write(to: result)
        try FileManager.default.copyItem(at: result,to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup:"1",adjustmentGroup:"2",baseLayer:"3",cutoutLayer:"4",mask:"4:userMask")
        let prepared = try PSDSnapshot(taskID:owner,workingURL:result,snapshotURL:result,contentVersion:AIFileValidation.hash(result.path),pixelSize:CGSize(width:2,height:2),roles:roles,structureSummary:"roles")
        let fixtures = directory.appendingPathComponent("fixtures");try FileManager.default.createDirectory(at: fixtures,withIntermediateDirectories:true)
        let base = fixtures.appendingPathComponent("base.png"),mask = fixtures.appendingPathComponent("mask.png"),cutout = fixtures.appendingPathComponent("cutout.png")
        try png(base,width:2,height:2,pixels:[255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255])
        try png(mask,width:2,height:2,pixels:[255,255,255,255,0,0,0,255,255,255,255,255,0,0,0,255])
        try png(cutout,width:2,height:2,pixels:[255,0,0,255,0,0,0,0,0,0,255,255,0,0,0,0])
        let matte = try MatteArtifact(inputPNGFingerprint:"input",alphaURL:mask,alphaFingerprint:AIFileValidation.hash(mask.path),cutoutURL:cutout,cutoutFingerprint:AIFileValidation.hash(cutout.path),orientation:1,pixelSize:CGSize(width:2,height:2))
        let transaction: [String: Any] = ["sourceVersion":try AIFileValidation.hash(source.path),"result":try JSONSerialization.jsonObject(with:JSONEncoder().encode(prepared)),"matte":try JSONSerialization.jsonObject(with:JSONEncoder().encode(matte))]
        let ownership: [String: Any] = ["owner":owner.uuidString,"pendingInstall":transaction]
        let record = document.appendingPathExtension("workflow-owner.json")
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        let encodedRoles = String(decoding:try JSONEncoder().encode(roles),as:UTF8.self)
        let metadata = "{\"width\":2,\"height\":2,\"profile\":\"AdobeRGB\",\"summary\":\"roles\",\"roles\":\(encodedRoles),\"originX\":0,\"originY\":0,\"extentWidth\":2,\"extentHeight\":2}"
        let lease = PhotoshopExecutionCoordinator()
        let bridge = PhotoshopWorkflowBridge(workspace:directory,coordinator:lease,scriptRunner:{ script in
            if script.contains("base.png") {
                let regex = try NSRegularExpression(pattern:#"wfPNG\(copy,("[^"]*/base\.png")\)"#)
                guard let match=regex.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range=Range(match.range(at:1),in:script) else { throw WorkflowBridgeError.invalidStructure }
                let destination = try JSONDecoder().decode(String.self,from:Data(script[range].utf8))
                let folder=URL(fileURLWithPath:destination).deletingLastPathComponent()
                for name in ["base.png","mask.png","cutout.png"] { try FileManager.default.copyItem(at:fixtures.appendingPathComponent(name),to:folder.appendingPathComponent(name)) }
            }
            if !script.contains("base.png"),try Data(contentsOf:document) == Data("old-stack".utf8) {
                return "{\"width\":2,\"height\":2,\"profile\":\"AdobeRGB\",\"summary\":\"stack\"}"
            }
            return metadata
        })
        let recovered = try await bridge.refreshSavedPSD(document:document,owner:owner)
        XCTAssertEqual(recovered.roles,roles);XCTAssertEqual(recovered.contentVersion,prepared.contentVersion)
        let finalized = try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        XCTAssertNotNil(finalized["roles"]);XCTAssertNil(finalized["pendingInstall"])
        XCTAssertEqual(try Data(contentsOf:source),Data("old-stack".utf8))
        // A foreign changed file cannot be recovered from even a genuine pending result record.
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        try Data("foreign-unrecorded-result".utf8).write(to:document)
        await rejects { _ = try await bridge.refreshSavedPSD(document:document,owner:owner) }
        // Removing the transaction must not relax normal role validation.
        try JSONSerialization.data(withJSONObject:["owner":owner.uuidString]).write(to:record)
        try Data("installed-matte".utf8).write(to:document)
        await rejects { _ = try await bridge.refreshSavedPSD(document:document,owner:owner) }
        // A prepared but unpublished result cannot write through a manual saved-read lease.
        try JSONSerialization.data(withJSONObject:ownership).write(to:record)
        try Data("old-stack".utf8).write(to:document)
        try await lease.beginManualEditing(owner:owner)
        let unchanged = try await bridge.refreshSavedPSD(document:document,owner:owner)
        XCTAssertNil(unchanged.roles);XCTAssertEqual(try Data(contentsOf:document),Data("old-stack".utf8))
        let stillPending = try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        XCTAssertNotNil(stillPending["pendingInstall"])
        await lease.endManualEditing(owner:owner)
        let resumed = try await bridge.installMatte(snapshot:unchanged,matte:matte)
        XCTAssertEqual(resumed.roles,roles);XCTAssertEqual(resumed.contentVersion,prepared.contentVersion)
    }
    func testGeometryRequiresExplicitPivotInSavedSourceFrame() throws {
        let solution = GeometrySolution(sourceVersion: "current-saved", angleDegrees: 7, rotationPivot: CGPoint(x: 17,y: 31),
            leftWingTip: CGPoint(x: 1,y: 2), rightWingTip: CGPoint(x: 5,y: 4), subjectBounds: CGRect(x: -8,y: -3,width: 40,height: 20),
            sourceCropRect: CGRect(x: -9,y: -4,width: 50,height: 30), outputSize: CGSize(width: 50,height: 30),
            actualMargins: WorkflowMargins(left: 0.1,top: 0.1,right: 0.1,bottom: 0.1), isApplicable: true)
        let encoded = try JSONEncoder().encode(solution)
        XCTAssertEqual(try JSONDecoder().decode(GeometrySolution.self, from: encoded), solution)
        var missing = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        missing.removeValue(forKey: "rotationPivot")
        XCTAssertThrowsError(try JSONDecoder().decode(GeometrySolution.self, from: JSONSerialization.data(withJSONObject: missing)))
    }
    private func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Invalid output accepted") } catch {}
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkflowBridgeTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func png(_ url: URL, width: Int, height: Int, pixels: [UInt8]) throws {
        let color = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: color, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
