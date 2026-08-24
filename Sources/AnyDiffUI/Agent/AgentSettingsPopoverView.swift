import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSettingsPopoverView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String
    public var onClose: () -> Void

    public init(
        coordinator: AgentSessionCoordinator,
        theme: Theme,
        workingDirectory: String,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coordinator.sessions.isEmpty {
                HStack {
                    Text("SESSIONS (\(coordinator.sessions.count))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                VStack(spacing: 2) {
                    ForEach(coordinator.sessions) { session in
                        AgentSessionRowView(
                            session: session,
                            isActive: session.id == coordinator.activeSessionId,
                            canClose: coordinator.sessions.count > 1,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    coordinator.selectSession(id: session.id)
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
