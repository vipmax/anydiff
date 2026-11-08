import SwiftUI
import AnyDiffCore

/// Terminal panel containing the header with multi-terminal tab controls,
/// display mode switcher (MultiBuffer vs Interactive), background execution, and terminal views.
public struct TerminalPanelView: View {
    @ObservedObject public var coordinator: TerminalCoordinator
    public var theme: Theme
    public var fontSize: CGFloat
    public var onBack: (() -> Void)?

    /// Backward compatibility initializer for single session usage.
    public init(
        session: TerminalSession,
        theme: Theme,
        fontSize: CGFloat = 12,
        onBack: (() -> Void)? = nil
    ) {
        self.coordinator = TerminalCoordinator(singleSession: session)
        self.theme = theme
        self.fontSize = fontSize
        self.onBack = onBack
    }

    /// Primary initializer taking a shared TerminalCoordinator.
    public init(
        coordinator: TerminalCoordinator,
        theme: Theme,
        fontSize: CGFloat = 12,
        onBack: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
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
                tabBarLeadingView
            } actions: {
                headerTrailingActions
            }
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        _ = coordinator.createTab()
                    }
            )
            .zIndex(2)

            if let activeTab = coordinator.activeTab {
                TerminalTabContentView(
                    tab: activeTab,
                    theme: theme,
                    fontSize: fontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyStateView
            }
        }
        .background(Color(theme.background).ignoresSafeArea())
    }

    // MARK: - Tab Bar (Leading)

    @ViewBuilder
    private var tabBarLeadingView: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(coordinator.tabs) { tab in
                        TerminalTabItemView(
                            tab: tab,
                            isActive: tab.id == coordinator.activeTab?.id,
                            canClose: coordinator.tabs.count > 1,
                            theme: theme,
                            onSelect: {
                                coordinator.selectTab(id: tab.id)
                            },
                            onClose: {
                                coordinator.closeTab(id: tab.id)
                            },
                            onCloseOthers: {
                                coordinator.closeOtherTabs(except: tab.id)
                            },
                            onNewTab: {
                                _ = coordinator.createTab()
                            }
                        )
                    }

                    // Empty space between tabs and trailing actions:
                    // double-clicking creates a new terminal tab.
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(minWidth: 40, maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture(count: 2) {
                            _ = coordinator.createTab()
                        }
                        .contextMenu {
                            Button("New Terminal") {
                                _ = coordinator.createTab()
                            }
                        }
                }
                .frame(minWidth: proxy.size.width, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - Header Actions (Trailing)

    @ViewBuilder
    private var headerTrailingActions: some View {
        HStack(spacing: 6) {
            if let tab = coordinator.activeTab {
                // Switch between MultiBuffer and Interactive mode
                if tab.isShowingInteractive {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            tab.displayMode = .multiBuffer
                        }
                    }) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(theme.foreground).opacity(0.85))
                    }
                    .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
                    .help("Switch to MultiBuffer Terminal")
                } else {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            tab.displayMode = .interactive
                            if !tab.blockSession.isProcessRunning && !tab.interactiveSession.isRunning && tab.interactiveSession.exitCode == nil {
                                tab.interactiveSession.start()
                            }
                        }
                    }) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(theme.foreground).opacity(0.85))
                    }
                    .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
                    .help("Switch to Classic Interactive Terminal")
                }

                // If in interactive mode and shell terminated, allow restarting
                if tab.isShowingInteractive && !tab.isRunning {
                    Button(action: { tab.restart() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(theme.foreground).opacity(0.85))
                    }
                    .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
                    .help("Restart Shell")
                }
            }

            // New Tab "+" Button (rightmost, transparent without hover)
            Button(action: {
                _ = coordinator.createTab()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.foreground).opacity(0.85))
            }
            .buttonStyle(ToolbarHoverButtonStyle(minWidth: 20, minHeight: 20))
            .help("New Terminal (Cmd+Shift+T)")
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundColor(Color(theme.gutterForeground))
            Text("No Terminals Open")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(theme.foreground).opacity(0.7))
            Button("New Terminal") {
                _ = coordinator.createTab()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab Item View

private struct TerminalTabItemView: View {
    @ObservedObject var tab: TerminalTab
    var isActive: Bool
    var canClose: Bool
    var theme: Theme
    var onSelect: () -> Void
    var onClose: () -> Void
    var onCloseOthers: () -> Void
    var onNewTab: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isEditingTitle = false
    @State private var editingTitleText = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isEditingTitle {
                TextField("", text: $editingTitleText)
                    .focused($isTitleFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.foreground))
                    .lineLimit(1)
                    .offset(y: 1)
                    .frame(minWidth: 36, maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .padding(.vertical, 3.5)
                    .onSubmit {
                        commitRename()
                    }
                    .onExitCommand {
                        cancelRename()
                    }
                    .onChange(of: isTitleFocused) { focused in
                        if !focused && isEditingTitle {
                            commitRename()
                        }
                    }
            } else {
                Button(action: onSelect) {
                    Text(tab.displayTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isActive ? Color(theme.foreground) : Color(theme.foreground).opacity(0.75))
                        .lineLimit(1)
                        .padding(.leading, 9)
                        .padding(.trailing, 4)
                        .padding(.vertical, 3.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        startRenaming()
                    }
                )
            }

            // Reserved trailing slot (14x14 so the tab layout stays stable and balanced)
            trailingSlot
                .frame(width: 14, height: 14)
                .padding(.trailing, 6)
        }
        .background(
            Capsule(style: .continuous)
                .fill(
                    (isActive || isEditingTitle)
                        ? Color(theme.gutterForeground).opacity(0.2)
                        : (isHovered ? Color(theme.gutterForeground).opacity(0.09) : Color.clear)
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    (isActive || isEditingTitle) ? Color(theme.excerptHeaderBorder).opacity(0.7) : Color.clear,
                    lineWidth: 0.8
                )
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("New Terminal") { onNewTab() }
            Divider()
            Button("Rename...") {
                startRenaming()
            }
            Button("Clear Output") { tab.clear() }
            Button("Restart Shell") { tab.restart() }
            Divider()
            Button("Close Terminal") { onClose() }
            if canClose {
                Button("Close Other Terminals") { onCloseOthers() }
            }
        }
    }

    private func startRenaming() {
        onSelect()
        editingTitleText = tab.displayTitle
        isEditingTitle = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            isTitleFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func commitRename() {
        let trimmed = editingTitleText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            tab.rename(to: "")
        } else if trimmed == tab.displayTitle && tab.customTitle == nil {
            isEditingTitle = false
            return
        } else {
            tab.rename(to: trimmed)
        }
        isEditingTitle = false
    }

    private func cancelRename() {
        isEditingTitle = false
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if isHovered {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(
                        isCloseHovered
                            ? Color(theme.foreground)
                            : Color(theme.foreground).opacity(0.65)
                    )
                    .frame(width: 14, height: 14)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? Color(theme.gutterForeground).opacity(0.35) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
            .help("Close Terminal")
        } else if tab.isRunning {
            Circle()
                .fill(Color(theme.gutterForeground).opacity(0.85))
                .frame(width: 5.5, height: 5.5)
                .help("Command running")
        } else if let code = tab.exitCode, code != 0 {
            Circle()
                .fill(Color.red.opacity(0.85))
                .frame(width: 5.5, height: 5.5)
                .help("Exited with code \(code)")
        } else {
            Circle()
                .fill(Color.green)
                .frame(width: 5.5, height: 5.5)
                .help("Waiting for input")
        }
    }
}

// MARK: - Tab Content View

private struct TerminalTabContentView: View {
    @ObservedObject var tab: TerminalTab
    var theme: Theme
    var fontSize: CGFloat

    var body: some View {
        Group {
            if !tab.isShowingInteractive {
                VStack(spacing: 0) {
                    BlockTerminalView(
                        session: tab.blockSession,
                        theme: theme,
                        fontSize: fontSize,
                        onSwitchToInteractive: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                tab.displayMode = .interactive
                            }
                        }
                    )
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    TerminalInputBarView(
                        session: tab.blockSession,
                        theme: theme,
                        onSwitchToInteractive: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                tab.displayMode = .interactive
                                if !tab.blockSession.isProcessRunning && !tab.interactiveSession.isRunning && tab.interactiveSession.exitCode == nil {
                                    tab.interactiveSession.start()
                                }
                            }
                        }
                    )
                    .zIndex(2)
                }
            } else {
                TerminalView(session: tab.activeTerminalSession, theme: theme, fontSize: fontSize)
                    .id(tab.activeTerminalSession.id)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if tab.isShowingInteractive && !tab.activeTerminalSession.isRunning && tab.activeTerminalSession.exitCode == nil {
                tab.activeTerminalSession.start()
            }
        }
    }
}
