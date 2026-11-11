// 旧外部 AI 调度计时已退役。保留隔离证据目录和素材复制检查，供其他真实环境测试使用。
import XCTest
@testable import Butterfly_Toolkit

@MainActor final class WorkflowPipelinePerformanceTests: XCTestCase {
    static func copyFixture(_ source: URL, to destination: URL, in root: URL) throws {
        let resolved = source.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try isolatedEvidenceRoot(destination.path).path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw WorkflowBridgeError.ownershipConflict
        }
        try FileManager.default.copyItem(at: resolved, to: destination)
        guard destination.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw WorkflowBridgeError.ownershipConflict
        }
    }
    func testFixtureSymlinksCopyContentsWithoutChangingTheirTargets() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("isolated"), original = base.appendingPathComponent("original.psd")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: original)
        let link = base.appendingPathComponent("link.psd"), copy = root.appendingPathComponent("copy.psd")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        try Self.copyFixture(link, to: copy, in: root)
        XCTAssertFalse(try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        try Data("copy".utf8).write(to: copy)
        XCTAssertEqual(try Data(contentsOf: original), Data("source".utf8))
        XCTAssertThrowsError(try Self.copyFixture(original, to: base.appendingPathComponent("outside.psd"), in: root))
    }
    static func isolatedEvidenceRoot(_ path: String) throws -> URL {
        // Resolve the existing ancestor first: Foundation may leave a nonexistent leaf's symlink parents unresolved.
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw WorkflowBridgeError.ownershipConflict }
            suffix.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
        }
        let root = suffix.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        let allowed = [URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory].map { $0.resolvingSymlinksInPath().path }
        guard allowed.contains(where: { root.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
            throw WorkflowBridgeError.ownershipConflict
        }
        return root
    }
    func testEvidenceRejectsEscapesAndSymlinksBeforeWriting() throws {
        XCTAssertThrowsError(try Self.isolatedEvidenceRoot("/Users/hans/Developer/tmp/never-write"))
        XCTAssertThrowsError(try Self.isolatedEvidenceRoot("/tmp/../Users/hans/never-write"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: URL(fileURLWithPath: "/Users/hans"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertThrowsError(try Self.isolatedEvidenceRoot(temporary.appendingPathComponent("never-write").path))
        XCTAssertNoThrow(try Self.isolatedEvidenceRoot("/tmp/new-workflow-fixture"))
    }

}
