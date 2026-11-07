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
        let document = directory.appendingPathComponent("owned.psd"),source = directory.appendingPathComponent("source.psd"),owner = UUID()
        let version = "9d022835c729988271c49048470eb33895c616efa58078153841079ae5f24fb3"
        let result = directory.appendingPathComponent("snapshots/\(owner)/\(version).psd")
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(),withIntermediateDirectories: true)
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
        let lease = PhotoshopExecutionCoordinator(),calls = Gate()
        let resultOwnership: [String:Any] = ["owner":owner.uuidString,"roles":try JSONSerialization.jsonObject(with:JSONEncoder().encode(roles))]
        try JSONSerialization.data(withJSONObject:resultOwnership).write(to:result.appendingPathExtension("workflow-owner.json"))
        let bridge = PhotoshopWorkflowBridge(workspace:directory,coordinator:lease,scriptRunner:{ script in
            if script.contains("copy.mergeVisibleLayers()") { await calls.append(2) }
            if script.contains("base.png") {
                await calls.append(1)
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
        _ = try await bridge.extractRoles(snapshot:prepared)
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
        _ = try await bridge.extractRoles(snapshot:resumed)
        let operations = await calls.values()
        XCTAssertEqual(operations,[1],"Both publication checkpoints reuse the prepared extraction and never reinstall")
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
    func testPublishedCopyReusesRoleExtractionWithoutTrustingWorkingPath() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let staged = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let first = try await bridge.extractRoles(snapshot: staged)
        let publishedURL = f.directory.appendingPathComponent("published.psd")
        try FileManager.default.copyItem(at: f.document,to: publishedURL)
        try FileManager.default.copyItem(at: f.document.appendingPathExtension("workflow-owner.json"),to: publishedURL.appendingPathExtension("workflow-owner.json"))
        let reopened = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let published = try await reopened.refreshSavedPSD(document: publishedURL,owner: f.owner)
        let second = try await reopened.extractRoles(snapshot: published)
        XCTAssertNotEqual(staged,published,"Global snapshot identity still includes the working path")
        XCTAssertEqual(first,second,"Publication must reuse the same verified role files")
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,1)
        // A cache hit must still inspect and hash the current published document.
        try Data("changed-published-psd".utf8).write(to: publishedURL)
        await rejects { _ = try await reopened.extractRoles(snapshot: published) }
        XCTAssertEqual(try Data(contentsOf: f.document),Data("saved-role-psd".utf8))
    }
    func testRoleReuseRejectsChangedOwnerRolesAndImmutableSnapshot() async throws {
        let f = try roleCacheFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let bridge = PhotoshopWorkflowBridge(workspace: f.directory,scriptRunner: f.runner)
        let saved = try await bridge.refreshSavedPSD(document: f.document,owner: f.owner)
        let receipt = f.directory.appendingPathComponent("role-cache/\(f.owner)/\(saved.contentVersion).json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String:Any])
        // A readable receipt from a different extraction identity must never be accepted.
        var variants: [PSDSnapshot] = []
        var changed = saved; changed.taskID = UUID(); variants.append(changed)
        changed = saved; changed.contentVersion = "other-version"; variants.append(changed)
        changed = saved; changed.snapshotURL = f.directory.appendingPathComponent("other.psd"); variants.append(changed)
        changed = saved; changed.pixelSize.width += 1; variants.append(changed)
        changed = saved; changed.roles?.baseLayer = "99"; variants.append(changed)
        changed = saved; changed.structureSummary = "other-structure"; variants.append(changed)
        for variant in variants {
            var mismatched = original
            mismatched["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(variant))
            try JSONSerialization.data(withJSONObject: mismatched).write(to: receipt)
            let extracted = try await bridge.extractRoles(snapshot: saved)
            XCTAssertEqual(extracted.snapshotVersion,saved.contentVersion)
        }
        let extractions = await f.calls.values(); XCTAssertEqual(extractions.count,7)
        // Identical PSD bytes and a copied receipt do not authorize a different owner.
        var foreign = saved; foreign.taskID = UUID()
        await rejects { _ = try await bridge.extractRoles(snapshot: foreign) }
        for variant in variants.dropFirst(3) {
            await rejects { _ = try await bridge.extractRoles(snapshot: variant) }
        }
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath: saved.snapshotURL.path)
        try Data("changed-immutable-copy".utf8).write(to: saved.snapshotURL)
        await rejects { _ = try await bridge.extractRoles(snapshot: saved) }
        let finalExtractions = await f.calls.values(); XCTAssertEqual(finalExtractions.count,7)
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
    // Exercise only disposable PSD copies; the supplied batch and its original assets remain read-only.
    func testRealPublishedCopyRoleReuseWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let batchPath = environment["WORKFLOW_ROLE_PUBLICATION_BATCH"],
              let evidencePath = environment["WORKFLOW_ROLE_PUBLICATION_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop publication reuse verification is opt-in")
        }
        let batch = try JSONDecoder().decode(WorkflowBatch.self,from: Data(contentsOf: URL(fileURLWithPath: batchPath)))
        let evidence = URL(fileURLWithPath: evidencePath)
        for repetition in 1...3 {
            for task in batch.activeTasks {
                let source = try XCTUnwrap(task.snapshot)
                let folder = evidence.appendingPathComponent("run-\(repetition)/\(source.workingURL.deletingPathExtension().lastPathComponent)")
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                let stagedURL = folder.appendingPathComponent("staged.psd"),publishedURL = folder.appendingPathComponent("published.psd")
                XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
                try FileManager.default.copyItem(at: source.snapshotURL,to: stagedURL)
                let ownership: [String:Any] = ["owner":source.taskID.uuidString,
                    "roles":try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(source.roles)))]
                let record = try JSONSerialization.data(withJSONObject: ownership)
                try record.write(to: stagedURL.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
                let calls = Gate()
                let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                    if script.contains("wfRolePNG(copy,") { await calls.append(1) }
                    return try await PhotoshopWorkflowBridge.execute(script)
                }
                let bridge = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                let started = Date()
                let staged = try await bridge.refreshSavedPSD(document: stagedURL,owner: source.taskID)
                let first = try await bridge.extractRoles(snapshot: staged)
                let firstSeconds = Date().timeIntervalSince(started)
                try FileManager.default.copyItem(at: stagedURL,to: publishedURL)
                try record.write(to: publishedURL.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
                let publishedStart = Date()
                let reopened = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                let published = try await reopened.refreshSavedPSD(document: publishedURL,owner: source.taskID)
                let second = try await reopened.extractRoles(snapshot: published)
                let publishedSeconds = Date().timeIntervalSince(publishedStart)
                let count = await calls.values().count
                try JSONEncoder().encode(first).write(to: folder.appendingPathComponent("staged-roles.json"))
                try JSONEncoder().encode(second).write(to: folder.appendingPathComponent("published-roles.json"))
                let summary: [String:Any] = ["firstRefreshAndExtractSeconds":firstSeconds,
                    "publishedRefreshAndExtractSeconds":publishedSeconds,"roleExtractions":count,
                    "sourceVersion":source.contentVersion]
                try JSONSerialization.data(withJSONObject: summary,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
                XCTAssertEqual(count,1)
                XCTAssertEqual(first,second)
                XCTAssertEqual(try AIFileValidation.hash(source.snapshotURL.path),source.contentVersion)
                XCTAssertEqual(try AIFileValidation.hash(publishedURL.path),source.contentVersion)
            }
        }
    }
    // Opt-in: un-matted stacks, including a soft-alpha foreground over a blue preview-only layer.
    func testRealStackInputFastPNGPreservesPixelsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let evidencePath = environment["WORKFLOW_PNG_EVIDENCE"] else {
            throw XCTSkip("Real Photoshop stack PNG verification is opt-in")
        }
        let evidence = URL(fileURLWithPath: evidencePath)
        let python = try XCTUnwrap(environment["WORKFLOW_PNG_PYTHON"],"Set WORKFLOW_PNG_PYTHON to the AI project's Python with Pillow")
        try FileManager.default.createDirectory(at: evidence,withIntermediateDirectories: true)
        func quoted(_ url: URL) throws -> String { String(decoding: try JSONEncoder().encode(url.path),as: UTF8.self) }
        let foreground = evidence.appendingPathComponent("soft-alpha.png")
        try png(foreground,width:5,height:1,pixels:[12,34,56,0,23,45,67,1,99,88,77,64,90,80,70,128,255,128,1,255])
        var fixtures: [(String,URL)] = []
        for (label,bits,srgb) in [("srgb-8",8,true),("adobe-8",8,false),("srgb-16",16,true)] {
            let document = evidence.appendingPathComponent("soft-alpha-\(label).psd")
            _ = try await PhotoshopWorkflowBridge.execute("""
                (function(){
                    var doc=app.open(new File(\(try quoted(foreground))));
                    try {
                        if(\(srgb ? "true" : "false"))doc.convertProfile('sRGB IEC61966-2.1',Intent.RELATIVECOLORIMETRIC,true,false);
                        if(\(bits)===16)doc.bitsPerChannel=BitsPerChannelType.SIXTEEN;
                        var subject=doc.activeLayer,blue=doc.artLayers.add();blue.name='Background #74BFFF';
                        var color=new SolidColor();color.rgb.red=116;color.rgb.green=191;color.rgb.blue=255;
                        doc.selection.selectAll();doc.selection.fill(color);doc.selection.deselect();
                        blue.move(subject,ElementPlacement.PLACEAFTER);blue.visible=true;
                        var options=new PhotoshopSaveOptions();options.layers=true;options.embedColorProfile=true;
                        doc.saveAs(new File(\(try quoted(document))),options,true,Extension.LOWERCASE);
                        return 'created';
                    }finally{doc.close(SaveOptions.DONOTSAVECHANGES);}
                }());
                """)
            fixtures.append(("soft-alpha-\(label)",document))
        }
        if let fixturePath = environment["WORKFLOW_STACK_FIXTURES"] {
            let records = try JSONDecoder().decode([[String:String]].self,from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
            for record in records {
                fixtures.append((try XCTUnwrap(record["name"]),URL(fileURLWithPath: try XCTUnwrap(record["source"]))))
            }
        }
        for (name,source) in fixtures {
            let sourceHash = try AIFileValidation.hash(source.path)
            let folder = evidence.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            let document = folder.appendingPathComponent("stack.psd"),owner = UUID()
            try FileManager.default.copyItem(at: source,to: document)
            try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"),options: .withoutOverwriting)
            let bridge = PhotoshopWorkflowBridge(workspace: folder,coordinator: PhotoshopExecutionCoordinator())
            let snapshot = try await bridge.refreshSavedPSD(document: document,owner: owner)
            XCTAssertNil(snapshot.roles,"This fixture must be an un-matted stack, not extracted roles")
            for repetition in 1...3 {
                var results: [String:Any] = [:]
                // Alternate order to reduce warm-cache bias; both exports read the same immutable PSD.
                for mode in repetition.isMultiple(of:2) ? ["fast","legacy"] : ["legacy","fast"] {
                    let calls = Gate()
                    let runner: PhotoshopWorkflowBridge.ScriptRunner = { script in
                        var actual = script
                        if mode == "legacy" {
                            actual = actual.replacingOccurrences(of:"wfStackPNG(copy,",with:"wfPNG(copy,")
                        }
                        // Count executed encoders, including the fast helper's mode/bit-depth fallback.
                        actual = "var wfQuickSaves=0,wfLegacySaves=0;\n" + actual
                            .replacingOccurrences(of:"function wfPNG(doc,path) {",with:"function wfPNG(doc,path) {wfLegacySaves++;")
                            .replacingOccurrences(of:"executeAction(s('save'),d,DialogModes.NO);",with:"wfQuickSaves++;executeAction(s('save'),d,DialogModes.NO);")
                            .replacingOccurrences(of:"\n(function(){",with:"\nvar wfEncodedResult=(function(){")
                        actual += "\nvar wfMeasured=eval('('+wfEncodedResult+')');wfMeasured.quickSaves=wfQuickSaves;wfMeasured.legacySaves=wfLegacySaves;wfJSON(wfMeasured);"
                        try actual.write(to:folder.appendingPathComponent("\(mode)-script.jsx"),atomically:true,encoding:.utf8)
                        let result: String
                        do { result = try await PhotoshopWorkflowBridge.execute(actual) }
                        catch { XCTFail("Photoshop \(name) \(mode): \(error)"); throw error }
                        try result.write(to:folder.appendingPathComponent("\(mode)-metadata.json"),atomically:true,encoding:.utf8)
                        let measured = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String:Any]
                        for _ in 0..<(measured?["quickSaves"] as? Int ?? 0) { await calls.append(1) }
                        for _ in 0..<(measured?["legacySaves"] as? Int ?? 0) { await calls.append(2) }
                        return result
                    }
                    let exporter = PhotoshopWorkflowBridge(workspace: folder,scriptRunner: runner)
                    let started = Date()
                    let exported = try await exporter.exportStackPNG(snapshot: snapshot)
                    let elapsed = Date().timeIntervalSince(started)
                    let encoders = await calls.values()
                    let usesQuick = mode == "fast" && name != "soft-alpha-adobe-8" && name != "soft-alpha-srgb-16"
                    XCTAssertEqual(encoders,[usesQuick ? 1 : 2],"sRGB/8-bit uses quick PNG; non-sRGB and 16-bit retain Save for Web")
                    let bytes = try Data(contentsOf: exported.pngURL).count
                    results[mode] = ["png":exported.pngURL.path,"seconds":elapsed,"bytes":bytes,
                                     "orientation":exported.orientation,"encoders":encoders]
                }
                let legacy = try XCTUnwrap(results["legacy"] as? [String:Any])
                let fast = try XCTUnwrap(results["fast"] as? [String:Any])
                let expected = try WorkflowRaster.read(URL(fileURLWithPath: XCTUnwrap(legacy["png"] as? String)))
                let actual = try WorkflowRaster.read(URL(fileURLWithPath: XCTUnwrap(fast["png"] as? String)))
                XCTAssertEqual(actual.size,expected.size)
                XCTAssertEqual(actual.orientation,expected.orientation)
                XCTAssertEqual(actual.profileData,expected.profileData)
                XCTAssertTrue(actual.pixels == expected.pixels)
                if name.hasPrefix("soft-alpha-") {
                    XCTAssertEqual(stride(from:3,to:actual.pixels.count,by:4).map { actual.pixels[$0] },[0,1,64,128,255],"Preview blue must be hidden; soft alpha must survive")
                }
                // Raw, unpremultiplied RGBA and all color chunks are additionally compared from these files.
                try JSONSerialization.data(withJSONObject: results,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("run-\(repetition).json"))
            }
            XCTAssertEqual(try AIFileValidation.hash(source.path),sourceHash)
            XCTAssertEqual(try AIFileValidation.hash(document.path),sourceHash)
        }
        let verifier = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/verify_workflow_png_pairs.py")
        let process = Process(),output = Pipe()
        process.executableURL = URL(fileURLWithPath:python)
        process.arguments = ["-B",verifier.path,evidence.path]
        process.standardOutput = output
        try process.run()
        let rawComparison = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try rawComparison.write(to:evidence.appendingPathComponent("raw-pixel-comparison.json"))
        XCTAssertEqual(process.terminationStatus,0,"Raw RGBA / ICC / color chunks differ: \(String(decoding:rawComparison,as:UTF8.self))")
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
