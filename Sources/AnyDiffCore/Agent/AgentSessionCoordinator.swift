import Foundation
import Combine

public struct AgentPreset: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var name: String
    public var command: String
    public var arguments: String
    public var iconName: String
    public var colorName: String
    public var providerName: String
    public var summary: String
    public let isMock: Bool
    public var isCustom: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, command, arguments, iconName, colorName
        case providerName, summary, isMock, isCustom
    }

    public var effectiveCommand: String {
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArgs.isEmpty {
            return command
        }
        return "\(command) \(trimmedArgs)"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        command: String,
        arguments: String = "",
        iconName: String = "sparkles",
        colorName: String = "green",
        providerName: String = "",
        summary: String = "",
        isMock: Bool = false,
        isCustom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.iconName = iconName
        self.colorName = colorName
        self.providerName = providerName
        self.summary = summary
        self.isMock = isMock
        self.isCustom = isCustom
    }

    public static let codex = AgentPreset(
        id: "codex",
        name: "Codex",
        command: "CODEX_PATH=\"$(command -v codex || true)\" npx -y @agentclientprotocol/codex-acp",
        iconName: "openai",
        colorName: "white",
        providerName: "OpenAI",
        summary: "Codex ACP over stdio via npx"
    )
    public static let agy = AgentPreset(
        id: "agy",
        name: "Antigravity",
        command: "command -v agy-acp-server >/dev/null 2>&1 && agy-acp-server || agy --acp",
        iconName: "googlegemini",
        colorName: "blue",
        providerName: "Google",
        summary: "Google Antigravity ACP server"
    )
    public static let claude = AgentPreset(
        id: "claude",
        name: "Claude Code",
        command: "npx -y @agentclientprotocol/claude-agent-acp",
        iconName: "claude",
        colorName: "orange",
        providerName: "Anthropic",
        summary: "Claude Code agent over ACP"
    )
    #if DEBUG
    public static let mock = AgentPreset(
        id: "mock",
        name: "Mock Agent",
        command: "",
        iconName: "tray.fill",
        colorName: "purple",
        providerName: "Offline",
        summary: "Offline interactive demo & test mode",
        isMock: true
    )
    public static let defaultPresets: [AgentPreset] = [.codex, .agy, .claude, .mock]
    #else
    public static let defaultPresets: [AgentPreset] = [.codex, .agy, .claude]
    #endif
    public static var allPresets: [AgentPreset] { defaultPresets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? "sparkles"
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName) ?? "green"
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        isMock = try container.decodeIfPresent(Bool.self, forKey: .isMock) ?? false
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(iconName, forKey: .iconName)
        try container.encode(colorName, forKey: .colorName)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(summary, forKey: .summary)
        try container.encode(isMock, forKey: .isMock)
        try container.encode(isCustom, forKey: .isCustom)
    }
}

public final class AgentSessionCoordinator: ObservableObject, @unchecked Sendable {
    @Published public var sessions: [AgentSessionItem] = []
    @Published public var activeSessionId: UUID? = nil
    @Published public var customPresets: [AgentPreset] = [] {
        didSet {
            saveCustomPresets()
        }
    }
    @Published public var selectedPresetId: String {
        didSet {
            UserDefaults.standard.set(selectedPresetId, forKey: "anydiff_selected_agent_preset")
        }
    }
    @Published public var isMockAgent: Bool {
        didSet {
            UserDefaults.standard.set(isMockAgent, forKey: "anydiff_agent_is_mock")
        }
    }
    @Published public var isPanelOpen: Bool = true
    @Published public var showStartScreen: Bool = false
    @Published public var activeReviewSummary: AgentEditedFilesSummary? = nil

    public func startReview(summary: AgentEditedFilesSummary) {
        activeReviewSummary = summary
    }

    public func exitReview() {
        activeReviewSummary = nil
    }

    public struct ActiveImagePreviewState: Equatable, Sendable {
        public var images: [AgentImageAttachment]
        public var selectedIndex: Int
        public var isDraft: Bool

        public init(images: [AgentImageAttachment], selectedIndex: Int = 0, isDraft: Bool = false) {
            self.images = images
            self.selectedIndex = selectedIndex
            self.isDraft = isDraft
        }
    }

    @Published public var activeImagePreview: ActiveImagePreviewState? = nil

    public func showImagePreview(images: [AgentImageAttachment], selectedIndex: Int = 0, isDraft: Bool = false) {
        activeImagePreview = ActiveImagePreviewState(images: images, selectedIndex: selectedIndex, isDraft: isDraft)
    }

    public func closeImagePreview() {
        activeImagePreview = nil
    }

    public var allPresets: [AgentPreset] {
        AgentPreset.defaultPresets + customPresets
    }

    private var cancellables = Set<AnyCancellable>()

    public init(isMockAgent: Bool? = nil, autoCreateSession: Bool = false) {
        let savedPresetId = UserDefaults.standard.string(forKey: "anydiff_selected_agent_preset") ?? "codex"
        self.selectedPresetId = savedPresetId
        self.customPresets = Self.loadCustomPresets()

        #if DEBUG
        let mock = isMockAgent ?? (UserDefaults.standard.object(forKey: "anydiff_agent_is_mock") as? Bool ?? (savedPresetId == "mock"))
        #else
        let mock = false
        #endif
        self.isMockAgent = mock

        if autoCreateSession {
            #if DEBUG
            let initialPreset = mock ? AgentPreset.mock : (allPresets.first(where: { $0.id == savedPresetId && !$0.isMock }) ?? .codex)
            let initialManager: AgentSessionManager
            if mock {
                initialManager = MockAgentSessionManager()
            } else {
                let acp = ACPAgentSessionManager()
                acp.agentCommand = initialPreset.effectiveCommand
                acp.agentTitle = initialPreset.name
                initialManager = acp
            }
            #else
            let initialPreset = allPresets.first(where: { $0.id == savedPresetId && !$0.isMock }) ?? .codex
            let acp = ACPAgentSessionManager()
            acp.agentCommand = initialPreset.effectiveCommand
            acp.agentTitle = initialPreset.name
            let initialManager: AgentSessionManager = acp
            #endif
            #if DEBUG
            let initialSessionTitle = mock ? "Mock Session" : "Session 1"
            #else
            let initialSessionTitle = "Session 1"
            #endif
            let firstSession = AgentSessionItem(
                title: initialSessionTitle,
                manager: initialManager,
                isMock: mock,
                preset: initialPreset
            )
            firstSession.isCurrentlyActive = true
            self.sessions = [firstSession]
            self.activeSessionId = firstSession.id

            firstSession.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    public var activeSession: AgentSessionItem? {
        sessions.first(where: { $0.id == activeSessionId }) ?? sessions.first
    }

    public var activeManager: AgentSessionManager? {
        activeSession?.manager
    }

    public var liveSessions: [AgentSessionItem] {
        sessions.filter { !$0.isMock }
    }

    public var mockSessions: [AgentSessionItem] {
        sessions.filter { $0.isMock }
    }

    public var hasUnreadUpdates: Bool {
        sessions.contains { $0.id != activeSessionId && $0.hasUnreadUpdates }
    }

    public var hasBackgroundBusy: Bool {
        sessions.contains { $0.id != activeSessionId && $0.manager.status == .busy }
    }

    @discardableResult
    public func createNewSession(workingDirectory: String, preset: AgentPreset? = nil) -> AgentSessionItem {
        #if DEBUG
        let fallbackPreset = isMockAgent ? AgentPreset.mock : AgentPreset.codex
        #else
        let fallbackPreset = AgentPreset.codex
        #endif
        let chosenPreset = preset ?? (allPresets.first(where: { $0.id == selectedPresetId }) ?? fallbackPreset)
        let isMock = chosenPreset.isMock

        let manager: AgentSessionManager
        let title: String
        #if DEBUG
        if isMock {
            let mockManager = MockAgentSessionManager(loadFixtures: false)
            manager = mockManager
            title = "Mock Session \(mockSessions.count + 1)"
        } else {
            let acp = ACPAgentSessionManager()
            acp.agentCommand = chosenPreset.effectiveCommand
            acp.agentTitle = chosenPreset.name
            manager = acp
            title = "\(acp.agentTitle) Session \(liveSessions.count + 1)"
        }
        #else
        let acp = ACPAgentSessionManager()
        acp.agentCommand = chosenPreset.effectiveCommand
        acp.agentTitle = chosenPreset.name
        manager = acp
        title = "\(acp.agentTitle) Session \(liveSessions.count + 1)"
        #endif

        let newSession = AgentSessionItem(
            title: title,
            manager: manager,
            isMock: isMock,
            preset: chosenPreset
        )

        for s in sessions {
            s.isCurrentlyActive = false
        }
        newSession.isCurrentlyActive = true

        sessions.append(newSession)
        activeSessionId = newSession.id
        showStartScreen = false
        self.isMockAgent = isMock
        self.selectedPresetId = chosenPreset.id

        newSession.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if !workingDirectory.isEmpty {
            manager.prepareAgent(workingDirectory: workingDirectory)
        }

        return newSession
    }

    public func selectSession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        for s in sessions {
            s.isCurrentlyActive = (s.id == id)
        }
        activeSessionId = id
        showStartScreen = false
        isMockAgent = session.isMock
        objectWillChange.send()
    }

    public func selectPreset(_ preset: AgentPreset, workingDirectory: String) {
        selectedPresetId = preset.id
        isMockAgent = preset.isMock

        if let active = activeSession, active.manager.messages.isEmpty {
            closeSession(id: active.id)
        }
        _ = createNewSession(workingDirectory: workingDirectory, preset: preset)
    }

    public func closeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]

        session.manager.cancel()
        session.manager.clearSession()

        sessions.remove(at: index)

        if sessions.isEmpty {
            activeSessionId = nil
        } else if activeSessionId == id {
            let next = sessions.last!
            for s in sessions {
                s.isCurrentlyActive = (s.id == next.id)
            }
            activeSessionId = next.id
            isMockAgent = next.isMock
        }
        objectWillChange.send()
    }

    public func cleanEmptySessions() {
        let emptyNonActive = sessions.filter { $0.id != activeSessionId && $0.manager.messages.isEmpty }
        for session in emptyNonActive {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                session.manager.cancel()
                session.manager.clearSession()
                sessions.remove(at: idx)
            }
        }
        objectWillChange.send()
    }

    #if DEBUG
    public func toggleMockMode(workingDirectory: String) {
        let nextMock = !isMockAgent
        let nextPreset: AgentPreset = nextMock ? .mock : .codex
        selectPreset(nextPreset, workingDirectory: workingDirectory)
    }
    #endif

    public func fetchSavedSessions(for preset: AgentPreset, workingDirectory: String) async throws -> [ACPSavedSessionItem] {
        let resolvedWorkingDirectory = normalizedWorkingDirectory(workingDirectory)
        #if DEBUG
        if preset.isMock {
            return [
                ACPSavedSessionItem(
                    sessionId: "mock_ses_001",
                    cwd: resolvedWorkingDirectory,
                    title: "Welcome & Onboarding Tour",
                    updatedAt: "2026-08-23T20:30:00Z"
                ),
                ACPSavedSessionItem(
                    sessionId: "mock_ses_002",
                    cwd: resolvedWorkingDirectory,
                    title: "MultiBuffer Diff Parser Optimization",
                    updatedAt: "2026-08-23T19:15:00Z"
                ),
                ACPSavedSessionItem(
                    sessionId: "mock_ses_003",
                    cwd: resolvedWorkingDirectory,
                    title: "Add Dark Mode & Custom Accents",
                    updatedAt: "2026-08-23T18:00:00Z"
                )
            ]
        }
        #endif

        let client = ACPClient()
        try client.start(command: preset.effectiveCommand, workingDirectory: resolvedWorkingDirectory)
        defer { client.stop() }

        _ = try await client.initialize()
        var sessions: [ACPSavedSessionItem] = []
        var cursor: String?
        var seenCursors = Set<String>()

        repeat {
            let page = try await client.listSessionsPage(
                cwd: resolvedWorkingDirectory,
                cursor: cursor
            )
            sessions.append(contentsOf: page.sessions)

            guard let nextCursor = page.nextCursor,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                break
            }
            cursor = nextCursor
        } while true

        return sessions
    }

    @discardableResult
    public func resumeSavedSession(
        savedSession: ACPSavedSessionItem,
        preset: AgentPreset,
        workingDirectory: String
    ) -> AgentSessionItem {
        if let existing = sessions.first(where: {
            if let acp = $0.manager as? ACPAgentSessionManager, acp.currentSessionId == savedSession.sessionId {
                return true
            }
            return false
        }) {
            selectSession(id: existing.id)
            return existing
        }

        let isMock = preset.isMock
        let manager: AgentSessionManager
        let title = savedSession.displayTitle

        #if DEBUG
        if isMock {
            let mockManager = MockAgentSessionManager(loadFixtures: true)
            mockManager.agentTitle = preset.name
            manager = mockManager
        } else {
            let acp = ACPAgentSessionManager()
            acp.agentCommand = preset.effectiveCommand
            acp.agentTitle = preset.name
            manager = acp
            acp.prepareAgent(
                workingDirectory: normalizedWorkingDirectory(workingDirectory),
                loadSessionId: savedSession.sessionId
            )
        }
        #else
        let acp = ACPAgentSessionManager()
        acp.agentCommand = preset.effectiveCommand
        acp.agentTitle = preset.name
        manager = acp
        acp.prepareAgent(
            workingDirectory: normalizedWorkingDirectory(workingDirectory),
            loadSessionId: savedSession.sessionId
        )
        #endif

        let newSession = AgentSessionItem(
            title: title,
            manager: manager,
            isMock: isMock,
            preset: preset
        )

        for s in sessions {
            s.isCurrentlyActive = false
        }
        newSession.isCurrentlyActive = true

        sessions.append(newSession)
        activeSessionId = newSession.id
        showStartScreen = false
        self.isMockAgent = isMock
        self.selectedPresetId = preset.id

        newSession.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        return newSession
    }

    private func normalizedWorkingDirectory(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    public func togglePanel() {
        isPanelOpen.toggle()
    }

    public func prepareActiveSession(workingDirectory: String) {
        guard !workingDirectory.isEmpty else { return }
        activeManager?.prepareAgent(workingDirectory: workingDirectory)
    }

    public func openStartScreen() {
        showStartScreen = true
        objectWillChange.send()
    }

    @discardableResult
    public func addCustomPreset(name: String, command: String, arguments: String = "", colorName: String = "teal", iconName: String = "terminal") -> AgentPreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = AgentPreset(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? "Custom Agent" : trimmedName,
            command: trimmedCommand,
            arguments: trimmedArgs,
            iconName: iconName,
            colorName: colorName,
            isMock: false,
            isCustom: true
        )
        customPresets.append(preset)
        return preset
    }

    public func deleteCustomPreset(id: String) {
        customPresets.removeAll(where: { $0.id == id })
        if selectedPresetId == id {
            selectedPresetId = "codex"
        }
    }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "anydiff_custom_agent_presets")
        }
    }

    private static func loadCustomPresets() -> [AgentPreset] {
        guard let data = UserDefaults.standard.data(forKey: "anydiff_custom_agent_presets"),
              let presets = try? JSONDecoder().decode([AgentPreset].self, from: data) else {
            return []
        }
        return presets
    }
}
