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
        let service = WorkflowMatteService(engine: directory, workspace: directory, device: "cpu", run: { engine, arguments in
            XCTAssertEqual(engine, directory)
            XCTAssertEqual(arguments, ["--workspace", directory.path, "infer", "--input", inputURL.path, "--device", "cpu"])
            return event
        })
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
                let regex = try NSRegularExpression(pattern:#"wfRolePNG\(copy,("[^"]*/base\.png")\)"#)
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
    func testSavedRefreshAndRepeatedExtractionReuseVerifiedRolesAcrossBridgeInstances() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: saved)
        let reopened = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let refreshed = try await reopened.refreshSavedPSD(document: f.document,owner: f.owner)
        let second = try await reopened.extractRoles(snapshot: refreshed)
        XCTAssertEqual(first,second)
        let extractions = await f.calls.values()
        XCTAssertEqual(extractions.count,1,"Refreshing and exporting an unchanged PSD must not re-export intermediate PNGs")
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
    }
    func testMissingOrChangedRoleCacheIsReextracted() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: saved)
        let expectedMask = try Data(contentsOf: first.maskPNG)
        try Data("damaged-mask".utf8).write(to: first.maskPNG)
        let repaired = try await bridge.extractRoles(snapshot: saved)
        XCTAssertEqual(try Data(contentsOf: repaired.maskPNG),expectedMask)
        try FileManager.default.removeItem(at: repaired.cutoutPNG)
        let recovered = try await bridge.extractRoles(snapshot: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.cutoutPNG.path))
        let receipt = f.directory.appendingPathComponent("role-cache/\(f.owner)/\(saved.contentVersion).json")
        try Data("incomplete-receipt".utf8).write(to: receipt)
        _ = try await bridge.extractRoles(snapshot: saved)
        let extractions = await f.calls.values()
        XCTAssertEqual(extractions.count,4,"One initial extraction plus one per damaged image or receipt")
    }
    func testRoleCacheCannotBypassOwnershipOrSnapshotIntegrity() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let record = f.document.appendingPathExtension("workflow-owner.json"),original = try Data(contentsOf: record)
        var ownership = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String:Any])
        ownership["owner"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: ownership).write(to: record)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        try original.write(to: record)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath: saved.snapshotURL.path)
        try Data("changed-immutable-copy".utf8).write(to: saved.snapshotURL)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        await rejects { _ = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner) }
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,1)
    }
    func testRoleReuseStillRejectsUnsavedAndChangedPSD() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        _ = try await bridge.extractRoles(snapshot: saved)
        let unsaved = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: { _ in throw WorkflowBridgeError.unsavedDocument })
        do { _ = try await unsaved.extractRoles(snapshot: saved); XCTFail("Unsaved PSD accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.unsavedDocument) }
        try Data("new-saved-role-psd".utf8).write(to: f.document)
        do { _ = try await bridge.extractRoles(snapshot: saved); XCTFail("Stale snapshot accepted") }
        catch { XCTAssertEqual(error as? WorkflowBridgeError,.staleSource) }
        let changed = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let images = try await bridge.extractRoles(snapshot: changed)
        XCTAssertEqual(images.snapshotVersion,changed.contentVersion)
        XCTAssertNotEqual(changed.contentVersion,saved.contentVersion)
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,2)
    }
    // Opt-in Photoshop verification. All outputs go to a new evidence directory; source PSDs are read only.
    func testReal4KExportReuseAndPixelsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let batchPath = environment["WORKFLOW_EXPORT_BATCH"],let evidencePath = environment["WORKFLOW_EXPORT_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop export verification is opt-in")
        }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        for (index,task) in batch.activeTasks.enumerated() {
            let source = try XCTUnwrap(task.snapshot),reference = try XCTUnwrap(task.roleImages)
            let folder = evidence.appendingPathComponent(source.workingURL.deletingPathExtension().lastPathComponent)
            let calls = Gate()
            let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                if script.contains("base.png") { await calls.append(1) }
                return try await PhotoshopWorkflowBridge.execute(script)
            }
            let bridge = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
            let before = try AIFileValidation.hash(source.workingURL.path)
            let started = Date()
            let saved = try await bridge.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
            let images = try await bridge.extractRoles(snapshot: saved)
            let coldSeconds = Date().timeIntervalSince(started)
            try JSONEncoder().encode(images).write(to: folder.appendingPathComponent("roles.json"))
            try JSONEncoder().encode(reference).write(to: folder.appendingPathComponent("reference-roles.json"))
            let warmStart = Date()
            let reopened = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
            let refreshed = try await reopened.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
            let cached = try await reopened.extractRoles(snapshot: refreshed)
            let warmSeconds = Date().timeIntervalSince(warmStart)
            XCTAssertEqual(cached,images)
            let extractions = await calls.values(); XCTAssertEqual(extractions.count,1)
            XCTAssertEqual(images.pixelSize,reference.pixelSize)
            XCTAssertEqual(images.coordinateOrigin,reference.coordinateOrigin)
            for (actualURL,expectedURL) in zip([images.basePNG,images.cutoutPNG,images.maskPNG],[reference.basePNG,reference.cutoutPNG,reference.maskPNG]) {
                let actual = try WorkflowRaster.read(actualURL),expected = try WorkflowRaster.read(expectedURL)
                XCTAssertEqual(actual.size,expected.size)
                XCTAssertEqual(actual.profileName,expected.profileName)
                XCTAssertEqual(actual.profileData,expected.profileData)
                XCTAssertTrue(actual.pixels == expected.pixels,"Changed pixels: \(actualURL.lastPathComponent)")
            }
            let output = folder.appendingPathComponent("4k.png"),renderStart = Date()
            try WorkflowAssetRenderer().render4K(roles: images,layout: task.squareLayout,destination: output)
            let renderSeconds = Date().timeIntervalSince(renderStart)
            let published = try XCTUnwrap(task.artifacts.last { $0.kind == .png4k && $0.state == .completed })
            XCTAssertTrue(try WorkflowRaster.read(output).pixels == WorkflowRaster.read(published.url).pixels,"Final 4K pixels changed")
            XCTAssertEqual(try AIFileValidation.hash(source.workingURL.path),before)
            var summary: [String:Any] = ["coldRefreshAndExtractSeconds":coldSeconds,"cachedRefreshAndExtractSeconds":warmSeconds,
                "render4KSeconds":renderSeconds,"roleExtractions":extractions.count,"publishedReference":published.url.path]
            if index == 0 {
                let legacy = PhotoshopWorkflowBridge(workspace: folder.appendingPathComponent("legacy"),scriptRunner: { script in
                    let old = script.replacingOccurrences(of: "wfRolePNG(copy,",with: "wfPNG(copy,")
                        .replacingOccurrences(of: "wfRolePNG(mask,",with: "wfPNG(mask,")
                    return try await PhotoshopWorkflowBridge.execute(old)
                })
                let baselineStart = Date()
                let baseline = try await legacy.refreshSavedPSD(document: source.workingURL,owner: source.taskID)
                let legacyImages = try await legacy.extractRoles(snapshot: baseline)
                summary["saveForWebRefreshAndExtractSeconds"] = Date().timeIntervalSince(baselineStart)
                try JSONEncoder().encode(legacyImages).write(to: folder.appendingPathComponent("legacy-roles.json"))
            }
            try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
        }
    }
    private func roleCacheFixture() throws -> (directory: URL,document: URL,owner: UUID,runner: PhotoshopWorkflowBridge.ScriptRunner,calls: Gate) {
        let directory = try temporaryDirectory(),document = directory.appendingPathComponent("owned.psd"),owner = UUID(),calls = Gate()
        try Data("saved-role-psd".utf8).write(to: document)
        let roles = PSDRoleIdentifiers(originalStackGroup: "1",adjustmentGroup: "2",baseLayer: "3",cutoutLayer: "4",mask: "4:userMask")
        let encodedRoles = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roles))
        try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString,"roles":encodedRoles]).write(to: document.appendingPathExtension("workflow-owner.json"))
        let metadata = String(decoding:try JSONSerialization.data(withJSONObject: ["width":2,"height":2,"profile":"AdobeRGB","summary":"roles","roles":encodedRoles,"originX":0,"originY":0,"extentWidth":2,"extentHeight":2]),as:UTF8.self)
        let fixtures = directory.appendingPathComponent("fixtures"); try FileManager.default.createDirectory(at: fixtures,withIntermediateDirectories: true)
        try png(fixtures.appendingPathComponent("base.png"),width:2,height:2,pixels:[255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255])
        try png(fixtures.appendingPathComponent("mask.png"),width:2,height:2,pixels:[255,255,255,255,0,0,0,255,255,255,255,255,0,0,0,255])
        try png(fixtures.appendingPathComponent("cutout.png"),width:2,height:2,pixels:[255,0,0,255,0,0,0,0,0,0,255,255,0,0,0,0])
        let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
            let regex = try NSRegularExpression(pattern:#"wfRolePNG\(copy,("[^"]*/base\.png")\)"#)
            if let match = regex.firstMatch(in:script,range:NSRange(script.startIndex...,in:script)),let range = Range(match.range(at:1),in:script) {
                let destination = try JSONDecoder().decode(String.self,from:Data(script[range].utf8))
                let folder = URL(fileURLWithPath:destination).deletingLastPathComponent()
                for name in ["base.png","mask.png","cutout.png"] { try FileManager.default.copyItem(at:fixtures.appendingPathComponent(name),to:folder.appendingPathComponent(name)) }
                await calls.append(1)
            }
            return metadata
        }
        return (directory,document,owner,runner,calls)
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
