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
    public let isGitRepository: Bool
    public let currentBranch: String
    public let worktrees: [GitWorktree]
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
        isGitRepository: Bool = false,
        currentBranch: String = "",
        worktrees: [GitWorktree] = [],
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
        self.isGitRepository = isGitRepository
        self.currentBranch = currentBranch
        self.worktrees = worktrees
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
                headerWorktreeTitle
            } actions: {
                headerActions
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
                        externalFocusRequest: inputFocusTrigger,
                        onReview: onReview,
                        onPreviewImages: { imgs, idx, isDraft in
                            coordinator.showImagePreview(images: imgs, selectedIndex: idx, isDraft: isDraft)
                        },
                        onOpenURL: onOpenURL,
                        onCreateWorktreeForPrompt: onCreateWorktreeForPrompt
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
    private var headerWorktreeTitle: some View {
        if !isShowingStartScreen, let currentSession = activeSession {
            AgentHeaderWorktreeView(
                agentManager: currentSession.manager,
                theme: theme,
                fallbackWorkingDirectory: workingDirectory,
                worktrees: worktrees
            )
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(alignment: .center, spacing: 2) {
            if !isShowingStartScreen, let currentSession = activeSession {
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

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        coordinator.setStartScreen(true, for: slot)
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16, height: 16)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(accentColor: accentColor))
                .help("Choose Agent / All Agents")
            }
        }
    }
}

private struct AgentHeaderWorktreeView: View {
    @ObservedObject var agentManager: AgentSessionManager
    let theme: Theme
    let fallbackWorkingDirectory: String
    let worktrees: [GitWorktree]

    @State private var isHovered: Bool = false

    private var sessionWorkingDirectory: String {
        if let dir = agentManager.workingDirectory, !dir.isEmpty {
            return dir
        }
        return fallbackWorkingDirectory
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

    private var worktreeHelpText: String {
        if agentManager.pendingNewWorktree {
            return "Will create a new worktree from \(sessionWorkingDirectory)"
        }
        return sessionWorkingDirectory
    }

    var body: some View {
        if let worktreeTitle = worktreeBadgeTitle {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isHovered ? Color(theme.foreground).opacity(0.85) : Color(theme.gutterForeground))
                Text(worktreeTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color(theme.foreground).opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovered ? Color(theme.excerptHeaderBorder).opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .help(worktreeHelpText)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 4)
        }
    }
}
