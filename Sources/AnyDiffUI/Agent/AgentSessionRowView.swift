import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSessionRowView: View {
    @ObservedObject public var session: AgentSessionItem
    public let isActive: Bool
    public let canClose: Bool
    public let onSelect: () -> Void
    public let onClose: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false

    public init(
        session: AgentSessionItem,
        isActive: Bool,
        canClose: Bool = true,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.isActive = isActive
        self.canClose = canClose
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    statusIconView

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(session.title)
                                .font(.system(size: 11.5, weight: (isActive || session.hasUnreadUpdates) ? .semibold : .regular))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            if session.hasUnreadUpdates {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 5, height: 5)
                            }
                        }

                        Text(sessionSubtitle)
                            .font(.system(size: 9.5, weight: session.hasUnreadUpdates ? .medium : .regular))
                            .foregroundColor(session.hasUnreadUpdates ? .accentColor : .secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.secondary.opacity(isCloseHovered ? 1.0 : 0.55))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.0)
                .allowsHitTesting(isHovered)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
                .onHover { closeHover in
                    isCloseHovered = closeHover
                }
                .help("Close session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : (isHovered ? Color.secondary.opacity(0.10) : Color.clear))
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var statusIconView: some View {
        switch session.manager.status {
        case .busy:
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 14, height: 14)
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 14)
        case .connecting:
            Circle()
                .fill(Color.yellow)
                .frame(width: 8, height: 8)
                .frame(width: 14)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .frame(width: 14)
        case .idle:
            Circle()
                .fill(sessionColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
                )
                .frame(width: 14)
        case .disconnected:
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .frame(width: 14)
        }
    }

    private var sessionColor: Color {
        session.preset.color
    }

    private var sessionSubtitle: String {
        let prefix = session.manager.agentTitle
        if session.hasUnreadUpdates {
            return "\(prefix) · New reply ready"
        }
        switch session.manager.status {
        case .busy:
            return "\(prefix) · Thinking in background…"
        case .connecting:
            return "\(prefix) · Connecting to agent…"
        case .error(let msg):
            return "\(prefix) · Error: \(msg)"
        case .idle, .disconnected:
            let count = session.manager.messages.count
            if count == 0 {
                return "\(prefix) · Empty session"
            }
            let userCount = session.manager.messages.filter { $0.role == .user }.count
            let promptText = userCount == 1 ? "1 prompt" : "\(userCount) prompts"
            let msgText = count == 1 ? "1 message" : "\(count) messages"
            return "\(prefix) · \(msgText) (\(promptText))"
        }
    }
}
