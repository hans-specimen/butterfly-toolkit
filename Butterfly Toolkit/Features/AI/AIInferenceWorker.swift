// 负责照片工作流的常驻 AI 推理会话，以先进先出队列复用子进程，并校验请求身份、输出路径和取消清理。

import Foundation
import Darwin

// MARK: - 推理请求

nonisolated struct WorkflowInferenceRequest: Sendable {
    let engine: URL
    let workspace: URL
    let input: URL
    let device: String
}

// MARK: - 会话队列与生命周期

/// 批次会话显式按先进先出顺序占用连接；仅靠 actor 隔离无法阻止等待期间的重入推理。
actor AIInferenceWorker {
    private struct Job {
        let id: UUID
        let request: WorkflowInferenceRequest
        let result: CheckedContinuation<AIEvent,Error>
    }
    private var queue: [Job] = []
    private var active: Job?
    private var connection: AIWorkerConnection?
    private var runner: Task<Void,Never>?
    private var stopping = false
    private var shutdownTask: Task<Void,Never>?
    private var sessionFailure: Error?
    var queuedCount: Int { queue.count }

    func infer(_ request: WorkflowInferenceRequest) async throws -> AIEvent {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let sessionFailure { throw sessionFailure }
            guard !stopping else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { result in
                queue.append(Job(id: id,request: request,result: result))
                if runner == nil { runner = Task { await self.drain() } }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    // 并发关闭共用同一清理任务，等待当前请求结束后再释放连接。
    func shutdown() async {
        if let pending = shutdownTask { await pending.value; return }
        stopping = true
        failQueued(CancellationError())
        connection?.cancel()
        let running = runner
        let pending = Task { [self] in
            await running?.value
            if let current = connection { await Task.detached { current.finish() }.value }
            connection = nil; sessionFailure = nil; stopping = false; shutdownTask = nil
        }
        shutdownTask = pending
        await pending.value
    }
    private func cancel(_ id: UUID) async {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).result.resume(throwing: CancellationError())
        } else if active?.id == id { await shutdown() }
    }
    private func failQueued(_ error: Error) {
        let waiting = queue; queue.removeAll()
        for job in waiting { job.result.resume(throwing: error) }
    }
    private func drain() async {
        defer { runner = nil }
        while !queue.isEmpty && !stopping {
            let job = queue.removeFirst(); active = job
            do {
                if connection == nil { connection = try AIWorkerConnection(request: job.request) }
                let current = connection!
                let event = try await Task.detached(priority: .userInitiated) { try current.exchange(job.request,id: job.id) }.value
                if stopping { throw CancellationError() }
                job.result.resume(returning: event)
            } catch {
                if stopping {
                    if let current = connection { await Task.detached { current.finish() }.value }
                    connection = nil; active = nil
                    job.result.resume(throwing: CancellationError()); return
                }
                // 单个请求失败仍可复用连接；进程或协议失败则使整个会话失效。
                if error is AIWorkerRequestError { job.result.resume(throwing: error) }
                else {
                    // 保留失败状态直到会话所有者关闭，防止下一个自动处理的标本面擅自重启会话。
                    sessionFailure = error; stopping = true; failQueued(error)
                    if let current = connection { current.cancel(); await Task.detached { current.finish() }.value }
                    connection = nil; stopping = false; active = nil
                    job.result.resume(throwing: error); return
                }
            }
            active = nil
        }
    }
}

private nonisolated struct AIWorkerRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 常驻进程连接与协议

/// 每次只执行一个阻塞交互，且始终在独立任务中运行；只有取消允许并发调用。
private nonisolated final class AIWorkerConnection: @unchecked Sendable {
    private struct Envelope: Decodable {
        let event: String
        let requestID: String?
        let version: Int?
        enum CodingKeys: String,CodingKey { case event,requestID; case version = "protocol" }
    }
    private let identity: WorkflowInferenceRequest
    private let child = Process()
    private let input = Pipe(),output = Pipe()
    private let logURL: URL
    private let log: FileHandle
    private let lock = NSLock()
    private let exited = DispatchGroup()
    private var cancelled = false
    private var started = false
    private var ready = false
    private var buffer = Data()

    init(request: WorkflowInferenceRequest) throws {
        identity = request
        let python = request.engine.appendingPathComponent(".venv/bin/python")
        let script = request.engine.appendingPathComponent("scripts/toolkit_bridge.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),FileManager.default.fileExists(atPath: script.path),
              ["mps","cpu"].contains(request.device) else { throw AIWorkspaceError(message: "AI 项目环境或设备配置无效。") }
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("butterfly-worker-\(UUID()).log")
        FileManager.default.createFile(atPath: logURL.path,contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        child.executableURL = python; child.currentDirectoryURL = request.engine
        child.arguments = ["-u","-B",script.path,"--workspace",request.workspace.path,"serve","--device",request.device]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        child.terminationHandler = { [exited] _ in exited.leave() }
        child.standardInput = input; child.standardOutput = output; child.standardError = log
        // 子进程退出后写入应返回错误，不能通过 SIGPIPE 终止应用。
        _ = fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
    }
    func cancel() {
        lock.lock(); cancelled = true
        let running = started && child.isRunning
        if running { child.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now()+1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if child.isRunning { kill(child.processIdentifier,SIGKILL) }
            }
        }
    }
    func finish() {
        cancel()
        // 启动与清理可能位于不同线程；等待退出通知，避免依赖启动线程的运行循环。
        if started { exited.wait() }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        try? log.close(); try? FileManager.default.removeItem(at: logURL)
    }
    private func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if !started {
            exited.enter()
            do { try child.run(); started = true }
            catch { exited.leave(); throw error }
        }
    }
    // MARK: - 请求交换与响应校验

    func exchange(_ request: WorkflowInferenceRequest,id: UUID) throws -> AIEvent {
        guard request.engine.standardizedFileURL == identity.engine.standardizedFileURL,
              request.workspace.standardizedFileURL == identity.workspace.standardizedFileURL,request.device == identity.device else {
            throw AIWorkerRequestError(message: "AI 会话不能切换引擎、工作目录或设备，请先关闭会话。")
        }
        try launch()
        // 首次请求先校验协议版本，后续响应必须携带当前请求的标识。
        if !ready {
            let data = try line(),envelope = try JSONDecoder().decode(Envelope.self,from: data)
            guard envelope.event == "ready",envelope.version == 1,envelope.requestID == nil else { throw protocolError() }
            ready = true
        }
        let payload = try JSONSerialization.data(withJSONObject: ["requestID":id.uuidString,"input":request.input.path])
        try input.fileHandleForWriting.write(contentsOf: payload+Data([10]))
        while true {
            let data = try line(),envelope = try JSONDecoder().decode(Envelope.self,from: data)
            guard envelope.requestID == id.uuidString else { throw protocolError() }
            let event = try JSONDecoder().decode(AIEvent.self,from: data)
            switch event.event {
            case "status": continue
            case "error": throw AIWorkerRequestError(message: event.message ?? "AI 推理失败。")
            case "completed":
                guard event.input.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath() }) == request.input.resolvingSymlinksInPath(),
                      let directory = event.outputDirectory,let prediction = event.prediction,let alpha = event.predictionAlpha else { throw protocolError() }
                // 解析符号链接后限制输出归属，防止接受其他输入或工作目录之外的结果。
                let root = request.workspace.resolvingSymlinksInPath().appendingPathComponent("outputs").path+"/"
                let folder = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
                guard folder.path.hasPrefix(root),[prediction,alpha].allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().path == folder.path }) else { throw protocolError() }
                return event
            default: throw protocolError()
            }
        }
    }
    // 限制单行事件大小，避免异常子进程输出无限累积在内存中。
    private func line() throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let result = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard !result.isEmpty,result.count <= 1_048_576 else { throw protocolError() }; return result
            }
            guard buffer.count <= 1_048_576 else { throw protocolError() }
            let bytes = output.fileHandleForReading.availableData
            guard !bytes.isEmpty else {
                let diagnostic = ((try? String(contentsOf: logURL,encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: "\n")
                throw AIWorkspaceError(message: "AI worker 已退出或输出中断；请重试失败项。\n"+diagnostic)
            }
            buffer.append(bytes)
        }
    }
    private func protocolError() -> AIWorkspaceError { AIWorkspaceError(message: "AI worker 协议或输入身份不匹配，已停止本次队列。") }
}
