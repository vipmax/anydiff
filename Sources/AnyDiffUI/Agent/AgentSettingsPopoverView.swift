import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSettingsPopoverView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String
    public var activeSessionId: UUID?
    public var onClose: () -> Void
    public var onSelectSession: ((UUID) -> Void)?
    public var onNewSession: (() -> Void)?

    public init(
        coordinator: AgentSessionCoordinator,
        theme: Theme,
        workingDirectory: String,
        activeSessionId: UUID? = nil,
        onClose: @escaping () -> Void,
        onSelectSession: ((UUID) -> Void)? = nil,
        onNewSession: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.activeSessionId = activeSessionId
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
                            canClose: coordinator.sessions.count > 1,
                            theme: theme,
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
            }

            Divider()
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            // Footer
            HStack {
                Text("Toggle Panel: Cmd+Opt+A")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                Spacer()
                Text("AnyDiff Agent")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
        }
        .padding(6)
        .frame(width: 300)
    }
}
