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
    @Published public var currentSessionId: String? = nil
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
    @Published public var draftPrompt: String = ""
    @Published public var draftAttachments: [AgentImageAttachment] = []
    open var isMock: Bool { false }
    open var isReadyForPrompt: Bool { initializationState == .ready }
    open var canAcceptPrompt: Bool { initializationState != .starting && status != .busy && pendingPermission == nil }
    open var isBusyOrStreaming: Bool { status == .busy || messages.last?.isStreaming == true }

    open var presetId: String? = nil
    public var userDefaults: UserDefaults = .standard

    open var configStorageIdentifier: String {
        if let presetId = presetId?.trimmingCharacters(in: .whitespacesAndNewlines), !presetId.isEmpty {
            return presetId.lowercased()
        }
        let trimmedTitle = agentTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedTitle.isEmpty && trimmedTitle != "agent" {
            return trimmedTitle
        }
        return "default"
    }

    public var configStorageKey: String {
        "anydiff_agent_config_\(configStorageIdentifier)"
    }

    open func savedConfigOptions() -> [String: String] {
        userDefaults.dictionary(forKey: configStorageKey) as? [String: String] ?? [:]
    }

    open func saveConfigOption(id: String, value: String) {
        var current = savedConfigOptions()
        current[id] = value
        userDefaults.set(current, forKey: configStorageKey)
    }

    open func clearSavedConfigOptions() {
        userDefaults.removeObject(forKey: configStorageKey)
    }

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

    /// Applies any agent-provided config option locally and persists it. ACP-backed managers
    /// override this to also sync the choice with `session/set_config_option`.
    open func selectConfigOption(id: String, value: String) {
        saveConfigOption(id: id, value: value)

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

    /// Applies full config options returned from an ACP session or preset.
    open func applyConfigOptions(_ options: [ACPConfigOption]) {
        var updated = options
        if let modelIdx = updated.firstIndex(where: { $0.id == ACPConfigOptionID.model }) {
            let currentVal = updated[modelIdx].currentValue ?? updated[modelIdx].options?.first?.value
            if let currentVal {
                let opt = updated[modelIdx].options?.first(where: { $0.value == currentVal })
                self.selectedModel = opt?.name ?? currentVal
                self.selectedModelValue = currentVal
                if updated[modelIdx].currentValue == nil {
                    updated[modelIdx].currentValue = currentVal
                }
            }
        }
        if let effortIdx = updated.firstIndex(where: { $0.id == ACPConfigOptionID.reasoningEffort }) {
            let currentVal = updated[effortIdx].currentValue ?? updated[effortIdx].options?.first?.value
            if let currentVal {
                let opt = updated[effortIdx].options?.first(where: { $0.value == currentVal })
                self.selectedReasoningEffort = opt?.name ?? currentVal
                self.selectedReasoningEffortValue = currentVal
                if updated[effortIdx].currentValue == nil {
                    updated[effortIdx].currentValue = currentVal
                }
            }
        }
        if let modeIdx = updated.firstIndex(where: { $0.id == ACPConfigOptionID.mode }) {
            let currentVal = updated[modeIdx].currentValue ?? updated[modeIdx].options?.first?.value
            if let currentVal {
                let opt = updated[modeIdx].options?.first(where: { $0.value == currentVal })
                self.selectedAgentMode = opt?.name ?? currentVal
                self.selectedAgentModeValue = currentVal
                if updated[modeIdx].currentValue == nil {
                    updated[modeIdx].currentValue = currentVal
                }
            }
        }
        self.configOptions = updated
    }

    /// Merges saved user preferences into the options provided by the server/agent.
    /// Returns the updated options (with currentValue updated) along with any options
    /// that need to be synced to the active session via `session/set_config_option`.
    open func optionsWithSavedPreferencesMerged(
        _ options: [ACPConfigOption],
        savedPreferences: [String: String]? = nil
    ) -> (merged: [ACPConfigOption], toSync: [(configId: String, value: String)]) {
        let prefs = savedPreferences ?? savedConfigOptions()
        guard !prefs.isEmpty else {
            return (options, [])
        }

        var merged = options
        var toSync: [(configId: String, value: String)] = []

        for (idx, opt) in merged.enumerated() {
            guard let savedVal = prefs[opt.id] else { continue }

            let isValid: Bool
            if let choices = opt.options, !choices.isEmpty {
                isValid = choices.contains { $0.value == savedVal }
            } else if opt.isBoolean {
                isValid = (savedVal.caseInsensitiveCompare("true") == .orderedSame || savedVal.caseInsensitiveCompare("false") == .orderedSame || savedVal == "1" || savedVal == "0")
            } else {
                isValid = !savedVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            guard isValid else { continue }

            if opt.currentValue != savedVal {
                toSync.append((configId: opt.id, value: savedVal))
                merged[idx].currentValue = savedVal
            }
        }

        return (merged, toSync)
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
        draftPrompt = ""
        draftAttachments.removeAll()
        initializationState = .notStarted
        status = .disconnected
        statusMessage = nil
        pendingPermission = nil
    }

    open func restartAgent(workingDirectory: String) {
        status = .disconnected
        statusMessage = nil
    }

    /// Notifies the active session that files on disk have changed (e.g. from the filesystem watcher).
    /// Subclasses override this to update live turn diff state when appropriate.
    open func notifyFileSystemChanged() {}

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
