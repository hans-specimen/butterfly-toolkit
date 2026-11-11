import XCTest
import JavaScriptCore
import ImageIO
import UniformTypeIdentifiers
@testable import Butterfly_Toolkit

private nonisolated final class PreparationMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    private var times: [Double] = []
    private var operations: [WorkflowPerformanceSample] = []
    func append(_ seconds: Double) { lock.withLock { times.append(seconds) } }
    func observe(_ sample: WorkflowPerformanceSample) { lock.withLock { operations.append(sample) } }
    func values() -> [Double] { lock.withLock { times } }
    func samples() -> [WorkflowPerformanceSample] { lock.withLock { operations } }
}

@MainActor final class WorkflowStackPreparationTests: XCTestCase {
    func testStackExportRunsAfterSaveBeforeClose() throws {
        let job = FocusStackJob(id: 0, sourceFiles: [], destinationURL: URL(fileURLWithPath: "/tmp/unused.psd"), butterflyName: "test", side: "D")
        for hook in [nil, "events.push('png');", "events.push('png');throw new Error('PNG failed');"] as [String?] {
            let script = FocusStackProcessor.jsx(for: job, workflowPNGExportScript: hook)
            let start = try XCTUnwrap(script.range(of: "var psdOptions ="))
            let end = try XCTUnwrap(script.range(of: "} catch (error)", range: start.upperBound..<script.endIndex))
            let tail = String(script[start.lowerBound..<end.lowerBound])
            let context = JSContext()!
            context.evaluateScript("var events=[],destination='test',Extension={LOWERCASE:0},SaveOptions={DONOTSAVECHANGES:0};function File(x){};function PhotoshopSaveOptions(){};var stackDocument={saveAs:function(){events.push('save');},close:function(){events.push('close');}};")
            context.evaluateScript("(function(){" + tail + "}());")
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.objectForKeyedSubscript("events")?.toArray() as? [String], hook == nil ? ["save","close"] : ["save","png","close"])
            context.evaluateScript("events=[];stackDocument.saveAs=function(){throw new Error('PSD failed');};")
            context.evaluateScript("(function(){" + tail + "}());")
            XCTAssertNotNil(context.exception, "PSD failure must not become optional")
            XCTAssertEqual(context.objectForKeyedSubscript("events")?.toArray() as? [String], [])
        }
    }

    private nonisolated static func png(_ url: URL, opaque: Bool = false) throws {
        var pixels: [UInt8] = [12,34,56,0,23,45,67,1,99,88,77,64,90,80,70,128,255,128,1,255]
        if opaque { for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 } }
        let image = CGImage(width: 5, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 20,
            space: CGColorSpace(name: CGColorSpace.adobeRGB1998)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkflowBridgeError.invalidImage("fixture PNG") }
    }
    private nonisolated static func candidatePath(_ script: String) throws -> URL {
        let regex = try NSRegularExpression(pattern: #"wfStackPNG\(copy,("[^"]+")\)"#)
        let match = try XCTUnwrap(regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: script))
        return try URL(fileURLWithPath: JSONDecoder().decode(String.self, from: Data(script[range].utf8)))
    }
    func testPNGFailureKeepsPublishedStack() async throws {
        for mode in ["valid", "transparent", "missing", "corrupt", "publication-conflict"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), owner = UUID()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sources = try (0..<3).map { i in let p = root.appendingPathComponent("\(i).jpg"); try Data("source".utf8).write(to: p); return p }
            let destination = root.appendingPathComponent("result.psd")
            let bridge = PhotoshopWorkflowBridge(workspace: root, coordinator: PhotoshopExecutionCoordinator(), scriptRunner: { _ in
                #"{"width":5,"height":1,"profile":"sRGB","summary":"layers"}"#
            }, stackProcessor: { job, hook in
                try Data("saved layered PSD".utf8).write(to: job.destinationURL)
                let png = try Self.candidatePath(XCTUnwrap(hook))
                if ["valid", "transparent", "publication-conflict"].contains(mode) { try Self.png(png, opaque: mode == "valid") }
                if mode == "corrupt" { try Data("broken".utf8).write(to: png) }
                if mode == "publication-conflict" { try Data("foreign".utf8).write(to: destination) }
            })
            let job = FocusStackJob(id: 0, sourceFiles: sources, destinationURL: destination, butterflyName: "test", side: "D")
            if mode == "publication-conflict" {
                do { _ = try await bridge.stackWithInput(job: job, owner: owner); XCTFail("Adopted foreign PSD") } catch {}
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "foreign")
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/processed").path))
                continue
            }
            let result = try await bridge.stackWithInput(job: job, owner: owner)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "saved layered PSD")
            XCTAssertEqual(result.input != nil, mode == "valid")
            if let input = result.input {
                XCTAssertEqual(input.snapshotVersion, result.snapshot.contentVersion)
                XCTAssertEqual(input.fingerprint, try AIFileValidation.hash(input.pngURL.path))
                let valid = try await bridge.validateStackInput(snapshot: result.snapshot, input: input); XCTAssertTrue(valid)
                try Data("changed PNG".utf8).write(to: input.pngURL)
                let changed = try await bridge.validateStackInput(snapshot: result.snapshot, input: input); XCTAssertFalse(changed)
                try Data("edited PSD".utf8).write(to: destination)
                do { _ = try await bridge.validateStackInput(snapshot: result.snapshot, input: input); XCTFail("Edited PSD accepted") }
                catch WorkflowBridgeError.staleSource {}
            }
        }
    }
    func testRetainedTransparentCandidateFallsBackWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["WORKFLOW_STACK_PREP_REPLAY"] else { throw XCTSkip("Retained real input replay is opt-in") }
        let evidence = try WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(XCTUnwrap(env["WORKFLOW_STACK_PREP_EVIDENCE"]))
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw WorkflowBridgeError.ownershipConflict }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: source), folder = evidence.appendingPathComponent("retained-22_V")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pair = try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("run-1.json"))) as! [String: Any]
        let candidate = URL(fileURLWithPath: (pair["fast"] as! [String: Any])["png"] as! String)
        let expected = URL(fileURLWithPath: (pair["legacy"] as! [String: Any])["png"] as! String)
        var sources: [URL] = []
        for index in 0..<3 {
            let destination = folder.appendingPathComponent("\(index).jpg")
            try WorkflowPipelinePerformanceTests.copyFixture(original.appendingPathComponent("\(index).jpg"), to: destination, in: evidence)
            sources.append(destination)
        }
        let calls = PreparationMeasurements()
        let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), stackProcessor: { job, hook in
            _ = calls.next()
            // Replay the exact saved PSD and failed candidate; do not synthesize a different stack.
            try FileManager.default.copyItem(at: original.appendingPathComponent("stack.psd"), to: job.destinationURL)
            try FileManager.default.copyItem(at: candidate, to: Self.candidatePath(XCTUnwrap(hook)))
        })
        let result = try await bridge.stackWithInput(job: FocusStackJob(id: 0, sourceFiles: sources, destinationURL: folder.appendingPathComponent("stack.psd"), butterflyName: "retained", side: "V"), owner: UUID())
        XCTAssertNil(result.input, "Transparent candidate must not be adopted even though dimensions/ICC match")
        let input = try await bridge.exportStackPNG(snapshot: result.snapshot)
        let record: [String: Any] = ["legacy": ["png": expected.path], "fast": ["png": input.pngURL.path]]
        try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("run-1.json"))
        XCTAssertEqual(calls.next(), 2, "Only one replay; PNG fallback must not call the stack processor")
        let verifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/verify_workflow_png_pairs.py")
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: try XCTUnwrap(env["WORKFLOW_PNG_PYTHON"]))
        process.arguments = [verifier.path, evidence.path]; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try output.write(to: evidence.appendingPathComponent("raw-pixel-comparison.json"))
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }
    func testFusedStackPNGMatchesReopenedExportWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WORKFLOW_STACK_PREP_EVIDENCE"] else { throw XCTSkip("Real Photoshop input equivalence is opt-in") }
        let root = try WorkflowPipelinePerformanceTests.isolatedEvidenceRoot(path), fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw WorkflowBridgeError.ownershipConflict }
        let reference = try JSONDecoder().decode(WorkflowBatch.self, from: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["WORKFLOW_STACK_PREP_BATCH"]))))
        try reference.validate()
        let python = try XCTUnwrap(env["WORKFLOW_PNG_PYTHON"])
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func quote(_ url: URL) throws -> String { String(decoding: try JSONEncoder().encode(url.path), as: UTF8.self) }
        func record(_ folder: URL, _ prepared: StackPNG, _ reopened: StackPNG, _ seconds: [String: Double], _ samples: [WorkflowPerformanceSample], preparedInputUsed: Bool? = nil) throws {
            var pair: [String: Any] = ["legacy": ["png": reopened.pngURL.path], "fast": ["png": prepared.pngURL.path], "seconds": seconds]
            pair["comparisonPath"] = preparedInputUsed.map { $0 ? "accepted-prepared-input" : "reopened-fallback" } ?? "direct-export-diagnostic"
            try JSONSerialization.data(withJSONObject: pair, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("run-1.json"))
            try JSONEncoder().encode(samples).write(to: folder.appendingPathComponent("operations.json"))
        }
        // Four real stacks, one synthesis each. Both exports come from that same saved PSD.
        let specimens = Array(reference.specimens.prefix(2)); XCTAssertEqual(specimens.count, 2)
        for specimen in specimens {
            for task in [specimen.front, specimen.back] {
                let folder = root.appendingPathComponent(specimen.baseName + "_" + task.side.fileSuffix), owner = UUID(), times = PreparationMeasurements()
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var sources: [URL] = []
                for (index, source) in task.sources.files.enumerated() {
                    let copy = folder.appendingPathComponent("\(index).jpg")
                    try WorkflowPipelinePerformanceTests.copyFixture(source.url, to: copy, in: root)
                    XCTAssertEqual(try AIFileValidation.hash(copy.path), source.fingerprint)
                    sources.append(copy)
                }
                let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator(), performanceObserver: { times.observe($0) }, stackProcessor: { job, hook in
                    let hook = try XCTUnwrap(hook)
                    let timed = "var task2Start=new Date().getTime();" + hook + ";task2PNGSeconds=(new Date().getTime()-task2Start)/1000;"
                    let script = "var task2PNGSeconds=-1;" + FocusStackProcessor.jsx(for: job, workflowPNGExportScript: timed).replacingOccurrences(of: "#target photoshop", with: "") + "\nString(task2PNGSeconds);"
                    let result = try await PhotoshopWorkflowBridge.execute(script)
                    times.append(try XCTUnwrap(Double(result)))
                })
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await bridge.stackWithInput(job: FocusStackJob(id: 0, sourceFiles: sources, destinationURL: folder.appendingPathComponent("stack.psd"), butterflyName: specimen.baseName, side: task.side.fileSuffix), owner: owner)
                let total = ProcessInfo.processInfo.systemUptime - start
                let prepared: StackPNG
                if let input = result.input { prepared = input }
                else { prepared = try await bridge.exportStackPNG(snapshot: result.snapshot) }
                let fingerprint = try AIFileValidation.hash(result.snapshot.workingURL.path)
                let validationStart = ProcessInfo.processInfo.systemUptime
                let valid = try await bridge.validateStackInput(snapshot: result.snapshot, input: prepared); XCTAssertTrue(valid)
                let validation = ProcessInfo.processInfo.systemUptime - validationStart
                let reopenStart = ProcessInfo.processInfo.systemUptime
                let reopened = try await bridge.exportStackPNG(snapshot: result.snapshot)
                let reopenedSeconds = ProcessInfo.processInfo.systemUptime - reopenStart
                XCTAssertEqual(try AIFileValidation.hash(result.snapshot.workingURL.path), fingerprint)
                let refreshed = try await bridge.refreshSavedPSD(document: result.snapshot.workingURL, owner: owner)
                XCTAssertEqual(refreshed, result.snapshot, "Export must preserve layers, masks and saved content")
                let fusedSeconds = try XCTUnwrap(times.values().first); XCTAssertGreaterThanOrEqual(fusedSeconds, 0)
                try record(folder, prepared, reopened, ["stackWithInput": total, "fusedExportInsidePS": fusedSeconds, "validatePreparedInput": validation, "reopenedExportIncludingValidation": reopenedSeconds], times.samples(), preparedInputUsed: result.input != nil)
            }
        }
        let foreground = root.appendingPathComponent("soft-alpha.png"); try Self.png(foreground)
        for (name, bits, srgb) in [("srgb-8", 8, true), ("adobe-8", 8, false), ("srgb-16", 16, true)] {
            let folder = root.appendingPathComponent("soft-alpha-" + name), owner = UUID()
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let document = folder.appendingPathComponent("stack.psd"), fused = folder.appendingPathComponent("fused.png")
            let script = """
            (function(){var stackDocument=app.open(new File(\(try quote(foreground))));try{
                if(\(srgb ? "true" : "false"))stackDocument.convertProfile('sRGB IEC61966-2.1',Intent.RELATIVECOLORIMETRIC,true,false);
                if(\(bits)===16)stackDocument.bitsPerChannel=BitsPerChannelType.SIXTEEN;
                var subject=stackDocument.activeLayer,blue=stackDocument.artLayers.add();blue.name='Background #74BFFF';
                var color=new SolidColor();color.rgb.red=116;color.rgb.green=191;color.rgb.blue=255;
                stackDocument.selection.selectAll();stackDocument.selection.fill(color);stackDocument.selection.deselect();
                blue.move(subject,ElementPlacement.PLACEAFTER);blue.visible=true;
                var options=new PhotoshopSaveOptions();options.layers=true;options.embedColorProfile=true;options.maximizeCompatibility=true;
                stackDocument.saveAs(new File(\(try quote(document))),options,true,Extension.LOWERCASE);
                var started=new Date().getTime();
                (function(){\(PhotoshopWorkflowBridge.stackInputExportScript(output: fused))}());
                return String((new Date().getTime()-started)/1000);
            }finally{stackDocument.close(SaveOptions.DONOTSAVECHANGES);}}());
            """
            let response = try await PhotoshopWorkflowBridge.execute(script)
            let fusedSeconds = try XCTUnwrap(Double(response))
            let fingerprint = try AIFileValidation.hash(document.path)
            try JSONSerialization.data(withJSONObject: ["owner":owner.uuidString]).write(to: document.appendingPathExtension("workflow-owner.json"))
            let bridge = PhotoshopWorkflowBridge(workspace: folder, coordinator: PhotoshopExecutionCoordinator())
            let snapshot = try await bridge.refreshSavedPSD(document: document, owner: owner)
            let start = ProcessInfo.processInfo.systemUptime, reopened = try await bridge.exportStackPNG(snapshot: snapshot)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(try AIFileValidation.hash(document.path), fingerprint)
            let prepared = StackPNG(snapshotVersion: snapshot.contentVersion, pngURL: fused, fingerprint: try AIFileValidation.hash(fused.path), pixelSize: snapshot.pixelSize, orientation: 1, colorProfile: "fixture")
            try record(folder, prepared, reopened, ["fusedExportInsidePS": fusedSeconds, "reopenedExportIncludingValidation": seconds], [])
        }
        let verifier = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/verify_workflow_png_pairs.py")
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [verifier.path, root.path]; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try output.write(to: root.appendingPathComponent("raw-pixel-comparison.json"))
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }
}
