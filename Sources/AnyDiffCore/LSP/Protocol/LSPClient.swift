import Foundation

public actor LSPClient {
    public enum State: Sendable, Equatable {
        case unstarted
        case initializing
        case ready
        case stopped
    }

    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var documentVersions: [String: Int] = [:]
    private var documentTexts: [String: String] = [:]
    private var warmedUpDocuments: Set<String> = []
    private var syncKind: Int = 1
    private var requiresProjectInitialization: Bool = false
    private var isProjectInitialized: Bool = false
    private var projectInitContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let frameReader = LSPFraming.FrameReader()

    public private(set) var state: State = .unstarted
    public private(set) var rootPath: String?
    public let serverName: String

    public init(executablePath: String, arguments: [String] = [], workingDirectory: String, serverName: String? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.serverName = serverName ?? LSPServerCatalog.canonicalServerName(fromExecutablePath: executablePath, arguments: arguments)
    }

    deinit {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }

    // MARK: - Lifecycle

    public func start(rootPath: String) async throws {
        guard state == .unstarted else { return }
        self.state = .initializing
        self.rootPath = rootPath
        self.requiresProjectInitialization = arguments.contains("--autoLoadProjects") && Self.hasAutoLoadableProjects(in: rootPath)
        self.isProjectInitialized = !requiresProjectInitialization

        let proc = Process()
        if executablePath.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = arguments
        } else if let resolved = LSPEnvironment.which(executablePath) {
            proc.executableURL = URL(fileURLWithPath: resolved)
            proc.arguments = arguments
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [executablePath] + arguments
        }
        proc.environment = LSPEnvironment.makeProcessEnvironment()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        try proc.run()

        // Start background stdout reader loop
        startReadingOutput(pipe: outPipe)

        // 1. Send initialize request
        let rootUri = URL(fileURLWithPath: rootPath).absoluteString
        let workspaceName = (rootPath as NSString).lastPathComponent
        let initParams: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootPath": rootPath,
            "rootUri": rootUri,
            "workspaceFolders": [
                [
                    "uri": rootUri,
                    "name": workspaceName
                ]
            ],
            "capabilities": [
                "workspace": [
                    "workspaceFolders": true,
                    "configuration": true
                ],
                "textDocument": [
                    "synchronization": [
                        "openClose": true,
                        "change": 1, // Full document sync preferred
                        "save": true
                    ],
                    "definition": [
                        "dynamicRegistration": true,
                        "linkSupport": true
                    ],
                    "hover": [
                        "dynamicRegistration": true,
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "completion": [
                        "dynamicRegistration": true,
                        "completionItem": [
                            "snippetSupport": true,
                            "documentationFormat": ["markdown", "plaintext"],
                            "insertReplaceSupport": true
                        ],
                        "contextSupport": true
                    ]
                ]
            ]
        ]

        let initResult = try await sendRequest(method: "initialize", params: initParams)
        if let resultDict = initResult as? [String: Any],
           let caps = resultDict["capabilities"] as? [String: Any] {
            if let syncInt = caps["textDocumentSync"] as? Int {
                self.syncKind = syncInt
            } else if let syncDict = caps["textDocumentSync"] as? [String: Any],
                      let changeInt = syncDict["change"] as? Int {
                self.syncKind = changeInt
            }
        }

        // 2. Send initialized notification
        try sendNotification(method: "initialized", params: [:])
        self.state = .ready
    }

    public func stop() {
        guard state != .stopped else { return }
        state = .stopped
        markProjectInitialized()
        let proc = self.process
        let inPipe = self.stdinPipe
        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        let pending = self.pendingRequests
        self.pendingRequests.removeAll()
        for (_, cont) in pending {
            cont.resume(throwing: NSError(domain: "LSPClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "LSP client stopped"]))
        }

        if let p = proc, p.isRunning {
            if let inPipe = inPipe {
                let shutdownReq: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": nextRequestId,
                    "method": "shutdown"
                ]
                nextRequestId += 1
                if let data = try? LSPFraming.encode(jsonDict: shutdownReq) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                let exitNotif: [String: Any] = [
                    "jsonrpc": "2.0",
                    "method": "exit"
                ]
                if let data = try? LSPFraming.encode(jsonDict: exitNotif) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()
            }
            p.terminate()
        }
    }

    private func markProjectInitialized() {
        isProjectInitialized = true
        let continuations = projectInitContinuations.values
        projectInitContinuations.removeAll()
        for cont in continuations {
            cont.resume()
        }
    }

    private func waitForProjectInitializationIfNeeded() async {
        guard requiresProjectInitialization && !isProjectInitialized else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if self.isProjectInitialized {
                continuation.resume()
                return
            }
            self.projectInitContinuations[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.resumeProjectInitTimeout(id: id)
            }
        }
    }

    private func resumeProjectInitTimeout(id: UUID) {
        if let cont = projectInitContinuations.removeValue(forKey: id) {
            isProjectInitialized = true
            cont.resume()
        }
    }

    // MARK: - Document Synchronization

    public func didOpen(filePath: String, text: String, languageId: String) async throws {
        guard state == .ready else { return }
        await waitForProjectInitializationIfNeeded()
        let uri = URL(fileURLWithPath: filePath).absoluteString
        documentVersions[uri] = 1
        documentTexts[uri] = text

        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "languageId": languageId,
                "version": 1,
                "text": text
            ]
        ]
        try sendNotification(method: "textDocument/didOpen", params: params)
    }

    public func didChange(filePath: String, text: String) throws {
        guard state == .ready else { return }
        let uri = URL(fileURLWithPath: filePath).absoluteString
        if let existing = documentTexts[uri], existing == text {
            return
        }

        let oldText = documentTexts[uri]
        let nextVer = (documentVersions[uri] ?? 1) + 1
        documentVersions[uri] = nextVer
        documentTexts[uri] = text

        let changeEvent: [String: Any]
        if syncKind == 2, let old = oldText {
            let endPos = Self.endPosition(of: old)
            changeEvent = [
                "range": [
                    "start": ["line": 0, "character": 0],
                    "end": ["line": endPos.line, "character": endPos.character]
                ],
                "text": text
            ]
        } else {
            changeEvent = ["text": text]
        }

        let params: [String: Any] = [
            "textDocument": [
                "uri": uri,
                "version": nextVer
            ],
            "contentChanges": [changeEvent]
        ]
        try sendNotification(method: "textDocument/didChange", params: params)
    }

    private static func endPosition(of text: String) -> (line: Int, character: Int) {
        var line = 0
        var character = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                line += 1
                character = 0
            } else {
                character += 1
            }
        }
        return (line, character)
    }

    public func didSave(filePath: String) throws {
        guard state == .ready else { return }
        let uri = URL(fileURLWithPath: filePath).absoluteString
        let params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        try sendNotification(method: "textDocument/didSave", params: params)
    }

    public func didClose(filePath: String) throws {
        guard state == .ready else { return }
        let uri = URL(fileURLWithPath: filePath).absoluteString
        documentVersions.removeValue(forKey: uri)
        documentTexts.removeValue(forKey: uri)
        warmedUpDocuments.remove(uri)
        let params: [String: Any] = [
            "textDocument": ["uri": uri]
        ]
        try sendNotification(method: "textDocument/didClose", params: params)
    }

    // MARK: - Go To Definition

    public func gotoDefinition(filePath: String, line: Int, character: Int) async throws -> [LSPLocation] {
        guard state == .ready else {
            return []
        }
        await waitForProjectInitializationIfNeeded()

        let uri = URL(fileURLWithPath: filePath).absoluteString
        warmedUpDocuments.insert(uri)
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": [
                "line": max(0, line),
                "character": max(0, character)
            ]
        ]

        let response = try await sendRequest(method: "textDocument/definition", params: params)
        return LSPDefinitionResponseParser.parse(from: response)
    }

    // MARK: - Code Completion

    public func getCompletions(
        filePath: String,
        line: Int,
        character: Int,
        triggerCharacter: String? = nil
    ) async throws -> [LSPCompletionItem] {
        guard state == .ready else { return [] }
        await waitForProjectInitializationIfNeeded()

        let uri = URL(fileURLWithPath: filePath).absoluteString
        if requiresProjectInitialization && !warmedUpDocuments.contains(uri) {
            warmedUpDocuments.insert(uri)
            _ = try? await sendRequest(
                method: "textDocument/hover",
                params: [
                    "textDocument": ["uri": uri],
                    "position": ["line": 0, "character": 0]
                ]
            )
        }

        var params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": [
                "line": max(0, line),
                "character": max(0, character)
            ]
        ]

        if let trigger = triggerCharacter {
            params["context"] = [
                "triggerKind": 2, // TriggerCharacter
                "triggerCharacter": trigger
            ]
        } else {
            params["context"] = [
                "triggerKind": 1 // Invoked
            ]
        }

        let response = try await sendRequest(method: "textDocument/completion", params: params)
        return LSPCompletionResponseParser.parse(from: response)
    }

    // MARK: - Hover

    public func getHover(
        filePath: String,
        line: Int,
        character: Int
    ) async throws -> LSPHover? {
        guard state == .ready else { return nil }
        await waitForProjectInitializationIfNeeded()

        let uri = URL(fileURLWithPath: filePath).absoluteString
        warmedUpDocuments.insert(uri)
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": [
                "line": max(0, line),
                "character": max(0, character)
            ]
        ]

        let response = try await sendRequest(method: "textDocument/hover", params: params)
        return LSPHoverResponseParser.parse(from: response)
    }

    // MARK: - Low-level Messaging

    private func sendRequest(method: String, params: Any?) async throws -> Any? {
        let reqId = nextRequestId
        nextRequestId += 1

        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method
        ]
        if let params = params {
            dict["params"] = params
        }

        let data = try LSPFraming.encode(jsonDict: dict)
        guard let inPipe = stdinPipe else {
            throw NSError(domain: "LSPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stdin not open"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[reqId] = continuation
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func sendNotification(method: String, params: Any?) throws {
        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params = params {
            dict["params"] = params
        }

        let data = try LSPFraming.encode(jsonDict: dict)
        stdinPipe?.fileHandleForWriting.write(data)
    }

    private func startReadingOutput(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        let reader = frameReader
        Task.detached(priority: .userInitiated) { [weak self, handle, reader] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                guard let self = self else { break }
                let messages = reader.append(data: chunk)
                for msg in messages {
                    await self.handleIncomingMessage(msg)
                }
            }
        }
    }

    private static func hasAutoLoadableProjects(in rootPath: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }
        for case let url as URL in enumerator {
            if enumerator.level > 3 {
                enumerator.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            if ext == "sln" || ext == "slnx" || ext == "csproj" || ext == "fsproj" || ext == "vbproj" {
                return true
            }
        }
        return false
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String, message["id"] == nil {
            if method == "workspace/projectInitializationComplete" {
                markProjectInitialized()
            }
            return
        }

        // Handle server-to-client requests (e.g. client/registerCapability, workspace/configuration)
        if let method = message["method"] as? String, let reqId = message["id"] {
            var resultObj: Any = NSNull()
            if method == "workspace/configuration" {
                if let params = message["params"] as? [String: Any],
                   let items = params["items"] as? [Any] {
                    resultObj = Array(repeating: NSNull(), count: items.count)
                } else {
                    resultObj = []
                }
            }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": reqId,
                "result": resultObj
            ]
            if let data = try? LSPFraming.encode(jsonDict: response) {
                stdinPipe?.fileHandleForWriting.write(data)
            }
            return
        }

        // Handle responses to pending client requests
        let resolvedId: Int? = {
            if let idNum = message["id"] as? NSNumber {
                return idNum.intValue
            } else if let idInt = message["id"] as? Int {
                return idInt
            }
            return nil
        }()

        if let id = resolvedId {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = message["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "LSP Error"
                    continuation.resume(throwing: NSError(domain: "LSPClient", code: id, userInfo: [NSLocalizedDescriptionKey: msg]))
                } else {
                    continuation.resume(returning: message["result"])
                }
            }
        }
    }
}
