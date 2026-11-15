import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSessionRowView: View {
    @ObservedObject public var session: AgentSessionItem
    public let isActive: Bool
    public var isKeyboardSelected: Bool = false
    public let canClose: Bool
    public let theme: Theme
    public let worktrees: [GitWorktree]
    public let fallbackWorkingDirectory: String?
    public let onSelect: () -> Void
    public let onClose: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    @State private var isCloseArmed: Bool = false
    @State private var closeArmResetWorkItem: DispatchWorkItem? = nil
    @State private var isStopHovered: Bool = false
    @State private var isBellHovered: Bool = false
    @State private var isSessionIdHovered: Bool = false
    @State private var isSessionIdCopied: Bool = false
    @State private var copyResetWorkItem: DispatchWorkItem? = nil
    @State private var customAvatar: NSImage? = nil
    @State private var avatarSize: CGFloat = 24
    @State private var showAgentCircle: Bool = false

    public init(
        session: AgentSessionItem,
        isActive: Bool,
        isKeyboardSelected: Bool = false,
        canClose: Bool = true,
        theme: Theme = .zedDark,
        worktrees: [GitWorktree] = [],
        fallbackWorkingDirectory: String? = nil,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.isActive = isActive
        self.isKeyboardSelected = isKeyboardSelected
        self.canClose = canClose
        self.theme = theme
        self.worktrees = worktrees
        self.fallbackWorkingDirectory = fallbackWorkingDirectory
        self.onSelect = onSelect
        self.onClose = onClose
    }

    private var isSessionBusy: Bool {
        session.manager.isBusyOrStreaming || session.manager.status == .busy || session.manager.status == .connecting
    }

    public var body: some View {
        let accentColor = Color(theme.accentColor)

        HStack(alignment: .center, spacing: 10) {
            // Leading avatar + corner status badge
            avatarWithStatusBadge
                .allowsHitTesting(false)

            // 3 lines of session content
            VStack(alignment: .leading, spacing: 3) {
                // Line 1: Prompt title
                line1PromptTitle(accentColor: accentColor)

                // Line 2: Agent name, profile, folder (or worktree id), Bell & Stop/Close grouped on the right
                line2AgentProfileAndLocation(accentColor: accentColor)

                // Line 3: Session ID, Status text
                line3StatusControls(accentColor: accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? accentColor.opacity(0.14) : ((isHovered || isKeyboardSelected) ? Color.secondary.opacity(0.09) : Color.clear))
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isKeyboardSelected ? accentColor.opacity(0.75) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                disarmClose()
            }
        }
        .onChange(of: isSessionBusy) { busy in
            if !busy {
                isStopHovered = false
                disarmClose()
            }
        }
        .contextMenu {
            if let fullId = session.displaySessionId {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullId, forType: .string)
                }) {
                    Label("Copy Session ID (\(session.shortSessionId ?? fullId))", systemImage: "doc.on.doc")
                }
                Divider()
            }
            if canClose {
                Button(role: .destructive, action: onClose) {
                    Label("Close Session", systemImage: "xmark")
                }
            }
        }
        .help(session.displaySessionId != nil ? "Session ID: \(session.displaySessionId!)" : session.title)
        .onAppear {
            refreshAvatar()
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentAvatarProvider.avatarDidChangeNotification)) { _ in
            refreshAvatar()
        }
    }

    // MARK: - Line 1: Prompt title
    @ViewBuilder
    private func line1PromptTitle(accentColor: Color) -> some View {
        HStack(spacing: 5) {
            Text(session.title)
                .font(.system(size: 11.5, weight: (isActive || session.hasUnreadUpdates) ? .semibold : .medium))
                .foregroundColor(isActive ? Color(theme.foreground) : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if session.hasUnreadUpdates {
                Circle()
                    .fill(accentColor)
                    .frame(width: 5, height: 5)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Line 2: Agent name, Profile, Folder (or worktree id), Action buttons
    @ViewBuilder
    private func line2AgentProfileAndLocation(accentColor: Color) -> some View {
        HStack(spacing: 6) {
            Text(session.preset.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(isActive ? Color(theme.foreground).opacity(0.85) : .secondary)
                .lineLimit(1)
                .layoutPriority(1)

            if let profile = session.preset.profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(profile)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(accentColor)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            let location = folderOrWorktreeInfo
            if !location.title.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: location.icon)
                        .font(.system(size: 7.5))
                    Text(location.title)
                        .font(.system(size: 8.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(location.isWorktree ? accentColor : (isActive ? Color(theme.foreground).opacity(0.7) : .secondary.opacity(0.85)))
                .help(location.isWorktree ? "Worktree: \(location.title)" : (session.worktreePath(fallbackWorkingDirectory: fallbackWorkingDirectory) ?? location.title))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Action buttons grouped together on the right
            HStack(spacing: 3) {
                bellButtonView(accentColor: accentColor)

                if isSessionBusy {
                    stopButtonView
                } else if canClose {
                    closeButtonView
                }
            }
            .layoutPriority(2)
        }
    }

    // MARK: - Line 3: Session ID, Status text
    @ViewBuilder
    private func line3StatusControls(accentColor: Color) -> some View {
        HStack(spacing: 6) {
            if let shortId = session.shortSessionId {
                Button(action: { copySessionId(shortId: shortId) }) {
                    ZStack(alignment: .leading) {
                        Text(shortId)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(
                                isSessionIdHovered
                                    ? (isActive ? Color(theme.foreground) : .primary)
                                    : (isActive ? Color(theme.foreground).opacity(0.72) : .secondary.opacity(0.85))
                            )
                            .opacity(isSessionIdCopied ? 0 : 1)

                        if isSessionIdCopied {
                            Text("copied")
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isSessionIdHovered = $0 }
                .help(isSessionIdCopied ? "Copied!" : "Copy Session ID")
                .layoutPriority(1)
            }

            Text(statusText)
                .font(.system(size: 9.5, weight: session.hasUnreadUpdates ? .medium : .regular))
                .foregroundColor(session.hasUnreadUpdates ? accentColor : (isActive ? Color(theme.foreground).opacity(0.75) : .secondary))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
    }

    private func copySessionId(shortId: String) {
        let valueToCopy = session.displaySessionId ?? shortId
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(valueToCopy, forType: .string)

        copyResetWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            isSessionIdCopied = true
        }
        let workItem = DispatchWorkItem { [self] in
            withAnimation(.easeOut(duration: 0.15)) {
                isSessionIdCopied = false
            }
        }
        copyResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: - Trailing Action Buttons

    @ViewBuilder
    private func bellButtonView(accentColor: Color) -> some View {
        Button(action: {
            session.isNotificationsEnabled.toggle()
        }) {
            Image(systemName: session.isNotificationsEnabled ? "bell.fill" : "bell")
                .font(.system(size: 9.5))
                .foregroundColor(bellForegroundColor(accentColor: accentColor))
                .frame(width: 17, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(bellBackgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isBellHovered = $0 }
        .help(session.isNotificationsEnabled ? "Sound notifications enabled for this chat" : "Enable sound notifications for this chat")
    }

    private func bellForegroundColor(accentColor: Color) -> Color {
        if session.isNotificationsEnabled {
            return accentColor
        }
        return Color.secondary.opacity(isBellHovered ? 0.85 : (isHovered ? 0.6 : 0.4))
    }

    private var bellBackgroundColor: Color {
        if isBellHovered {
            return Color.secondary.opacity(0.14)
        }
        return Color.clear
    }

    @ViewBuilder
    private var stopButtonView: some View {
        Button(action: {
            isStopHovered = false
            session.manager.cancel()
        }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(isStopHovered ? Color.red : Color.red.opacity(isHovered ? 0.85 : 0.72))
                .frame(width: 17, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isStopHovered ? Color.red.opacity(0.14) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isStopHovered = hovering
        }
        .help("Stop generation")
    }

    @ViewBuilder
    private var closeButtonView: some View {
        Button(action: handleCloseTap) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(closeForegroundColor)
                .frame(width: 17, height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(closeBackgroundColor)
                )
                .scaleEffect(isCloseArmed ? 1.06 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isCloseArmed)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isCloseHovered = hovering
        }
        .help(isCloseArmed ? "Click again to close session" : "Close session")
    }

    private var closeForegroundColor: Color {
        if isCloseArmed {
            return .white
        }
        return Color.secondary.opacity(isCloseHovered ? 0.95 : (isHovered ? 0.62 : 0.35))
    }

    private var closeBackgroundColor: Color {
        if isCloseArmed {
            return Color.red.opacity(isCloseHovered ? 0.95 : 0.82)
        }
        if isCloseHovered {
            return Color.secondary.opacity(0.14)
        }
        return Color.clear
    }

    private func handleCloseTap() {
        if isCloseArmed {
            disarmClose()
            onClose()
        } else {
            armClose()
        }
    }

    private func armClose() {
        closeArmResetWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            isCloseArmed = true
        }
        let workItem = DispatchWorkItem { [self] in
            withAnimation(.easeOut(duration: 0.15)) {
                isCloseArmed = false
            }
        }
        closeArmResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func disarmClose() {
        closeArmResetWorkItem?.cancel()
        closeArmResetWorkItem = nil
        if isCloseArmed {
            isCloseArmed = false
        }
    }

    // MARK: - Avatar & Status Badge

    private func refreshAvatar() {
        customAvatar = AgentAvatarProvider.customAgentAvatarImage(for: session.preset.id)
        avatarSize = AgentAvatarProvider.currentAgentAvatarSize(for: session.preset.id)
        showAgentCircle = AgentAvatarProvider.shouldShowAgentCircle(for: session.preset.id)
    }

    @ViewBuilder
    private var avatarWithStatusBadge: some View {
        let auraSize = avatarSize + AgentAvatarAuraView.auraPadding(forAvatarSize: avatarSize) * 2

        ZStack(alignment: .bottomTrailing) {
            avatarBaseView
                .background(
                    AgentAvatarAuraRepresentable(theme: theme, isAnimating: isSessionBusy)
                        .frame(width: auraSize, height: auraSize)
                        .allowsHitTesting(false)
                )

            statusBadgeView
                .offset(x: 3, y: 2)
                .allowsHitTesting(false)
        }
        .padding(.trailing, 3)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var avatarBaseView: some View {
        if let custom = customAvatar {
            Image(nsImage: custom)
                .resizable()
                .scaledToFill()
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(Circle())
        } else if showAgentCircle {
            Circle()
                .fill(sessionColor.opacity(isActive ? 0.22 : 0.12))
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    AgentIconView(
                        icon: session.preset.iconName,
                        agentId: session.preset.id,
                        tintColor: sessionColor,
                        size: max(10, ceil(avatarSize * 0.62))
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: max(5, avatarSize * 0.24), style: .continuous)
                .fill(sessionColor.opacity(isActive ? 0.22 : 0.12))
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    AgentIconView(
                        icon: session.preset.iconName,
                        agentId: session.preset.id,
                        tintColor: sessionColor,
                        size: max(10, ceil(avatarSize * 0.56))
                    )
                )
        }
    }

    @ViewBuilder
    private var statusBadgeView: some View {
        if session.manager.pendingPermission != nil {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9))
                .foregroundColor(.orange)
                .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
                .help("Permission required")
        } else if session.manager.status == .connecting {
            Circle()
                .fill(Color.yellow)
                .frame(width: 7, height: 7)
                .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
        } else if isSessionBusy {
            EmptyView()
        } else {
            switch session.manager.status {
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
                    .help(statusText)
            case .idle:
                Circle()
                    .fill(Color.green)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 0.5)
            case .disconnected:
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0.5)
            case .busy, .connecting:
                EmptyView()
            }
        }
    }

    private var sessionColor: Color {
        session.preset.color
    }

    private var folderOrWorktreeInfo: (icon: String, title: String, isWorktree: Bool) {
        if let wtTitle = session.worktreeDisplayTitle(fallbackWorkingDirectory: fallbackWorkingDirectory, worktrees: worktrees) {
            return ("square.stack.3d.up", wtTitle, true)
        }
        let targetPath = session.worktreePath(fallbackWorkingDirectory: fallbackWorkingDirectory) ?? fallbackWorkingDirectory ?? ""
        if !targetPath.isEmpty {
            let folderName = URL(fileURLWithPath: targetPath).lastPathComponent
            if !folderName.isEmpty && folderName != "/" {
                return ("folder", folderName, false)
            }
        }
        return ("folder", "", false)
    }

    private var statusText: String {
        if session.manager.pendingPermission != nil {
            return "Permission required"
        }
        if session.hasUnreadUpdates {
            return "New reply ready"
        }
        switch session.manager.status {
        case .busy:
            return "Thinking in background…"
        case .connecting:
            return "Connecting…"
        case .error(let msg):
            return "Error: \(msg)"
        case .idle, .disconnected:
            let count = session.manager.messages.count
            if count == 0 {
                return "Empty session"
            }
            let userCount = session.manager.messages.filter { $0.role == .user }.count
            let promptText = userCount == 1 ? "1 prompt" : "\(userCount) prompts"
            let msgText = count == 1 ? "1 message" : "\(count) messages"
            return "\(msgText) (\(promptText))"
        }
    }
}
