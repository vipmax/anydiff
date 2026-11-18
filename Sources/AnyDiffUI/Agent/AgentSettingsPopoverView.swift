import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSettingsPopoverView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String
    public var activeSessionId: UUID?
    public var worktrees: [GitWorktree]
    public var onClose: () -> Void
    public var onSelectSession: ((UUID) -> Void)?
    public var onNewSession: (() -> Void)?

    public init(
        coordinator: AgentSessionCoordinator,
        theme: Theme,
        workingDirectory: String,
        activeSessionId: UUID? = nil,
        worktrees: [GitWorktree] = [],
        onClose: @escaping () -> Void,
        onSelectSession: ((UUID) -> Void)? = nil,
        onNewSession: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.activeSessionId = activeSessionId
        self.worktrees = worktrees
        self.onClose = onClose
        self.onSelectSession = onSelectSession
        self.onNewSession = onNewSession
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coordinator.sessions.isEmpty {
                HStack {
                    Text("SESSIONS (\(coordinator.sessions.count))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let onNewSession = onNewSession {
                        Button(action: {
                            onClose()
                            onNewSession()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 8, weight: .bold))
                                Text("New")
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .foregroundColor(Color(theme.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                VStack(spacing: 2) {
                    ForEach(coordinator.sessions) { session in
                        AgentSessionRowView(
                            session: session,
                            isActive: session.id == (activeSessionId ?? coordinator.activeSessionId),
                            canClose: true,
                            theme: theme,
                            worktrees: worktrees,
                            fallbackWorkingDirectory: workingDirectory,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if let onSelectSession = onSelectSession {
                                        onSelectSession(session.id)
                                    } else {
                                        coordinator.selectSession(id: session.id)
                                    }
                                    onClose()
                                }
                            },
                            onClose: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    coordinator.closeSession(id: session.id)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
        }
        .padding(6)
        .frame(width: 440)
    }
}
