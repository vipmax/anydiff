import Foundation
import Combine

public enum AgentConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case idle
    case busy
    case error(String)
}

public enum AgentInitializationState: Equatable, Sendable {
    case notStarted
    case starting
    case ready
    case failed(String)
}

public struct AgentPermissionRequest: Identifiable, Sendable {
    public let requestId: JSONRPCID
    public let sessionId: String
    public let toolCallId: String
    public let title: String
    public let kind: String?
    public let command: String?
    public let options: [ACPPermissionOption]

    public var id: JSONRPCID { requestId }

    public init(
        requestId: JSONRPCID,
        sessionId: String,
        toolCallId: String,
        title: String,
        kind: String? = nil,
        command: String? = nil,
        options: [ACPPermissionOption]
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.command = command
        self.options = options
    }
}

open class AgentSessionManager: ObservableObject, @unchecked Sendable {
    @Published public var status: AgentConnectionStatus = .disconnected
    @Published public var initializationState: AgentInitializationState = .notStarted
    @Published public var messages: [AgentMessage] = []
    @Published public var isPanelOpen: Bool = true
    @Published public var statusMessage: String? = nil

    @Published public var agentTitle: String = "Codex"
    @Published public var configOptions: [ACPConfigOption] = []
    @Published public var selectedModel: String = ""
    @Published public var selectedModelValue: String = ""
    @Published public var selectedReasoningEffort: String = ""
    @Published public var selectedReasoningEffortValue: String = ""
    @Published public var selectedAgentMode: String = ""
    @Published public var selectedAgentModeValue: String = ""
    @Published public var contextUsagePercentage: Int? = nil
    @Published public var pendingPermission: AgentPermissionRequest? = nil
    @Published public var liveEditedSummary: AgentEditedFilesSummary? = nil
    @Published public var isNotificationsEnabled: Bool = false
    open var isMock: Bool { false }
    open var isReadyForPrompt: Bool { initializationState == .ready }
    open var canAcceptPrompt: Bool { initializationState != .starting && status != .busy && pendingPermission == nil }

    public init() {}

    open func togglePanel() {
        isPanelOpen.toggle()
    }

    open var availableModels: [(name: String, value: String)] {
        if let modelOpt = configOptions.first(where: { $0.id == ACPConfigOptionID.model }), let opts = modelOpt.options, !opts.isEmpty {
            return opts.map { ($0.name, $0.value) }
        }
        return []
    }

    open var availableReasoningEfforts: [(name: String, value: String)] {
        if let effortOpt = configOptions.first(where: { $0.id == ACPConfigOptionID.reasoningEffort }), let opts = effortOpt.options, !opts.isEmpty {
            return opts.map { ($0.name, $0.value) }
        }
        return []
    }

    open var availableAgentModes: [(name: String, value: String, description: String)] {
        if let modeOpt = configOptions.first(where: { $0.id == ACPConfigOptionID.mode }),
           let options = modeOpt.options,
           !options.isEmpty {
            return options.map { ($0.name, $0.value, $0.description ?? "") }
        }
        return []
    }

    /// The agent's complete settings surface. Unknown options are preserved
    /// so the UI can render new agent capabilities without a client release.
    open var availableAgentSettings: [ACPConfigOption] {
        configOptions
    }

    open func selectModel(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.model, value: value)
    }

    open func selectReasoningEffort(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.reasoningEffort, value: value)
    }

    open func selectAgentMode(name: String, value: String) {
        selectConfigOption(id: ACPConfigOptionID.mode, value: value)
    }

    /// Applies any agent-provided config option locally. ACP-backed managers
    /// override this to persist the choice with `session/set_config_option`.
    open func selectConfigOption(id: String, value: String) {
        if let index = configOptions.firstIndex(where: { $0.id == id }) {
            configOptions[index].currentValue = value
        }

        switch id {
        case ACPConfigOptionID.model:
            selectedModelValue = value
            selectedModel = displayName(for: id, value: value) ?? value
        case ACPConfigOptionID.reasoningEffort:
            selectedReasoningEffortValue = value
            selectedReasoningEffort = displayName(for: id, value: value) ?? value
        case ACPConfigOptionID.mode:
            selectedAgentModeValue = value
            selectedAgentMode = displayName(for: id, value: value) ?? value
        default:
            break
        }
    }

    private func displayName(for id: String, value: String) -> String? {
        availableAgentSettings
            .first(where: { $0.id == id })?
            .options?
            .first(where: { $0.value == value })?
            .name
    }

    open func sendPrompt(_ text: String, images: [AgentImageAttachment] = [], workingDirectory: String) {}

    open func sendPrompt(_ text: String, workingDirectory: String) {
        sendPrompt(text, images: [], workingDirectory: workingDirectory)
    }

    /// Prepares the agent independently from sending the first prompt. The
    /// UI calls this when the panel appears so startup never races with the
    /// first keystroke. Mock agents are ready synchronously.
    open func prepareAgent(workingDirectory: String) {}

    open func cancel() {}

    /// Sends the selected permission option back to the agent. ACP-backed
    /// managers override this; the base manager keeps mock agents inert.
    open func respondToPermission(optionId: String?) {}

    open func clearSession() {
        messages.removeAll()
        initializationState = .notStarted
        status = .disconnected
        statusMessage = nil
        pendingPermission = nil
    }

    open func restartAgent(workingDirectory: String) {
        status = .disconnected
        statusMessage = nil
    }

    @discardableResult
    open func revertTurn(messageId: UUID, workingDirectory: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              var summary = messages[index].editedFilesSummary,
              !summary.isReverted else {
            return false
        }
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: workingDirectory, summary: &summary)
        if success {
            summary.isReverted = true
            messages[index].editedFilesSummary = summary
            NotificationCenter.default.post(name: Notification.Name("anyDiffReloadDiff"), object: nil)
            objectWillChange.send()
        }
        return success
    }

    @discardableResult
    open func revertTurn(summary: AgentEditedFilesSummary, workingDirectory: String) -> Bool {
        if let index = messages.firstIndex(where: { $0.editedFilesSummary?.filePaths == summary.filePaths && $0.editedFilesSummary?.baseCommitHash == summary.baseCommitHash }) {
            return revertTurn(messageId: messages[index].id, workingDirectory: workingDirectory)
        }
        var mutSummary = summary
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: workingDirectory, summary: &mutSummary)
        if success {
            mutSummary.isReverted = true
            for i in messages.indices where messages[i].editedFilesSummary?.filePaths == summary.filePaths {
                messages[i].editedFilesSummary = mutSummary
            }
            NotificationCenter.default.post(name: Notification.Name("anyDiffReloadDiff"), object: nil)
            objectWillChange.send()
        }
        return success
    }

    @discardableResult
    open func restoreTurn(messageId: UUID, workingDirectory: String) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              var summary = messages[index].editedFilesSummary,
              summary.isReverted else {
            return false
        }
        let success = AgentTurnRollbackService.restoreTurn(workingDirectory: workingDirectory, summary: summary)
        if success {
            summary.isReverted = false
            messages[index].editedFilesSummary = summary
            NotificationCenter.default.post(name: Notification.Name("anyDiffReloadDiff"), object: nil)
            objectWillChange.send()
        }
        return success
    }

    @discardableResult
    open func restoreTurn(summary: AgentEditedFilesSummary, workingDirectory: String) -> Bool {
        if let index = messages.firstIndex(where: { $0.editedFilesSummary?.filePaths == summary.filePaths && $0.editedFilesSummary?.baseCommitHash == summary.baseCommitHash }) {
            return restoreTurn(messageId: messages[index].id, workingDirectory: workingDirectory)
        }
        let success = AgentTurnRollbackService.restoreTurn(workingDirectory: workingDirectory, summary: summary)
        if success {
            for i in messages.indices where messages[i].editedFilesSummary?.filePaths == summary.filePaths {
                messages[i].editedFilesSummary?.isReverted = false
            }
            NotificationCenter.default.post(name: Notification.Name("anyDiffReloadDiff"), object: nil)
            objectWillChange.send()
        }
        return success
    }
}
