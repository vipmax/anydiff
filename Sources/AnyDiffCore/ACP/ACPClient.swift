import Foundation

public enum ACPLogger {
    private static let logURL = URL(fileURLWithPath: "/tmp/anydiff_acp.log")
    private static let lock = NSLock()

    public static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

public protocol ACPClientDelegate: AnyObject, Sendable {
    func client(_ client: ACPClient, didReceiveUpdate update: ACPSessionUpdateContent, sessionId: String)
    func client(_ client: ACPClient, didRequestPermission request: ACPRequestPermissionParams, requestId: JSONRPCID)
    func client(_ client: ACPClient, didLog message: String)
    func client(_ client: ACPClient, didExecuteTool toolName: String, path: String?, details: String?)
    func client(_ client: ACPClient, didExecuteFSWrite path: String, oldContent: String?, newContent: String)
    func client(_ client: ACPClient, didDisconnectWith error: String?)
}

public final class ACPClient: ACPTransportDelegate, @unchecked Sendable {
    public weak var delegate: ACPClientDelegate?

    private let transport: ACPTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let stateQueue = DispatchQueue(label: "com.anydiff.acp.client.state")
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: (Result<Data, JSONRPCError>) -> Void] = [:]
    private var activeTerminals: [String: ACPTerminalRunner] = [:]
    private let terminalsLock = NSLock()
    private var lastStderr: String = ""

    public private(set) var workingDirectory: String = ""
    public private(set) var activeSessionId: String? = nil

    public var isConnected: Bool {
        transport.isRunning
    }

    public init(transport: ACPTransport = ACPTransport()) {
        self.transport = transport
        self.transport.delegate = self
    }

    public func start(command: String, workingDirectory: String, environment: [String: String]? = nil) throws {
        self.workingDirectory = workingDirectory
        self.activeSessionId = nil
        try transport.launch(command: command, workingDirectory: workingDirectory, environment: environment)
    }

    public func stop() {
        let pending = stateQueue.sync { () -> [Int: (Result<Data, JSONRPCError>) -> Void] in
            let copy = pendingRequests
            pendingRequests.removeAll()
            activeSessionId = nil
            return copy
        }

        for (_, completion) in pending {
            completion(.failure(JSONRPCError(code: -1, message: "Client stopped")))
        }

        terminalsLock.lock()
        for (_, runner) in activeTerminals {
            runner.kill()
        }
        activeTerminals.removeAll()
        terminalsLock.unlock()

        transport.terminate()
    }

    // MARK: - High Level ACP Lifecycle

    public func initialize() async throws -> ACPInitializeResult {
        let params = ACPInitializeParams(
            protocolVersion: 1,
            capabilities: ACPClientCapabilities(
                fs: ACPClientCapabilities.FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true,
                session: ACPClientCapabilities.SessionCapabilities(
                    configOptions: ACPClientCapabilities.BooleanConfigOptionCapabilities()
                )
            ),
            clientInfo: ACPClientInfo(name: "AnyDiff", version: "1.0.0")
        )
        let responseData = try await sendRequest(method: "initialize", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPInitializeResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        guard let result = response.result else {
            throw JSONRPCError(code: -32603, message: "Missing initialize result in response")
        }
        return result
    }

    public func createSession(cwd: String) async throws -> String {
        self.workingDirectory = cwd
        let params = ACPSessionNewParams(cwd: cwd)
        let responseData = try await sendRequest(method: "session/new", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPSessionNewResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        guard let result = response.result else {
            throw JSONRPCError(code: -32603, message: "Missing result in session/new response")
        }
        self.activeSessionId = result.sessionId
        return result.sessionId
    }

    public func createSessionFull(cwd: String) async throws -> ACPSessionNewResult {
        self.workingDirectory = cwd
        let params = ACPSessionNewParams(cwd: cwd)
        let responseData = try await sendRequest(method: "session/new", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPSessionNewResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        guard let result = response.result else {
            throw JSONRPCError(code: -32603, message: "Missing result in session/new response")
        }
        self.activeSessionId = result.sessionId
        return result
    }

    public func listSessions(cwd: String) async throws -> [ACPSavedSessionItem] {
        try await listSessionsPage(cwd: cwd).sessions
    }

    public func listSessionsPage(cwd: String, cursor: String? = nil) async throws -> ACPSessionListResult {
        let params = ACPSessionListParams(cwd: cwd, cursor: cursor)
        let responseData = try await sendRequest(method: "session/list", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPSessionListResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        return response.result ?? ACPSessionListResult()
    }

    public func loadSession(sessionId: String, cwd: String) async throws -> ACPSessionLoadResult {
        self.workingDirectory = cwd
        self.activeSessionId = sessionId
        let params = ACPSessionLoadParams(sessionId: sessionId, cwd: cwd, mcpServers: [])
        let responseData = try await sendRequest(method: "session/load", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPSessionLoadResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        guard let result = response.result else {
            return ACPSessionLoadResult()
        }
        return result
    }

    public func setConfigOption(sessionId: String, configId: String, value: String) async throws -> [ACPConfigOption]? {
        let params = ACPSetConfigOptionParams(sessionId: sessionId, configId: configId, value: value)
        let responseData = try await sendRequest(method: "session/set_config_option", params: params)
        let response = try decoder.decode(JSONRPCResponse<ACPSetConfigOptionResult>.self, from: responseData)
        if let err = response.error {
            throw err
        }
        return response.result?.configOptions
    }

    public func sendPrompt(sessionId: String, prompt: [ACPSessionPromptParams.PromptItem]) async throws {
        let params = ACPSessionPromptParams(sessionId: sessionId, prompt: prompt)
        let _ = try await sendRequest(method: "session/prompt", params: params)
    }

    public func sendPrompt(sessionId: String, text: String, images: [AgentImageAttachment] = []) async throws {
        let params = ACPSessionPromptParams(sessionId: sessionId, text: text, images: images)
        let _ = try await sendRequest(method: "session/prompt", params: params)
    }

    public func cancelSession(sessionId: String) async throws {
        let params = ACPSessionCancelParams(sessionId: sessionId)
        // Session cancel can be sent as notification or request
        let notif = JSONRPCNotification(method: "session/cancel", params: params)
        if let data = try? encoder.encode(notif) {
            transport.sendLine(data)
        }
    }

    /// Completes an agent-originated `session/request_permission` request.
    /// The response must use the request's id; it is not a new client request.
    public func respondToPermission(requestId: JSONRPCID, optionId: String?) {
        let result = optionId.map(ACPRequestPermissionResult.selected) ?? ACPRequestPermissionResult.cancelled
        sendRawResponse(id: requestId, result: result)
    }

    // MARK: - Generic JSON-RPC Request/Response

    private func sendRequest<T: Codable & Sendable>(method: String, params: T?) async throws -> Data {
        let id: Int = stateQueue.sync {
            let current = nextRequestId
            nextRequestId &+= 1
            return current
        }

        let req = JSONRPCRequest(id: id, method: method, params: params)
        let data = try encoder.encode(req)

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync {
                pendingRequests[id] = { result in
                    switch result {
                    case .success(let resData):
                        continuation.resume(returning: resData)
                    case .failure(let err):
                        continuation.resume(throwing: err)
                    }
                }
            }

            transport.sendLine(data)
        }
    }

    private func sendRawResponse<T: Codable & Sendable>(id: JSONRPCID, result: T?) {
        let resp = JSONRPCAnyIDResponse(id: id, result: result)
        if let data = try? encoder.encode(resp) {
            let text = String(data: data, encoding: .utf8) ?? ""
            ACPLogger.log(">>> SEND RESPONSE: \(text)")
            transport.sendLine(data)
        }
    }

    private func sendRawError(id: JSONRPCID, error: JSONRPCError) {
        let resp = JSONRPCAnyIDResponse<String>(id: id, result: nil, error: error)
        if let data = try? encoder.encode(resp) {
            let text = String(data: data, encoding: .utf8) ?? ""
            ACPLogger.log(">>> SEND ERROR: \(text)")
            transport.sendLine(data)
        }
    }

    // MARK: - ACPTransportDelegate

    public func transport(_ transport: ACPTransport, didReceiveLine data: Data) {
        let text = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
        ACPLogger.log("<<< RECV: \(text)")

        guard let raw = try? decoder.decode(RawJSONRPCMessage.self, from: data) else {
            ACPLogger.log("    Failed to decode RawJSONRPCMessage!")
            return
        }

        // 1. If it's a response to a pending request (has id and NO method)
        if let id = raw.id, raw.method == nil {
            let completion: ((Result<Data, JSONRPCError>) -> Void)?
            if case .integer(let integerID) = id {
                completion = stateQueue.sync {
                    pendingRequests.removeValue(forKey: integerID)
                }
            } else {
                completion = nil
            }

            if let error = raw.error {
                completion?(.failure(error))
            } else {
                completion?(.success(data))
            }
            return
        }

        // 2. If it's a notification from the agent (no id, has method)
        if raw.id == nil, let method = raw.method {
            handleNotification(method: method, data: data)
            return
        }

        // 3. If it's a client-side request from the agent (has id AND method)
        if let id = raw.id, let method = raw.method {
            handleAgentRequest(id: id, method: method, data: data)
            return
        }
    }

    public func transport(_ transport: ACPTransport, didLogStderr text: String) {
        ACPLogger.log("--- STDERR: \(text)")
        stateQueue.sync {
            lastStderr += text
            if lastStderr.count > 500 {
                lastStderr = String(lastStderr.suffix(500))
            }
        }
        delegate?.client(self, didLog: text)
    }

    public func transport(_ transport: ACPTransport, didTerminateWith exitCode: Int32) {
        ACPLogger.log("--- TERMINATED: exitCode=\(exitCode)")
        let (pending, stderrText) = stateQueue.sync { () -> ([Int: (Result<Data, JSONRPCError>) -> Void], String) in
            let copy = pendingRequests
            pendingRequests.removeAll()
            let err = lastStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            lastStderr = ""
            return (copy, err)
        }

        let failureMsg: String
        if !stderrText.isEmpty {
            failureMsg = "Agent process exited with code \(exitCode): \(stderrText)"
        } else {
            failureMsg = "Agent process exited with code \(exitCode)"
        }

        for (_, completion) in pending {
            completion(.failure(JSONRPCError(code: -1, message: failureMsg)))
        }

        let message = exitCode == 0 ? "Process terminated cleanly" : failureMsg
        delegate?.client(self, didDisconnectWith: message)
    }

    // MARK: - Inbound Message Dispatching

    private func handleNotification(method: String, data: Data) {
        ACPLogger.log("--- NOTIFICATION: method=\(method)")
        if method == "session/update" {
            do {
                let notif = try decoder.decode(JSONRPCNotification<ACPSessionUpdateNotificationParams>.self, from: data)
                if let params = notif.params {
                    ACPLogger.log("    update.type=\(params.update.type ?? "nil"), toolName=\(params.update.toolName ?? "nil"), toolInput=\(String(describing: params.update.toolInput)), toolResult=\(params.update.toolResult ?? "nil")")
                    delegate?.client(self, didReceiveUpdate: params.update, sessionId: params.sessionId)
                } else {
                    ACPLogger.log("    params is nil in session/update!")
                }
            } catch {
                ACPLogger.log("    Failed to decode session/update: \(error)")
            }
        }
    }

    private func handleAgentRequest(id: JSONRPCID, method: String, data: Data) {
        ACPLogger.log("--- AGENT REQUEST: id=\(id), method=\(method)")
        switch method {
        case "fs/read_text_file":
            handleFSRead(id: id, data: data)
        case "fs/write_text_file":
            handleFSWrite(id: id, data: data)
        case "terminal/create":
            handleTerminalCreate(id: id, data: data)
        case "terminal/wait_for_exit":
            handleTerminalWaitForExit(id: id, data: data)
        case "session/request_permission":
            handlePermissionRequest(id: id, data: data)
        default:
            ACPLogger.log("    Unsupported client method: \(method)")
            sendRawError(id: id, error: JSONRPCError(code: -32601, message: "Unsupported client method: \(method)"))
        }
    }

    private func handlePermissionRequest(id: JSONRPCID, data: Data) {
        guard let req = try? decoder.decode(JSONRPCAnyIDRequest<ACPRequestPermissionParams>.self, from: data),
              let params = req.params else {
            sendRawError(id: id, error: JSONRPCError(code: -32602, message: "Invalid session/request_permission params"))
            return
        }

        delegate?.client(self, didRequestPermission: params, requestId: id)
    }

    // MARK: - Auto-Allow Client Methods (Filesystem & Terminal)

    private func handleFSRead(id: JSONRPCID, data: Data) {
        guard let req = try? decoder.decode(JSONRPCRequest<ACPFSReadTextFileParams>.self, from: data),
              let params = req.params else {
            sendRawError(id: id, error: JSONRPCError(code: -32602, message: "Invalid fs/read_text_file params"))
            return
        }

        let fullPath = resolvePath(params.path)
        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            delegate?.client(self, didExecuteTool: "fs/read_text_file", path: params.path, details: "Read \(content.count) chars")
            sendRawResponse(id: id, result: ACPFSReadTextFileResult(content: content))
        } catch {
            sendRawError(id: id, error: JSONRPCError(code: -32000, message: "Failed to read file: \(error.localizedDescription)"))
        }
    }

    private func handleFSWrite(id: JSONRPCID, data: Data) {
        guard let req = try? decoder.decode(JSONRPCRequest<ACPFSWriteTextFileParams>.self, from: data),
              let params = req.params else {
            sendRawError(id: id, error: JSONRPCError(code: -32602, message: "Invalid fs/write_text_file params"))
            return
        }

        let fullPath = resolvePath(params.path)
        let oldContent = (try? String(contentsOfFile: fullPath, encoding: .utf8))
        let newContent = params.content
        do {
            let fileURL = URL(fileURLWithPath: fullPath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try params.content.write(toFile: fullPath, atomically: true, encoding: .utf8)
            delegate?.client(self, didExecuteTool: "fs/write_text_file", path: params.path, details: "Wrote \(params.content.count) bytes")
            delegate?.client(self, didExecuteFSWrite: params.path, oldContent: oldContent, newContent: newContent)
            sendRawResponse(id: id, result: ACPFSWriteTextFileResult(success: true))
        } catch {
            sendRawError(id: id, error: JSONRPCError(code: -32000, message: "Failed to write file: \(error.localizedDescription)"))
        }
    }

    private func handleTerminalCreate(id: JSONRPCID, data: Data) {
        guard let req = try? decoder.decode(JSONRPCRequest<ACPTerminalCreateParams>.self, from: data),
              let params = req.params else {
            sendRawError(id: id, error: JSONRPCError(code: -32602, message: "Invalid terminal/create params"))
            return
        }

        let cmd = params.command ?? ""
        let terminalId = UUID().uuidString
        let effectiveCwd = params.cwd.flatMap { resolvePath($0) } ?? self.workingDirectory

        let runner = ACPTerminalRunner(id: terminalId, command: cmd, cwd: effectiveCwd)
        terminalsLock.lock()
        activeTerminals[terminalId] = runner
        terminalsLock.unlock()

        runner.start { [weak self] chunk in
            guard let self else { return }
            let notif = JSONRPCNotification(
                method: "terminal/output",
                params: ACPTerminalOutputParams(terminalId: terminalId, output: chunk)
            )
            if let notifData = try? self.encoder.encode(notif) {
                self.transport.sendLine(notifData)
            }
        }

        sendRawResponse(id: id, result: ACPTerminalCreateResult(terminalId: terminalId))
    }

    private func handleTerminalWaitForExit(id: JSONRPCID, data: Data) {
        guard let req = try? decoder.decode(JSONRPCRequest<ACPTerminalWaitForExitParams>.self, from: data),
              let params = req.params else {
            sendRawResponse(id: id, result: ACPTerminalWaitForExitResult(exitCode: 0))
            return
        }

        let terminalId = params.terminalId
        terminalsLock.lock()
        let runner = activeTerminals[terminalId]
        terminalsLock.unlock()

        guard let runner else {
            sendRawResponse(id: id, result: ACPTerminalWaitForExitResult(exitCode: 0))
            return
        }

        runner.waitForExit { [weak self] code, finalOutput in
            guard let self else { return }
            self.sendRawResponse(id: id, result: ACPTerminalWaitForExitResult(exitCode: Int(code)))
            self.delegate?.client(self, didExecuteTool: "run_command", path: nil, details: finalOutput)
        }
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path
    }
}

final class ACPTerminalRunner: @unchecked Sendable {
    let id: String
    let command: String
    let cwd: String
    let process: Process
    let pipe: Pipe
    private(set) var output: String = ""
    private(set) var exitCode: Int32? = nil
    private var exitHandlers: [(Int32, String) -> Void] = []
    private let lock = NSLock()

    init(id: String, command: String, cwd: String) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.process = Process()
        self.pipe = Pipe()
    }

    func start(onOutputChunk: @escaping (String) -> Void) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        } else if let p = env["PATH"], !p.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:\(p)"
        }
        process.environment = env
        process.standardOutput = pipe
        process.standardError = pipe

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                self?.lock.lock()
                self?.output += str
                self?.lock.unlock()
                onOutputChunk(str)
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = self.pipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty, let str = String(data: remaining, encoding: .utf8) ?? String(data: remaining, encoding: .ascii) {
                self.lock.lock()
                self.output += str
                self.lock.unlock()
                onOutputChunk(str)
            }

            self.lock.lock()
            let code = proc.terminationStatus
            self.exitCode = code
            let finalOutput = self.output
            let handlers = self.exitHandlers
            self.exitHandlers.removeAll()
            self.lock.unlock()

            for handler in handlers {
                handler(code, finalOutput)
            }
        }

        do {
            try process.run()
        } catch {
            lock.lock()
            let errMsg = "Failed to run command: \(error.localizedDescription)\n"
            self.output += errMsg
            self.exitCode = 1
            let finalOutput = self.output
            let handlers = self.exitHandlers
            self.exitHandlers.removeAll()
            lock.unlock()

            onOutputChunk(errMsg)
            for handler in handlers {
                handler(1, finalOutput)
            }
        }
    }

    func waitForExit(completion: @escaping (Int32, String) -> Void) {
        lock.lock()
        if let code = exitCode {
            let out = output
            lock.unlock()
            completion(code, out)
            return
        }
        exitHandlers.append(completion)
        lock.unlock()
    }

    func kill() {
        if process.isRunning {
            process.terminate()
        }
    }
}
