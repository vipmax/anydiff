import Foundation

public final class ACPAgentSessionManager: AgentSessionManager, ACPClientDelegate, @unchecked Sendable {
    public static let defaultCommand = "CODEX_PATH=\"$(command -v codex || true)\" npx -y @agentclientprotocol/codex-acp"

    @Published public var agentCommand: String {
        didSet {
            UserDefaults.standard.set(agentCommand, forKey: "anydiff_acp_command")
        }
    }

    private let client: ACPClient
    private var currentWorkingDirectory: String = ""
    public internal(set) var currentSessionId: String? = nil
    private var currentStreamMessageId: UUID? = nil
    private var initializationTask: Task<Void, Never>?
    private var initializationWorkingDirectory: String?
    private var promptTask: Task<Void, Never>?
    private var pendingPrompt: (text: String, workingDirectory: String)?

    public init(client: ACPClient = ACPClient()) {
        self.client = client
        self.agentCommand = UserDefaults.standard.string(forKey: "anydiff_acp_command") ?? Self.defaultCommand
        super.init()
        self.client.delegate = self
    }

    deinit {
        initializationTask?.cancel()
        promptTask?.cancel()
    }

    public override func selectModel(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.model, value: value)
    }

    public override func selectReasoningEffort(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.reasoningEffort, value: value)
    }

    public override func selectAgentMode(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.mode, value: value)
    }

    public override func selectConfigOption(id: String, value: String) {
        super.selectConfigOption(id: id, value: value)
        guard let sessionId = currentSessionId else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let result = try? await self.client.setConfigOption(sessionId: sessionId, configId: id, value: value) {
                self.applyConfigOptions(result)
            }
        }
    }

    public override func sendPrompt(_ text: String, workingDirectory: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Never let two lifecycle tasks mutate the same ACP client. A prompt
        // can be staged while the process is starting, then drained after the
        // initialize + session/new handshake completes.
        guard currentStreamMessageId == nil, promptTask == nil, pendingPrompt == nil else { return }

        let userMsg = AgentMessage(role: .user, content: trimmed)
        messages.append(userMsg)

        let assistantMsgId = UUID()
        currentStreamMessageId = assistantMsgId
        let assistantMsg = AgentMessage(id: assistantMsgId, role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        pendingPrompt = (text: trimmed, workingDirectory: workingDirectory)
        if isReadyForPrompt, currentSessionId != nil, currentWorkingDirectory == workingDirectory, client.isConnected {
            startPendingPromptIfPossible()
        } else {
            prepareAgent(workingDirectory: workingDirectory)
        }
    }

    public var targetLoadSessionId: String? = nil

    public func prepareAgent(workingDirectory: String, loadSessionId: String?) {
        self.targetLoadSessionId = loadSessionId
        self.prepareAgent(workingDirectory: workingDirectory)
    }

    public override func prepareAgent(workingDirectory: String) {
        guard !workingDirectory.isEmpty else { return }

        if initializationState == .ready,
           currentSessionId != nil,
           currentWorkingDirectory == workingDirectory,
           client.isConnected {
            startPendingPromptIfPossible()
            return
        }

        // A panel can call prepareAgent repeatedly as SwiftUI recomputes its
        // body. Only the first call for a directory is allowed to own the
        // startup handshake. A directory change invalidates the old attempt.
        if let initializationTask {
            if initializationWorkingDirectory == workingDirectory {
                return
            }
            initializationTask.cancel()
            self.initializationTask = nil
            initializationWorkingDirectory = nil
            client.stop()
            currentSessionId = nil
        }

        initializationWorkingDirectory = workingDirectory
        initializationState = .starting
        status = .connecting
        statusMessage = targetLoadSessionId != nil ? "Loading session..." : "Starting agent..."

        initializationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureConnectedAndSession(workingDirectory: workingDirectory)
                guard self.currentSessionId != nil else {
                    throw JSONRPCError(code: -1, message: "Failed to establish ACP session")
                }

                self.initializationState = .ready
                self.initializationTask = nil
                self.initializationWorkingDirectory = nil
                self.status = .idle
                self.statusMessage = nil
                self.startPendingPromptIfPossible()
            } catch {
                self.initializationTask = nil
                self.initializationWorkingDirectory = nil
                guard !Task.isCancelled else { return }
                self.initializationState = .failed(error.localizedDescription)
                self.status = .error(error.localizedDescription)
                self.statusMessage = "Error: \(error.localizedDescription)"
                if self.pendingPrompt != nil {
                    self.pendingPrompt = nil
                    self.appendErrorMessage(error.localizedDescription)
                    self.markCurrentStreamComplete()
                }
            }
        }
    }

    private var preTurnSnapshot: PreTurnGitSnapshot? = nil

    private func startPendingPromptIfPossible() {
        guard promptTask == nil,
              let pending = pendingPrompt,
              let sessionId = currentSessionId,
              initializationState == .ready else { return }

        guard pending.workingDirectory == currentWorkingDirectory else {
            prepareAgent(workingDirectory: pending.workingDirectory)
            return
        }

        pendingPrompt = nil
        status = .busy
        statusMessage = "Agent is thinking..."
        liveEditedSummary = nil

        let workingDir = pending.workingDirectory
        self.preTurnSnapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: workingDir)

        promptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendPrompt(sessionId: sessionId, text: pending.text)
                self.status = .idle
                self.statusMessage = nil
                let (summary, _) = AgentGitChangesDetector.computeTurnSummary(
                    workingDirectory: workingDir,
                    snapshot: self.preTurnSnapshot
                )
                if let summary {
                    if let streamId = self.currentStreamMessageId, let idx = self.messages.firstIndex(where: { $0.id == streamId }) {
                        self.messages[idx].editedFilesSummary = summary
                    } else if let lastIdx = self.messages.indices.last, self.messages[lastIdx].role == .assistant {
                        self.messages[lastIdx].editedFilesSummary = summary
                    }
                }
                self.liveEditedSummary = nil
                self.preTurnSnapshot = nil
                self.markCurrentStreamComplete()
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .error(error.localizedDescription)
                self.statusMessage = "Error: \(error.localizedDescription)"
                self.appendErrorMessage(error.localizedDescription)
                self.liveEditedSummary = nil
                self.preTurnSnapshot = nil
                self.markCurrentStreamComplete()
            }
            self.promptTask = nil
        }
    }

    public override func cancel() {
        if let permission = pendingPermission {
            client.respondToPermission(requestId: permission.requestId, optionId: nil)
            pendingPermission = nil
        }

        if currentSessionId == nil {
            // Startup can still be in progress. Cancel the handshake as well
            // as the staged prompt so the stop button has an immediate effect.
            initializationTask?.cancel()
            initializationTask = nil
            initializationWorkingDirectory = nil
            client.stop()
            pendingPrompt = nil
            markCurrentStreamComplete()
            initializationState = .notStarted
            status = .idle
            statusMessage = "Stopped"
            return
        }

        guard let sessionId = currentSessionId else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await self.client.cancelSession(sessionId: sessionId)
            self.promptTask?.cancel()
            self.promptTask = nil
            self.status = .idle
            self.statusMessage = "Stopped"
            self.markCurrentStreamComplete()
        }
    }

    public override func clearSession() {
        initializationTask?.cancel()
        promptTask?.cancel()
        initializationTask = nil
        initializationWorkingDirectory = nil
        promptTask = nil
        pendingPrompt = nil
        pendingPermission = nil
        client.stop()
        messages.removeAll()
        currentStreamMessageId = nil
        currentSessionId = nil
        initializationState = .notStarted
        status = .disconnected
        statusMessage = nil
    }

    public override func restartAgent(workingDirectory: String) {
        initializationTask?.cancel()
        promptTask?.cancel()
        initializationTask = nil
        initializationWorkingDirectory = nil
        promptTask = nil
        pendingPrompt = nil
        pendingPermission = nil
        currentStreamMessageId = nil
        client.stop()
        currentSessionId = nil
        currentWorkingDirectory = ""
        initializationState = .notStarted
        status = .disconnected
        statusMessage = "Agent stopped"
    }

    private func startClient(command: String, workingDirectory: String) async throws {
        let client = self.client
        try await Task.detached(priority: .userInitiated) {
            try client.start(command: command, workingDirectory: workingDirectory)
        }.value
    }

    private func ensureConnectedAndSession(workingDirectory: String) async throws {
        if !client.isConnected || currentWorkingDirectory != workingDirectory {
            client.stop()
            currentWorkingDirectory = workingDirectory
            DispatchQueue.main.async {
                self.status = .connecting
                self.statusMessage = "Launching \(self.agentCommand)..."
            }
            try await startClient(command: agentCommand, workingDirectory: workingDirectory)

            let initResult = try await client.initialize()
            let resolvedTitle: String
            if !self.agentTitle.isEmpty {
                resolvedTitle = self.agentTitle
            } else if let title = initResult.agentInfo?.title, !title.isEmpty {
                resolvedTitle = title
            } else if let name = initResult.agentInfo?.name, !name.isEmpty {
                resolvedTitle = name
            } else {
                resolvedTitle = "Agent"
            }

            let sessionOpts: [ACPConfigOption]?
            let sessId: String
            if let targetId = targetLoadSessionId {
                let loadResult = try await client.loadSession(sessionId: targetId, cwd: workingDirectory)
                sessId = targetId
                sessionOpts = loadResult.configOptions
            } else {
                let sessionResult = try await client.createSessionFull(cwd: workingDirectory)
                sessId = sessionResult.sessionId
                sessionOpts = sessionResult.configOptions
            }

            DispatchQueue.main.async {
                self.agentTitle = resolvedTitle
                self.statusMessage = "Connected to \(resolvedTitle)"
                self.currentSessionId = sessId
                if let options = sessionOpts, !options.isEmpty {
                    self.applyConfigOptions(options)
                }
            }
        } else if currentSessionId == nil {
            let sessionOpts: [ACPConfigOption]?
            let sessId: String
            if let targetId = targetLoadSessionId {
                let loadResult = try await client.loadSession(sessionId: targetId, cwd: workingDirectory)
                sessId = targetId
                sessionOpts = loadResult.configOptions
            } else {
                let sessionResult = try await client.createSessionFull(cwd: workingDirectory)
                sessId = sessionResult.sessionId
                sessionOpts = sessionResult.configOptions
            }

            DispatchQueue.main.async {
                self.currentSessionId = sessId
                if let options = sessionOpts, !options.isEmpty {
                    self.applyConfigOptions(options)
                }
            }
        }
    }

    private func applyConfigOptions(_ options: [ACPConfigOption]) {
        self.configOptions = options
        if let modelOpt = options.first(where: { $0.id == ACPConfigOptionID.model }) {
            let currentVal = modelOpt.currentValue ?? modelOpt.options?.first?.value
            if let currentVal {
                let opt = modelOpt.options?.first(where: { $0.value == currentVal })
                self.selectedModel = opt?.name ?? currentVal
                self.selectedModelValue = currentVal
            }
        }
        if let effortOpt = options.first(where: { $0.id == ACPConfigOptionID.reasoningEffort }) {
            let currentVal = effortOpt.currentValue ?? effortOpt.options?.first?.value
            if let currentVal {
                let opt = effortOpt.options?.first(where: { $0.value == currentVal })
                self.selectedReasoningEffort = opt?.name ?? currentVal
                self.selectedReasoningEffortValue = currentVal
            }
        }
        if let modeOpt = options.first(where: { $0.id == ACPConfigOptionID.mode }) {
            let currentVal = modeOpt.currentValue ?? modeOpt.options?.first?.value
            if let currentVal {
                let opt = modeOpt.options?.first(where: { $0.value == currentVal })
                self.selectedAgentMode = opt?.name ?? currentVal
                self.selectedAgentModeValue = currentVal
            }
        }
    }

    private func markCurrentStreamComplete() {
        guard let streamId = currentStreamMessageId else { return }
        if let idx = messages.firstIndex(where: { $0.id == streamId }) {
            messages[idx].isStreaming = false
            messages[idx].completeRunningToolCalls()
        }
        currentStreamMessageId = nil
    }

    private func appendErrorMessage(_ errorText: String) {
        if let streamId = currentStreamMessageId, let idx = messages.firstIndex(where: { $0.id == streamId }) {
            if messages[idx].content.isEmpty {
                messages[idx].appendText("⚠️ \(errorText)")
            } else {
                messages[idx].appendText("\n\n⚠️ \(errorText)")
            }
            messages[idx].isStreaming = false
            messages[idx].completeRunningToolCalls()
        } else {
            messages.append(AgentMessage(role: .assistant, content: "⚠️ \(errorText)", isStreaming: false))
        }
    }

    // MARK: - ACPClientDelegate

    public func client(_ client: ACPClient, didReceiveUpdate update: ACPSessionUpdateContent, sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let type = update.effectiveType
            let chunk = update.effectiveChunk

            ACPLogger.log("MANAGER didReceiveUpdate: type=\(type), chunk=\(chunk), toolName=\(update.toolName ?? "nil"), toolCallId=\(update.toolCallId ?? "nil"), inputKeys=\(update.toolInput?.keys.sorted() ?? [])")

            // 1. User messages (from history replaying during session/load)
            if type == "user_message_chunk" || type == "user_message" || type == "user" {
                if !chunk.isEmpty {
                    if let lastIdx = self.messages.indices.last, self.messages[lastIdx].role == .user {
                        self.messages[lastIdx].appendText(chunk)
                    } else {
                        self.messages.append(AgentMessage(role: .user, content: chunk, isStreaming: false))
                    }
                }
                return
            }

            let isThought = type == "thought_chunk" || type == "thought" || type == "agent_thought_chunk"
            let isText = type == "message_chunk" || type == "text" || type == "content" || type == "agent_message_chunk"
            let isTool = type == "tool_call" || type == "tool_use" || type == "tool_start" || type == "tool_call_update" || type == "tool_result" || type == "tool_call_result" || type == "tool_end" || type == "tool_complete" || type == "usage_update"

            // Ignore metadata/command updates that are not chat turns
            guard isThought || isText || isTool else {
                return
            }

            // Don't append empty messages for empty thought/text chunks
            if (isThought || isText) && chunk.isEmpty && update.toolCallId == nil {
                return
            }

            // 2. Assistant messages or streaming updates
            let targetIdx: Int
            if let streamId = self.currentStreamMessageId,
               let idx = self.messages.firstIndex(where: { $0.id == streamId }) {
                targetIdx = idx
            } else {
                // Replaying historical message during session/load
                if let lastIdx = self.messages.indices.last, self.messages[lastIdx].role == .assistant {
                    targetIdx = lastIdx
                } else {
                    let msg = AgentMessage(role: .assistant, content: "", isStreaming: false)
                    self.messages.append(msg)
                    targetIdx = self.messages.count - 1
                }
            }

            switch type {
            case "thought_chunk", "thought", "agent_thought_chunk":
                if !chunk.isEmpty {
                    self.messages[targetIdx].appendThought(chunk)
                }
                if self.currentStreamMessageId != nil {
                    self.status = .busy
                    self.statusMessage = "Thinking..."
                }
            case "message_chunk", "text", "content", "agent_message_chunk":
                if !chunk.isEmpty {
                    self.messages[targetIdx].appendText(chunk)
                    self.messages[targetIdx].completeRunningToolCalls()
                }
                if self.currentStreamMessageId != nil {
                    self.status = .busy
                    self.statusMessage = nil
                }
            case "tool_call", "tool_use", "tool_start", "tool_call_update":
                let input = update.toolInput ?? [:]
                var toolName = update.kind ?? update.toolName ?? "tool"
                var cmd = Self.extractFirstString(from: input, keys: [
                    "CommandLine", "command_line", "commandLine", "command",
                    "cmd", "script", "shell", "shell_command", "shellCommand",
                    "program"
                ])

                let normalizedToolName = toolName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let commandToolNames = ["just", "make", "xcodebuild", "swift", "swiftc", "cargo", "npm", "pnpm", "yarn", "git", "rg", "grep", "find", "bash", "sh", "zsh", "python", "python3"]
                let isCommandLike = toolName.starts(with: "git ") || toolName.starts(with: "npm ") || toolName.starts(with: "cargo ") || toolName.starts(with: "swift ") || toolName.starts(with: "sh ") || toolName.starts(with: "bash ") || toolName.contains(" && ") || toolName.contains(" | ") || toolName.contains(" --") || commandToolNames.contains(normalizedToolName)

                if normalizedToolName == "edit" || normalizedToolName == "editing files" || update.kind == "edit" {
                    toolName = "Edit"
                } else if normalizedToolName == "execute" || update.kind == "execute" {
                    toolName = "run_command"
                } else if cmd == nil && isCommandLike {
                    cmd = toolName
                    toolName = "run_command"
                } else if toolName == "tool" || toolName.isEmpty {
                    if cmd != nil {
                        toolName = "run_command"
                    } else if input.keys.contains("TargetContent") || input.keys.contains("replacement_content") || input.keys.contains("ReplacementContent") || input.keys.contains("old_string") || input.keys.contains("old_content") || input.keys.contains("oldText") {
                        toolName = "replace_file_content"
                    } else if input.keys.contains("TargetFile") || input.keys.contains("CodeContent") || input.keys.contains("new_content") || input.keys.contains("newText") {
                        toolName = "write_to_file"
                    } else if input.keys.contains("AbsolutePath") || input.keys.contains("path") || input.keys.contains("file_path") {
                        toolName = "view_file"
                    }
                }

                let path = Self.extractFirstString(from: input, keys: ["path", "file_path", "filePath", "TargetFile", "target_file", "target_path", "file", "AbsolutePath", "filename", "uri"])
                let desc = Self.extractFirstString(from: input, keys: ["description", "Description", "Instruction", "instruction", "toolSummary", "summary", "title", "label"])
                let sLineStr = Self.extractFirstString(from: input, keys: ["StartLine", "start_line", "line"])
                let eLineStr = Self.extractFirstString(from: input, keys: ["EndLine", "end_line"])
                let sLine = sLineStr.flatMap { Int($0) }
                let eLine = eLineStr.flatMap { Int($0) }
                let oldContent = Self.extractFirstString(from: input, keys: ["old_content", "oldContent", "oldText", "old_text", "TargetContent", "target_content", "old_string", "old_str", "find", "target", "original_text", "original", "before", "diff", "patch"])
                let newContent = Self.extractFirstString(from: input, keys: ["new_content", "newContent", "newText", "new_text", "ReplacementContent", "replacement_content", "CodeContent", "new_string", "new_str", "replacement", "content", "text", "insert", "after", "data"])

                let title = path.map { ($0 as NSString).lastPathComponent } ?? update.title ?? desc

                let isCompleted = update.status == "completed" || update.status == "done" || update.status == "success"
                let isFailed = update.status == "failed" || update.status == "error"
                let initialStatus: ToolCallStatus = isFailed ? .failed : (isCompleted ? .completed : .running)

                if let toolId = update.toolCallId,
                   self.messages[targetIdx].toolCalls.contains(where: { $0.id == toolId }) {
                    // Update existing tool call
                    _ = self.messages[targetIdx].updateToolCall(id: toolId) { item in
                        if toolName != "tool" { item.toolName = toolName }
                        if let path {
                            item.path = path
                            item.title = (path as NSString).lastPathComponent
                        } else if item.title == nil || item.title == "Editing files" {
                            item.title = title
                        }
                        if let desc { item.descriptionText = desc }
                        if let sLine { item.startLine = sLine }
                        if let eLine { item.endLine = eLine }
                        if let oldContent { item.oldContent = oldContent }
                        if let newContent { item.newContent = newContent }
                        if let cmd { item.command = cmd }
                        if let res = update.toolResult ?? update.contentText, !res.isEmpty {
                            if item.output == nil || item.output?.isEmpty == true {
                                item.output = res
                            } else if item.output != res {
                                item.output? += res
                            }
                            item.summary = item.output
                        }
                        if isCompleted { item.status = .completed }
                        if isFailed { item.status = .failed }
                    }
                } else {
                    let item = ToolCallItem(
                        id: update.toolCallId ?? UUID().uuidString,
                        toolName: toolName,
                        path: path,
                        title: title,
                        descriptionText: desc,
                        startLine: sLine,
                        endLine: eLine,
                        oldContent: oldContent,
                        newContent: newContent,
                        command: cmd,
                        output: update.toolResult ?? update.contentText,
                        summary: update.toolResult ?? (chunk.isEmpty ? nil : chunk),
                        status: initialStatus
                    )
                    self.messages[targetIdx].appendToolCall(item)
                }
                if self.currentStreamMessageId != nil {
                    self.statusMessage = "Running \(toolName)..."
                }
            case "tool_result", "tool_call_result", "tool_end", "tool_complete":
                let isErr = update.isError == true || update.status == "error" || update.status == "failed"
                let resultText = update.toolResult ?? update.contentText ?? (chunk.isEmpty ? nil : chunk)
                if let toolId = update.toolCallId,
                   self.messages[targetIdx].toolCalls.contains(where: { $0.id == toolId }) {
                    _ = self.messages[targetIdx].updateToolCall(id: toolId) { item in
                        item.status = isErr ? .failed : .completed
                        if let res = resultText, !res.isEmpty {
                            item.output = res
                            item.summary = res
                        }
                    }
                } else {
                    _ = self.messages[targetIdx].updateLastRunningToolCall { item in
                        item.status = isErr ? .failed : .completed
                        if let res = resultText, !res.isEmpty {
                            item.output = res
                            item.summary = res
                        }
                    }
                }
                if self.currentStreamMessageId != nil {
                    self.statusMessage = nil
                }
            case "usage_update":
                if let used = update.used, let size = update.size, size > 0 {
                    self.contextUsagePercentage = Int(round(Double(used) / Double(size) * 100.0))
                }
            case "session_info_update", "available_commands_update":
                break
            default:
                if !chunk.isEmpty {
                    self.messages[targetIdx].appendText(chunk)
                }
            }
        }
    }

    public func client(_ client: ACPClient, didRequestPermission request: ACPRequestPermissionParams, requestId: JSONRPCID) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentSessionId == nil || self.currentSessionId == request.sessionId else { return }

            let rawInput = request.toolCall.rawInput ?? [:]
            let command = Self.extractFirstString(from: rawInput, keys: [
                "command", "CommandLine", "command_line", "commandLine", "cmd", "script", "shell"
            ])
            let title = request.toolCall.title
                ?? command
                ?? "Permission required for \(request.toolCall.kind ?? "tool")"

            self.pendingPermission = AgentPermissionRequest(
                requestId: requestId,
                sessionId: request.sessionId,
                toolCallId: request.toolCall.toolCallId,
                title: title,
                kind: request.toolCall.kind,
                command: command,
                options: request.options
            )
            self.status = .busy
            self.statusMessage = "Waiting for permission..."
        }
    }

    public override func respondToPermission(optionId: String?) {
        guard let permission = pendingPermission else { return }
        client.respondToPermission(requestId: permission.requestId, optionId: optionId)
        pendingPermission = nil
        status = .busy
        statusMessage = "Agent is thinking..."
    }

    public func client(_ client: ACPClient, didLog message: String) {}

    public func client(_ client: ACPClient, didExecuteTool toolName: String, path: String?, details: String?) {
        ACPLogger.log("MANAGER didExecuteTool: toolName=\(toolName), path=\(path ?? "nil"), details=\(details ?? "nil")")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let streamId = self.currentStreamMessageId,
               let idx = self.messages.firstIndex(where: { $0.id == streamId }) {
                if let rIdx = self.messages[idx].toolCalls.lastIndex(where: { $0.status == .running }) {
                    let toolID = self.messages[idx].toolCalls[rIdx].id
                    _ = self.messages[idx].updateToolCall(id: toolID) { item in
                        item.toolName = toolName
                        if let path {
                            item.path = path
                            item.title = (path as NSString).lastPathComponent
                        }
                        if item.summary == nil { item.summary = details }
                        item.status = .completed
                    }
                } else {
                    let item = ToolCallItem(
                        toolName: toolName,
                        path: path,
                        title: path.map { ($0 as NSString).lastPathComponent },
                        summary: details,
                        status: .completed
                    )
                    self.messages[idx].appendToolCall(item)
                }
            }
            self.updateLiveGitDiffState()
        }
    }

    public func client(_ client: ACPClient, didExecuteFSWrite path: String, oldContent: String?, newContent: String) {
        ACPLogger.log("MANAGER didExecuteFSWrite: path=\(path), oldContent.count=\(oldContent?.count ?? 0), newContent.count=\(newContent.count)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let filename = (path as NSString).lastPathComponent
            if let streamId = self.currentStreamMessageId,
               let idx = self.messages.firstIndex(where: { $0.id == streamId }) {
                if let rIdx = self.messages[idx].toolCalls.lastIndex(where: { $0.status == .running || $0.shortToolName == "Edit" || $0.path == path }) {
                    let toolID = self.messages[idx].toolCalls[rIdx].id
                    _ = self.messages[idx].updateToolCall(id: toolID) { item in
                        item.toolName = "fs/write_text_file"
                        item.path = path
                        item.title = filename
                        item.descriptionText = nil
                        item.oldContent = oldContent
                        item.newContent = newContent
                        item.status = .completed
                    }
                } else {
                    let item = ToolCallItem(
                        toolName: "fs/write_text_file",
                        path: path,
                        title: filename,
                        oldContent: oldContent,
                        newContent: newContent,
                        status: .completed
                    )
                    self.messages[idx].appendToolCall(item)
                }
            }
            self.updateLiveGitDiffState()
        }
    }

    private func updateLiveGitDiffState() {
        guard status == .busy, !currentWorkingDirectory.isEmpty, let snapshot = preTurnSnapshot else { return }
        let (liveSum, _) = AgentGitChangesDetector.computeTurnSummary(
            workingDirectory: currentWorkingDirectory,
            snapshot: snapshot
        )
        if let liveSum {
            self.liveEditedSummary = liveSum
        }
    }

    public func client(_ client: ACPClient, didDisconnectWith error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.status = .disconnected
            self.currentSessionId = nil
            self.pendingPermission = nil
            self.initializationState = .notStarted
            self.initializationTask = nil
            if let err = error {
                self.statusMessage = err
            }
        }
    }

    private static func extractFirstString(from dict: [String: AnyCodableSendable], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key]?.description, !val.isEmpty {
                return val
            }
        }
        // ACP producers use a mix of camelCase, snake_case, and occasionally
        // capitalized field names. Match those spellings without requiring a
        // new parser branch for every agent implementation.
        for (actualKey, value) in dict {
            guard keys.contains(where: { $0.caseInsensitiveCompare(actualKey) == .orderedSame }) else { continue }
            let string = value.description
            if !string.isEmpty {
                return string
            }
        }
        return nil
    }
}
