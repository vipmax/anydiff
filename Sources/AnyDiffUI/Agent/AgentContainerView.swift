import SwiftUI
import AnyDiffCore

public struct AgentContainerView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public let slot: PanelSlot
    public let theme: Theme
    public let workingDirectory: String
    public let selectedFilePath: String?
    public let fileDiffsSummary: String
    public let toolcallColorMode: ToolcallColorMode
    public let isCompactMode: Bool
    public let isGitRepository: Bool
    public let currentBranch: String
    public let worktrees: [GitWorktree]
    public let reloadToken: UInt64
    public let repoName: String
    public let onClose: () -> Void
    public let onReview: (AgentEditedFilesSummary) -> Void
    public let onOpenURL: (URL) -> Void
    public let onSelectWorktree: ((GitWorktree) -> Void)?
    public let onCreateWorktreeForPrompt: ((_ prompt: String, _ baseBranch: String?) async -> Result<String, GitWorktreeError>)?

    @State private var isSessionsPresented: Bool = false
    @State private var isSessionsHovered: Bool = false
    @State private var inputFocusTrigger: Int = 0

    public init(
        coordinator: AgentSessionCoordinator,
        slot: PanelSlot = .right,
        theme: Theme,
        workingDirectory: String,
        selectedFilePath: String?,
        fileDiffsSummary: String,
        toolcallColorMode: ToolcallColorMode,
        isCompactMode: Bool = AgentDisplayPreferences.isCompactMode,
        isGitRepository: Bool = false,
        currentBranch: String = "",
        worktrees: [GitWorktree] = [],
        reloadToken: UInt64 = 0,
        repoName: String = "",
        onClose: @escaping () -> Void,
        onReview: @escaping (AgentEditedFilesSummary) -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onSelectWorktree: ((GitWorktree) -> Void)? = nil,
        onCreateWorktreeForPrompt: ((_ prompt: String, _ baseBranch: String?) async -> Result<String, GitWorktreeError>)? = nil
    ) {
        self.coordinator = coordinator
        self.slot = slot
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.selectedFilePath = selectedFilePath
        self.fileDiffsSummary = fileDiffsSummary
        self.toolcallColorMode = toolcallColorMode
        self.isCompactMode = isCompactMode
        self.isGitRepository = isGitRepository
        self.currentBranch = currentBranch
        self.worktrees = worktrees
        self.reloadToken = reloadToken
        self.repoName = repoName
        self.onClose = onClose
        self.onReview = onReview
        self.onOpenURL = onOpenURL
        self.onSelectWorktree = onSelectWorktree
        self.onCreateWorktreeForPrompt = onCreateWorktreeForPrompt
    }

    private var activeSession: AgentSessionItem? {
        coordinator.activeSession(for: slot)
    }

    private var accentColor: Color {
        activeSession?.preset.color ?? Color(theme.accentColor)
    }

    private var isShowingStartScreen: Bool {
        coordinator.isShowingStartScreen(for: slot)
    }

    private func sessionWorkingDirectory(for session: AgentSessionItem) -> String {
        if let dir = session.manager.workingDirectory, !dir.isEmpty {
            return dir
        }
        return workingDirectory
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                theme: theme,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        onClose()
                    }
                }
            ) {
                headerLeadingContent
            } actions: {
                EmptyView()
            }

            Group {
                if !isShowingStartScreen, let currentSession = activeSession {
                    AgentPanelView(
                        agentManager: currentSession.manager,
                        theme: theme,
                        workingDirectory: sessionWorkingDirectory(for: currentSession),
                        currentSelectedFile: selectedFilePath,
                        fileDiffsSummary: fileDiffsSummary,
                        agentAccentColor: currentSession.preset.color,
                        agentIcon: currentSession.preset.iconName,
                        agentId: currentSession.preset.id,
                        toolcallColorMode: toolcallColorMode,
                        isCompactMode: isCompactMode,
                        externalFocusRequest: inputFocusTrigger,
                        isWindowModalActive: coordinator.activeImagePreview != nil || isSessionsPresented,
                        onReview: onReview,
                        onPreviewImages: { imgs, idx, isDraft in
                            coordinator.showImagePreview(images: imgs, selectedIndex: idx, isDraft: isDraft)
                        },
                        onOpenURL: onOpenURL,
                        onCreateWorktreeForPrompt: onCreateWorktreeForPrompt,
                        onReturnToStartScreen: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                coordinator.setStartScreen(true, for: slot)
                            }
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: Notification.Name("anyDiffAgentStartScreenKeyboardFocus"),
                                    object: slot
                                )
                            }
                        }
                    )
                    .id(currentSession.id)
                } else {
                    AgentStartScreenView(
                        coordinator: coordinator,
                        slot: slot,
                        theme: theme,
                        workingDirectory: workingDirectory,
                        isGitRepository: isGitRepository,
                        currentBranch: currentBranch,
                        worktrees: worktrees,
                        repoName: repoName,
                        onSelectWorktree: onSelectWorktree
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            inputFocusTrigger &+= 1
        }
        .onChange(of: coordinator.isPanelOpen) { isOpen in
            if isOpen {
                inputFocusTrigger &+= 1
            }
        }
    }

    @ViewBuilder
    private var headerLeadingContent: some View {
        if !isShowingStartScreen, let currentSession = activeSession {
            HStack(alignment: .center, spacing: 2) {
                headerActions(for: currentSession)
                    .layoutPriority(1)

                headerWorktreeTitle(for: currentSession)
            }
        }
    }

    @ViewBuilder
    private func headerWorktreeTitle(for currentSession: AgentSessionItem) -> some View {
        AgentHeaderWorktreeView(
            agentManager: currentSession.manager,
            theme: theme,
            fallbackWorkingDirectory: workingDirectory,
            worktrees: worktrees,
            reloadToken: reloadToken,
            onSelectWorktree: onSelectWorktree
        )
    }

    @ViewBuilder
    private func headerActions(for currentSession: AgentSessionItem) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    coordinator.setStartScreen(true, for: slot)
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(AgentToolbarActionButtonStyle(accentColor: accentColor))
            .help("Choose Agent / All Agents (Cmd+Esc)")

            Button(action: { isSessionsPresented.toggle() }) {
                Text(currentSession.preset.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSessionsHovered || isSessionsPresented
                        ? Color(nsColor: .labelColor)
                        : Color(nsColor: .labelColor).opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(minHeight: 20)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accentColor.opacity(
                                isSessionsHovered || isSessionsPresented ? 0.08 : 0
                            ))
                    )
            }
            .buttonStyle(.plain)
            .help("Sessions")
            .popover(isPresented: $isSessionsPresented, arrowEdge: .bottom) {
                AgentSettingsPopoverView(
                    coordinator: coordinator,
                    theme: theme,
                    workingDirectory: sessionWorkingDirectory(for: currentSession),
                    activeSessionId: currentSession.id,
                    worktrees: worktrees,
                    onClose: { isSessionsPresented = false },
                    onSelectSession: { id in
                        coordinator.selectSession(id: id, for: slot)
                    },
                    onNewSession: {
                        coordinator.setStartScreen(true, for: slot)
                    }
                )
            }
            .onHover { isSessionsHovered = $0 }

            AgentHeaderControlsView(
                agentManager: currentSession.manager,
                theme: theme,
                accentColor: accentColor,
                workingDirectory: sessionWorkingDirectory(for: currentSession),
                onSend: {
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffAgentSubmitPrompt"),
                        object: nil
                    )
                }
            )

            Button(action: {
                currentSession.isNotificationsEnabled.toggle()
            }) {
                Image(systemName: currentSession.isNotificationsEnabled ? "bell.fill" : "bell.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
                    .foregroundColor(currentSession.isNotificationsEnabled
                        ? accentColor
                        : Color(nsColor: .secondaryLabelColor).opacity(0.85))
            }
            .buttonStyle(AgentToolbarActionButtonStyle(
                accentColor: accentColor,
                isActive: currentSession.isNotificationsEnabled
            ))
            .help(currentSession.isNotificationsEnabled
                ? "Sound notifications enabled (Click to mute)"
                : "Sound notifications disabled (Click to enable)")

            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    _ = coordinator.createNewSession(workingDirectory: workingDirectory, for: slot)
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(AgentToolbarActionButtonStyle(accentColor: accentColor))
            .help("New Agent Session (Cmd+N)")
        }
    }
}

private struct AgentHeaderWorktreeView: View {
    @ObservedObject var agentManager: AgentSessionManager
    let theme: Theme
    let fallbackWorkingDirectory: String
    let worktrees: [GitWorktree]
    let reloadToken: UInt64
    let onSelectWorktree: ((GitWorktree) -> Void)?

    private var worktreeAccent: Color { Color(theme.accentColor) }

    @State private var isHovered: Bool = false
    @State private var diffStats: GitDiffStats = .zero
    @State private var externalWatchRevision: UInt64 = 0

    private struct StatsRefreshKey: Equatable {
        let directory: String
        let pendingNewWorktree: Bool
        let status: AgentConnectionStatus
        let messageCount: Int
        let liveFileCount: Int
        let liveAdditions: Int
        let liveDeletions: Int
        let reloadToken: UInt64
        let externalWatchRevision: UInt64
    }

    private var statsRefreshKey: StatsRefreshKey {
        StatsRefreshKey(
            directory: sessionWorkingDirectory,
            pendingNewWorktree: agentManager.pendingNewWorktree,
            status: agentManager.status,
            messageCount: agentManager.messages.count,
            liveFileCount: agentManager.liveEditedSummary?.files.count ?? 0,
            liveAdditions: agentManager.liveEditedSummary?.totalAdditions ?? 0,
            liveDeletions: agentManager.liveEditedSummary?.totalDeletions ?? 0,
            reloadToken: reloadToken,
            externalWatchRevision: externalWatchRevision
        )
    }

    private var externalWatchTargetPath: String? {
        guard !agentManager.pendingNewWorktree,
              worktreeBadgeTitle != nil,
              !isViewingSessionWorktree,
              !sessionWorkingDirectory.isEmpty else {
            return nil
        }
        return resolvedPath(sessionWorkingDirectory)
    }

    private var sessionWorkingDirectory: String {
        if let dir = agentManager.workingDirectory, !dir.isEmpty {
            return dir
        }
        return fallbackWorkingDirectory
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private var worktreeBadgeTitle: String? {
        if agentManager.pendingNewWorktree {
            return "New worktree"
        }
        return GitService.shared.nonMainWorktreeDisplayTitle(
            at: sessionWorkingDirectory,
            worktrees: worktrees
        )
    }

    private var isViewingSessionWorktree: Bool {
        guard !agentManager.pendingNewWorktree else { return false }
        return resolvedPath(fallbackWorkingDirectory) == resolvedPath(sessionWorkingDirectory)
    }

    private var mainWorktree: GitWorktree? {
        worktrees.first(where: \.isMain)
    }

    private var targetWorktree: GitWorktree? {
        guard !agentManager.pendingNewWorktree else { return nil }
        let targetSessionPath = resolvedPath(sessionWorkingDirectory)
        if isViewingSessionWorktree {
            guard let main = mainWorktree, resolvedPath(main.path) != targetSessionPath else {
                return nil
            }
            return main
        }
        if let matched = worktrees.first(where: { resolvedPath($0.path) == targetSessionPath }) {
            return matched
        }
        return GitWorktree(path: sessionWorkingDirectory, branch: worktreeBadgeTitle)
    }

    private var canSwitch: Bool {
        onSelectWorktree != nil && targetWorktree != nil
    }

    private var worktreeHelpText: String {
        if agentManager.pendingNewWorktree {
            return "Will create a new worktree from \(sessionWorkingDirectory)"
        }
        guard let title = worktreeBadgeTitle else { return sessionWorkingDirectory }
        let statsSuffix = diffStats.hasChanges ? " (+\(diffStats.additions) -\(diffStats.deletions))" : ""
        if isViewingSessionWorktree, let main = mainWorktree {
            return "Viewing worktree “\(title)”\(statsSuffix) — click to return to \(main.displayTitle) (Uncommitted)"
        }
        if canSwitch {
            return "Click to switch window diff to “\(title)”\(statsSuffix) — \(sessionWorkingDirectory)"
        }
        return sessionWorkingDirectory
    }

    var body: some View {
        if let worktreeTitle = worktreeBadgeTitle {
            Button(action: {
                guard let target = targetWorktree else { return }
                onSelectWorktree?(target)
            }) {
                HStack(spacing: 6) {
                    if !agentManager.pendingNewWorktree && diffStats.hasChanges {
                        HStack(spacing: 3) {
                            if diffStats.additions > 0 {
                                Text("+\(diffStats.additions)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(nsColor: .systemGreen).opacity(0.95))
                            }
                            if diffStats.deletions > 0 {
                                Text("-\(diffStats.deletions)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(nsColor: .systemRed).opacity(0.95))
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10, weight: .medium))
                        Text(worktreeTitle)
                            .font(.system(size: 11, weight: isViewingSessionWorktree ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(badgeForegroundColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(minHeight: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(badgeBackgroundColor)
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSwitch)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .help(worktreeHelpText)
            .frame(minWidth: 0, alignment: .leading)
            .padding(.leading, 4)
            .onChange(of: sessionWorkingDirectory) { _ in
                diffStats = .zero
            }
            .task(id: externalWatchTargetPath) {
                guard let watchPath = externalWatchTargetPath else { return }
                let urls: [URL] = await Task.detached(priority: .utility) {
                    var result = [URL(fileURLWithPath: watchPath, isDirectory: true)]
                    if let gitPaths = GitService.shared.resolveGitPaths(at: watchPath),
                       gitPaths.isLinkedWorktree {
                        result.append(URL(fileURLWithPath: gitPaths.gitDir, isDirectory: true))
                    }
                    return result
                }.value
                guard !Task.isCancelled else { return }
                for await events in FolderWatcher.events(for: urls, latency: 0.3) {
                    if Task.isCancelled { break }
                    guard events.contains(where: { !FolderWatcher.shouldIgnore(path: $0.path) }) else { continue }
                    externalWatchRevision &+= 1
                    if agentManager.isBusyOrStreaming {
                        agentManager.notifyFileSystemChanged()
                    }
                }
            }
            .task(id: statsRefreshKey) {
                guard !agentManager.pendingNewWorktree, !sessionWorkingDirectory.isEmpty else {
                    diffStats = .zero
                    return
                }
                if agentManager.isBusyOrStreaming {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if Task.isCancelled { return }
                }
                let dir = sessionWorkingDirectory
                let stats = await Task.detached(priority: .utility) {
                    GitService.shared.workingTreeDiffStats(at: dir)
                }.value
                guard !Task.isCancelled, sessionWorkingDirectory == dir else { return }
                diffStats = stats
            }
        }
    }

    private var badgeForegroundColor: Color {
        if isViewingSessionWorktree || (isHovered && canSwitch) {
            return worktreeAccent
        }
        return worktreeAccent.opacity(0.88)
    }

    private var badgeBackgroundColor: Color {
        if isViewingSessionWorktree {
            return worktreeAccent.opacity(isHovered && canSwitch ? 0.20 : 0.14)
        }
        return isHovered && canSwitch ? worktreeAccent.opacity(0.08) : Color.clear
    }
}
