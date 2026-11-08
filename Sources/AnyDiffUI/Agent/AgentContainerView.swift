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
    public let onClose: () -> Void
    public let onReview: (AgentEditedFilesSummary) -> Void
    public let onOpenURL: (URL) -> Void

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
        onClose: @escaping () -> Void,
        onReview: @escaping (AgentEditedFilesSummary) -> Void,
        onOpenURL: @escaping (URL) -> Void
    ) {
        self.coordinator = coordinator
        self.slot = slot
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.selectedFilePath = selectedFilePath
        self.fileDiffsSummary = fileDiffsSummary
        self.toolcallColorMode = toolcallColorMode
        self.onClose = onClose
        self.onReview = onReview
        self.onOpenURL = onOpenURL
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
                EmptyView()
            } actions: {
                headerActions
            }

            Group {
                if !isShowingStartScreen, let currentSession = activeSession {
                    AgentPanelView(
                        agentManager: currentSession.manager,
                        theme: theme,
                        workingDirectory: workingDirectory,
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
                        onOpenURL: onOpenURL
                    )
                    .id(currentSession.id)
                } else {
                    AgentStartScreenView(
                        coordinator: coordinator,
                        slot: slot,
                        theme: theme,
                        workingDirectory: workingDirectory
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
    private var headerActions: some View {
        HStack(alignment: .center, spacing: 4) {
            if let currentSession = activeSession {
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
                        workingDirectory: workingDirectory,
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
                    workingDirectory: workingDirectory,
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
                        .font(.system(size: 11, weight: .medium))
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
            }

            if activeSession != nil {
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
                        coordinator.setStartScreen(!isShowingStartScreen, for: slot)
                    }
                }) {
                    Image(systemName: isShowingStartScreen ? "chevron.right" : "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .foregroundColor(isShowingStartScreen ? accentColor : Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(
                    accentColor: accentColor,
                    isActive: isShowingStartScreen
                ))
                .help(isShowingStartScreen ? "Back to Chat" : "Choose Agent / All Agents")
            }
        }
    }
}
