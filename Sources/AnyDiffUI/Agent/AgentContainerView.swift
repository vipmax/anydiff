import SwiftUI
import AnyDiffCore

public struct AgentContainerView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
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

    public init(
        coordinator: AgentSessionCoordinator,
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
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.selectedFilePath = selectedFilePath
        self.fileDiffsSummary = fileDiffsSummary
        self.toolcallColorMode = toolcallColorMode
        self.onClose = onClose
        self.onReview = onReview
        self.onOpenURL = onOpenURL
    }

    private var accentColor: Color {
        coordinator.activeSession?.preset.color ?? .accentColor
    }

    private var isShowingStartScreen: Bool {
        coordinator.showStartScreen || coordinator.activeSession == nil
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
                if !coordinator.showStartScreen, let activeSession = coordinator.activeSession {
                    AgentPanelView(
                        agentManager: activeSession.manager,
                        theme: theme,
                        workingDirectory: workingDirectory,
                        currentSelectedFile: selectedFilePath,
                        fileDiffsSummary: fileDiffsSummary,
                        agentAccentColor: activeSession.preset.color,
                        agentIcon: activeSession.preset.iconName,
                        toolcallColorMode: toolcallColorMode,
                        onReview: onReview,
                        onPreviewImages: { imgs, idx, isDraft in
                            coordinator.showImagePreview(images: imgs, selectedIndex: idx, isDraft: isDraft)
                        },
                        onOpenURL: onOpenURL
                    )
                    .id(activeSession.id)
                } else {
                    AgentStartScreenView(
                        coordinator: coordinator,
                        theme: theme,
                        workingDirectory: workingDirectory
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(alignment: .center, spacing: 4) {
            if let activeSession = coordinator.activeSession {
                Button(action: { isSessionsPresented.toggle() }) {
                    Text(activeSession.preset.name)
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
                        onClose: { isSessionsPresented = false }
                    )
                }
                .onHover { isSessionsHovered = $0 }

                Button(action: {
                    activeSession.isNotificationsEnabled.toggle()
                }) {
                    Image(systemName: activeSession.isNotificationsEnabled ? "bell.fill" : "bell.slash")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                        .foregroundColor(activeSession.isNotificationsEnabled
                            ? accentColor
                            : Color(nsColor: .secondaryLabelColor).opacity(0.85))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(
                    accentColor: accentColor,
                    isActive: activeSession.isNotificationsEnabled
                ))
                .help(activeSession.isNotificationsEnabled
                    ? "Sound notifications enabled (Click to mute)"
                    : "Sound notifications disabled (Click to enable)")
            }

            if coordinator.activeSession != nil {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = coordinator.createNewSession(workingDirectory: workingDirectory)
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
                        if isShowingStartScreen {
                            if let active = coordinator.activeSession {
                                coordinator.selectSession(id: active.id)
                            }
                        } else {
                            coordinator.openStartScreen()
                        }
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
