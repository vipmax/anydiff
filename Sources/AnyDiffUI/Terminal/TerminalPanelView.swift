import SwiftUI
import AnyDiffCore

/// Terminal panel containing the header with controls (clear, restart, kill, status) and interactive terminal grid.
public struct TerminalPanelView: View {
    @ObservedObject public var session: TerminalSession
    public var theme: Theme
    public var fontSize: CGFloat
    public var onBack: (() -> Void)?

    @State private var isHoveringKill = false

    public init(
        session: TerminalSession,
        theme: Theme,
        fontSize: CGFloat = 12,
        onBack: (() -> Void)? = nil
    ) {
        self.session = session
        self.theme = theme
        self.fontSize = fontSize
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                theme: theme,
                onBack: onBack
            ) {
                headerLeadingView
            } actions: {
                headerTrailingActions
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)

            TerminalView(session: session, theme: theme, fontSize: fontSize)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(theme.background))
        .onAppear {
            if !session.isRunning && session.exitCode == nil {
                session.start()
            }
        }
    }

    @ViewBuilder
    private var headerLeadingView: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(theme.accentColor))

            Text(session.title.isEmpty ? "Terminal" : session.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(theme.foreground))
                .lineLimit(1)

            statusIndicator
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var headerTrailingActions: some View {
        HStack(spacing: 4) {
            if !session.isRunning {
                Button(action: { session.restart() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("Relaunch")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Color(theme.foreground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(theme.gutterForeground).opacity(0.25))
                    )
                }
                .buttonStyle(.plain)
                .help("Relaunch Terminal Process")
            } else {
                Button(action: { session.restart() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(theme.foreground).opacity(0.85))
                }
                .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
                .help("Restart Shell")

                Button(action: { session.terminateProcess() }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(theme.foreground).opacity(0.85))
                }
                .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
                .help("Kill Shell Process")
            }

            Button(action: { session.clear() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.foreground).opacity(0.85))
            }
            .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
            .help("Clear Terminal (Cmd+K)")
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)

            if !session.isRunning {
                if let code = session.exitCode {
                    Text("Exited (\(code))")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                } else {
                    Text("Stopped")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
