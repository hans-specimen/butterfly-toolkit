import Foundation

/// One child per operation; all blocking reads stay off the UI actor.
nonisolated final class AIProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func run(engine: URL, arguments: [String], workspace: URL? = nil, onEvent: @escaping @Sendable (AIEvent) async -> Void) async throws -> AIEvent {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try await execute(engine: engine, arguments: (workspace.map { ["--workspace", $0.path] } ?? []) + arguments, onEvent: onEvent)
            }.value
        } onCancel: { self.cancel() }
    }

    private func execute(engine: URL, arguments: [String], onEvent: @escaping @Sendable (AIEvent) async -> Void) async throws -> AIEvent {
        let python = engine.appendingPathComponent(".venv/bin/python")
        let script = engine.appendingPathComponent("scripts/toolkit_bridge.py")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) else {
            throw AIWorkspaceError(message: "所选文件夹缺少 AI 连接脚本或项目 Python 环境。请选择已配置好的 butterfly-ai 项目文件夹。")
        }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-u", "-B", script.path] + arguments
        child.currentDirectoryURL = engine
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        // A file avoids a stderr pipe filling up while stdout is being read.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("butterfly-ai-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        child.standardError = log
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        try launch(child)
        defer { clearProcess() }
        var pending = Data()
        var last: AIEvent?
        var failure: String?
        func consume(_ line: Data) async {
            guard !line.isEmpty, let event = try? JSONDecoder().decode(AIEvent.self, from: line) else { return }
            if event.event == "error" { failure = event.message }
            if ["completed", "catalog", "imported"].contains(event.event) { last = event }
            await onEvent(event)
        }
        while true {
            let bytes = output.fileHandleForReading.availableData
            if bytes.isEmpty { break }
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                await consume(line)
            }
        }
        await consume(pending)
        child.waitUntilExit()
        if isCancelled() { throw CancellationError() }
        guard child.terminationStatus == 0, let last else {
            let diagnostic = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let tail = diagnostic.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw AIWorkspaceError(message: failure ?? "AI 处理未完成（退出码 \(child.terminationStatus)）。\(tail.isEmpty ? "请检查项目环境与输入文件。" : "\n" + tail)")
        }
        return last
    }

    private func launch(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try child.run()
        process = child
    }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func clearProcess() { lock.lock(); process = nil; lock.unlock() }
}
