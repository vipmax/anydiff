import Foundation
import Combine

public struct AgentPreset: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var name: String
    public var version: String?
    public var command: String
    public var arguments: String
    public var iconName: String
    public var colorName: String
    public var providerName: String
    public var summary: String
    public let isMock: Bool
    public var isCustom: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, version, command, arguments, iconName, colorName
        case providerName, summary, isMock, isCustom
    }

    public var effectiveCommand: String {
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArgs = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArgs.isEmpty {
            return trimmedCmd
        }
        return "\(trimmedCmd) \(trimmedArgs)"
    }

    /// If the preset command points directly to a local filesystem executable file (e.g. "/path/to/bin" or '"/path/to/bin"'), returns that normalized path.
    public var executablePathIfLocal: String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawPath: String?
        if trimmed.hasPrefix("\"") {
            if let secondQuote = trimmed.dropFirst().firstIndex(of: "\"") {
                rawPath = String(trimmed[trimmed.index(after: trimmed.startIndex)..<secondQuote])
            }
        } else if trimmed.hasPrefix("'") {
            if let secondQuote = trimmed.dropFirst().firstIndex(of: "'") {
                rawPath = String(trimmed[trimmed.index(after: trimmed.startIndex)..<secondQuote])
            }
        } else {
            let firstToken = trimmed.components(separatedBy: .whitespaces).first ?? ""
            if !firstToken.isEmpty {
                rawPath = firstToken
            }
        }

        guard let path = rawPath else { return nil }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("./") || path.hasPrefix("../") {
            return (path as NSString).expandingTildeInPath
        }
        return nil
    }

    /// Checks whether the preset's executable is present and runnable on disk (if it references a local path).
    /// Always returns true for mock presets and commands resolved via PATH (like `npx` or shell pipelines).
    public var isExecutableAvailable: Bool {
        if isMock { return true }
        if let localPath = executablePathIfLocal {
            return FileManager.default.isExecutableFile(atPath: localPath)
        }
        return true
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        version: String? = nil,
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
        self.version = version
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
    public static let defaultPresets: [AgentPreset] = [.mock]
    #else
    public static let defaultPresets: [AgentPreset] = []
    #endif
    public static var allPresets: [AgentPreset] { defaultPresets }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
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
        try container.encodeIfPresent(version, forKey: .version)
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
    @Published public var updatingAgentIds: Set<String> = []
    private var autoUpdateTask: Task<Void, Never>?
    public let userDefaults: UserDefaults

    public static var defaultUserDefaults: UserDefaults = .standard

    @Published public var selectedPresetId: String {
        didSet {
            userDefaults.set(selectedPresetId, forKey: "anydiff_selected_agent_preset")
        }
    }
    @Published public var isMockAgent: Bool {
        didSet {
            userDefaults.set(isMockAgent, forKey: "anydiff_agent_is_mock")
        }
    }
    public static let isRightPanelOpenKey = "anydiff_is_right_panel_open"
    public static var isPanelOpenKey: String { isRightPanelOpenKey }
    @Published public var isPanelOpen: Bool {
        didSet {
            userDefaults.set(isPanelOpen, forKey: Self.isRightPanelOpenKey)
        }
    }
    public var isRightPanelOpen: Bool {
        get { isPanelOpen }
        set { isPanelOpen = newValue }
    }
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

    public init(
        isMockAgent: Bool? = nil,
        autoCreateSession: Bool = false,
        enablePeriodicAutoUpdate: Bool = false,
        userDefaults: UserDefaults? = nil
    ) {
        let defaults = userDefaults ?? Self.defaultUserDefaults
        self.userDefaults = defaults
        #if DEBUG
        let defaultId = "mock"
        #else
        let defaultId = ""
        #endif
        let savedPresetId = defaults.string(forKey: "anydiff_selected_agent_preset") ?? defaultId
        self.selectedPresetId = savedPresetId
        self.customPresets = Self.loadCustomPresets(from: defaults)

        #if DEBUG
        let mock = isMockAgent ?? (defaults.object(forKey: "anydiff_agent_is_mock") as? Bool ?? (savedPresetId == "mock"))
        #else
        let mock = false
        #endif
        self.isMockAgent = mock
        self.isPanelOpen = defaults.object(forKey: Self.isRightPanelOpenKey) as? Bool ?? true

        if autoCreateSession {
            #if DEBUG
            let initialPreset = mock ? AgentPreset.mock : (allPresets.first(where: { $0.id == savedPresetId && !$0.isMock }) ?? (allPresets.first(where: { !$0.isMock }) ?? AgentPreset(id: "live", name: "Agent", command: "")))
            let initialManager: AgentSessionManager
            if mock {
                let mockManager = MockAgentSessionManager()
                mockManager.presetId = initialPreset.id
                mockManager.userDefaults = defaults
                initialManager = mockManager
            } else {
                let acp = ACPAgentSessionManager()
                acp.presetId = initialPreset.id
                acp.userDefaults = defaults
                acp.agentCommand = initialPreset.effectiveCommand
                acp.agentTitle = initialPreset.name
                initialManager = acp
            }
            #else
            let initialPreset = allPresets.first(where: { $0.id == savedPresetId && !$0.isMock }) ?? (allPresets.first(where: { !$0.isMock }) ?? AgentPreset(id: "live", name: "Agent", command: ""))
            let acp = ACPAgentSessionManager()
            acp.presetId = initialPreset.id
            acp.userDefaults = defaults
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

        if enablePeriodicAutoUpdate {
            startPeriodicAutoUpdate()
        }
    }

    deinit {
        stopPeriodicAutoUpdate()
    }

    public var activeSession: AgentSessionItem? {
        sessions.first(where: { $0.id == activeSessionId }) ?? sessions.first
    }

    public var activeManager: AgentSessionManager? {
        activeSession?.manager
    }

    /// Forwards file change notifications to the active agent session while it is working.
    public func notifyFileSystemChanged() {
        guard let activeManager, activeManager.isBusyOrStreaming else { return }
        activeManager.notifyFileSystemChanged()
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
        let fallbackPreset = isMockAgent ? AgentPreset.mock : (allPresets.first(where: { !$0.isMock }) ?? AgentPreset(id: "live", name: "Agent", command: ""))
        #else
        let fallbackPreset = allPresets.first(where: { !$0.isMock }) ?? AgentPreset(id: "live", name: "Agent", command: "")
        #endif
        let chosenPreset = preset ?? (allPresets.first(where: { $0.id == selectedPresetId }) ?? fallbackPreset)
        let isMock = chosenPreset.isMock

        let manager: AgentSessionManager
        let title: String
        #if DEBUG
        if isMock {
            let mockManager = MockAgentSessionManager(loadFixtures: false)
            mockManager.presetId = chosenPreset.id
            mockManager.userDefaults = userDefaults
            manager = mockManager
            title = "Mock Session \(mockSessions.count + 1)"
        } else {
            let acp = ACPAgentSessionManager()
            acp.presetId = chosenPreset.id
            acp.userDefaults = userDefaults
            acp.agentCommand = chosenPreset.effectiveCommand
            acp.agentTitle = chosenPreset.name
            manager = acp
            title = "\(acp.agentTitle) Session \(liveSessions.count + 1)"
        }
        #else
        let acp = ACPAgentSessionManager()
        acp.presetId = chosenPreset.id
        acp.userDefaults = userDefaults
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

        if !chosenPreset.isExecutableAvailable {
            let missingPath = chosenPreset.executablePathIfLocal ?? chosenPreset.command
            manager.status = .error("Executable not found on disk: \(missingPath)")
            manager.statusMessage = "Agent executable missing. Please re-download from ACP Registry."
        } else if !workingDirectory.isEmpty {
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
        let nextPreset: AgentPreset = nextMock ? .mock : (allPresets.first(where: { !$0.isMock }) ?? .mock)
        selectPreset(nextPreset, workingDirectory: workingDirectory)
    }
    #endif

    public func fetchSavedSessions(
        for preset: AgentPreset,
        workingDirectory: String,
        onPage: (@Sendable @MainActor ([ACPSavedSessionItem]) -> Void)? = nil
    ) async throws -> [ACPSavedSessionItem] {
        let resolvedWorkingDirectory = normalizedWorkingDirectory(workingDirectory)
        #if DEBUG
        if preset.isMock {
            let mockItems = [
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
            if let onPage {
                await onPage(mockItems)
            }
            return mockItems
        }
        #endif

        guard preset.isExecutableAvailable else {
            let missingPath = preset.executablePathIfLocal ?? preset.command
            throw ACPClientError.executableNotFound(missingPath)
        }

        let client = ACPClient()
        try client.start(command: preset.effectiveCommand, workingDirectory: resolvedWorkingDirectory)
        defer { client.stop() }

        _ = try await client.initialize()
        var sessions: [ACPSavedSessionItem] = []
        var cursor: String?
        var seenCursors = Set<String>()

        repeat {
            try Task.checkCancellation()
            let page = try await client.listSessionsPage(
                cwd: resolvedWorkingDirectory,
                cursor: cursor
            )
            sessions.append(contentsOf: page.sessions)
            if let onPage, !page.sessions.isEmpty {
                await onPage(page.sessions)
            }

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
            if let acp = $0.manager as? ACPAgentSessionManager,
               (acp.currentSessionId == savedSession.sessionId || acp.targetLoadSessionId == savedSession.sessionId) {
                return true
            }
            return false
        }) {
            if existing.manager.messages.isEmpty, let acp = existing.manager as? ACPAgentSessionManager {
                acp.prepareAgent(
                    workingDirectory: normalizedWorkingDirectory(workingDirectory),
                    loadSessionId: savedSession.sessionId
                )
            }
            selectSession(id: existing.id)
            showStartScreen = false
            return existing
        }

        let isMock = preset.isMock
        let manager: AgentSessionManager
        let title = savedSession.displayTitle

        #if DEBUG
        if isMock {
            let mockManager = MockAgentSessionManager(loadFixtures: true)
            mockManager.presetId = preset.id
            mockManager.userDefaults = userDefaults
            mockManager.agentTitle = preset.name
            manager = mockManager
        } else {
            let acp = ACPAgentSessionManager()
            acp.presetId = preset.id
            acp.userDefaults = userDefaults
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
        acp.presetId = preset.id
        acp.userDefaults = userDefaults
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
            selectedPresetId = allPresets.first?.id ?? ""
        }
    }

    // MARK: - Registry Agents Management

    public func isAgentInstalled(id: String) -> Bool {
        allPresets.contains(where: { $0.id == id })
    }

    /// Returns true if the agent is registered as a preset, but its required local binary is missing from disk.
    public func hasMissingBinary(id: String) -> Bool {
        guard let preset = allPresets.first(where: { $0.id == id }) else { return false }
        return !preset.isExecutableAvailable
    }

    public func installedVersion(for id: String) -> String? {
        guard let preset = allPresets.first(where: { $0.id == id }) else { return nil }
        if let v = preset.version, !v.isEmpty {
            return v
        }
        // Fallback: extract version folder from command path if set (e.g. .../bin/<id>/<version>/...)
        let components = preset.command.components(separatedBy: "/")
        if let binIndex = components.firstIndex(where: { $0 == id }), binIndex + 1 < components.count {
            let candidate = components[binIndex + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'/"))
            if !candidate.isEmpty && !candidate.contains(".par") && !candidate.contains(".exe") {
                return candidate
            }
        }
        return nil
    }

    public func hasUpdateAvailable(for entry: ACPRegistryAgentEntry) -> Bool {
        guard isAgentInstalled(id: entry.id) else { return false }
        guard let currentVer = installedVersion(for: entry.id) else {
            return true
        }
        return currentVer != entry.version
    }

    public func isAgentUpdating(id: String) -> Bool {
        updatingAgentIds.contains(id)
    }

    public func isAgentInActiveUse(id: String) -> Bool {
        sessions.contains { session in
            session.preset.id == id && session.manager.status != .disconnected
        }
    }

    public func startPeriodicAutoUpdate(interval: TimeInterval = 3600) {
        autoUpdateTask?.cancel()
        autoUpdateTask = Task { [weak self] in
            // Initial check 3 seconds after startup
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await self?.checkForAgentUpdates()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                _ = await self?.checkForAgentUpdates()
            }
        }
    }

    public func stopPeriodicAutoUpdate() {
        autoUpdateTask?.cancel()
        autoUpdateTask = nil
    }

    @discardableResult
    public func checkForAgentUpdates(
        registryService: ACPRegistryService = .shared,
        forceRefresh: Bool = false
    ) async -> [String] {
        guard let registryAgents = try? await registryService.fetchAgents(forceRefresh: forceRefresh) else {
            return []
        }

        let candidates: [ACPRegistryAgentEntry] = await MainActor.run {
            registryAgents.filter { entry in
                hasUpdateAvailable(for: entry) && !isAgentInActiveUse(id: entry.id)
            }
        }

        var updatedIds: [String] = []

        for entry in candidates {

            await MainActor.run {
                updatingAgentIds.insert(entry.id)
                objectWillChange.send()
            }

            do {
                if entry.currentPlatformBinaryTarget != nil {
                    let binaryPath = try await registryService.downloadAndInstallBinary(for: entry)
                    await MainActor.run {
                        _ = installRegistryAgent(entry, binaryPath: binaryPath)
                        updatingAgentIds.remove(entry.id)
                        objectWillChange.send()
                    }
                    updatedIds.append(entry.id)
                } else if entry.distribution.npx != nil {
                    await MainActor.run {
                        _ = installRegistryAgent(entry)
                        updatingAgentIds.remove(entry.id)
                        objectWillChange.send()
                    }
                    updatedIds.append(entry.id)
                } else {
                    await MainActor.run {
                        updatingAgentIds.remove(entry.id)
                        objectWillChange.send()
                    }
                }
            } catch {
                await MainActor.run {
                    updatingAgentIds.remove(entry.id)
                    objectWillChange.send()
                }
            }
        }

        return updatedIds
    }

    @discardableResult
    public func installRegistryAgent(_ entry: ACPRegistryAgentEntry, binaryPath: String? = nil) -> AgentPreset {
        let wasSelected = (selectedPresetId == entry.id)
        deleteCustomPreset(id: entry.id)
        let preset = entry.toAgentPreset(binaryInstalledPath: binaryPath)
        customPresets.append(preset)
        if wasSelected {
            selectedPresetId = entry.id
        }
        return preset
    }

    public func uninstallRegistryAgent(id: String) {
        deleteCustomPreset(id: id)
        ACPRegistryBinaryDownloader.removeAgent(agentId: id)
        objectWillChange.send()
    }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            userDefaults.set(data, forKey: "anydiff_custom_agent_presets")
        }
    }

    private static func loadCustomPresets(from defaults: UserDefaults) -> [AgentPreset] {
        guard let data = defaults.data(forKey: "anydiff_custom_agent_presets"),
              let presets = try? JSONDecoder().decode([AgentPreset].self, from: data) else {
            return []
        }
        return presets
    }
}
