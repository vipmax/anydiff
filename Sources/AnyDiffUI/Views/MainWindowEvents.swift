import SwiftUI
import AppKit
import AnyDiffCore

public struct MainWindowEventsModifier: ViewModifier {
    public let onUpdateAppearance: () -> Void
    public let onFocusEditor: () -> Void
    public let onOpenProject: () -> Void
    public let onOpenInBrowser: () -> Void
    public let onReloadDiff: () -> Void
    public let onToggleWatchMode: () -> Void
    public let onToggleLeftPanel: () -> Void
    public let onToggleRightPanel: () -> Void
    public let onSelectTheme: (String) -> Void
    public let onSetDiffLayout: (DiffLayoutMode) -> Void
    public let onFindInProject: () -> Void
    public let onFindNext: () -> Void
    public let onFindPrevious: () -> Void
    public let onZoomIn: () -> Void
    public let onZoomOut: () -> Void
    public let onResetZoom: () -> Void
    public let onResetPanelsLayout: () -> Void
    public let onToolcallColorModeChanged: (ToolcallColorMode) -> Void
    public let onToggleTerminal: (() -> Void)?

    public init(
        onUpdateAppearance: @escaping () -> Void,
        onFocusEditor: @escaping () -> Void,
        onOpenProject: @escaping () -> Void,
        onOpenInBrowser: @escaping () -> Void,
        onReloadDiff: @escaping () -> Void,
        onToggleWatchMode: @escaping () -> Void,
        onToggleLeftPanel: @escaping () -> Void,
        onToggleRightPanel: @escaping () -> Void,
        onSelectTheme: @escaping (String) -> Void,
        onSetDiffLayout: @escaping (DiffLayoutMode) -> Void,
        onFindInProject: @escaping () -> Void,
        onFindNext: @escaping () -> Void,
        onFindPrevious: @escaping () -> Void,
        onZoomIn: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onResetZoom: @escaping () -> Void,
        onResetPanelsLayout: @escaping () -> Void,
        onToolcallColorModeChanged: @escaping (ToolcallColorMode) -> Void,
        onToggleTerminal: (() -> Void)? = nil
    ) {
        self.onUpdateAppearance = onUpdateAppearance
        self.onFocusEditor = onFocusEditor
        self.onOpenProject = onOpenProject
        self.onOpenInBrowser = onOpenInBrowser
        self.onReloadDiff = onReloadDiff
        self.onToggleWatchMode = onToggleWatchMode
        self.onToggleLeftPanel = onToggleLeftPanel
        self.onToggleRightPanel = onToggleRightPanel
        self.onSelectTheme = onSelectTheme
        self.onSetDiffLayout = onSetDiffLayout
        self.onFindInProject = onFindInProject
        self.onFindNext = onFindNext
        self.onFindPrevious = onFindPrevious
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onResetZoom = onResetZoom
        self.onResetPanelsLayout = onResetPanelsLayout
        self.onToolcallColorModeChanged = onToolcallColorModeChanged
        self.onToggleTerminal = onToggleTerminal
    }

    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                onUpdateAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                onUpdateAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusFileInEditor)) { _ in
                onFocusEditor()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
                onUpdateAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification)) { _ in
                onUpdateAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenProject"))) { _ in
                onOpenProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenURL"))) { _ in
                onOpenProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenInBrowser"))) { _ in
                onOpenInBrowser()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentSessionTurnCompleted"))) { notification in
                guard let session = notification.object as? AgentSessionItem else { return }
                let isError = (notification.userInfo?["isError"] as? Bool) ?? false
                if session.isNotificationsEnabled {
                    if isError {
                        SoundFeedback.play(.error)
                    } else {
                        SoundFeedback.play(.completion)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AgentDisplayPreferences.didChangeNotification)) { _ in
                onToolcallColorModeChanged(AgentDisplayPreferences.toolcallColorMode)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentPermissionRequested"))) { notification in
                guard let session = notification.object as? AgentSessionItem else { return }
                if session.isNotificationsEnabled {
                    SoundFeedback.play(.attention)
                    HapticFeedback.perform(.levelChange)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffReloadDiff"))) { _ in
                onReloadDiff()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleWatchMode"))) { _ in
                onToggleWatchMode()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleLeftPanel"))) { _ in
                onToggleLeftPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleRightPanel"))) { _ in
                onToggleRightPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleAgent"))) { _ in
                onToggleRightPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleSidebar"))) { _ in
                onToggleLeftPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleTerminal"))) { _ in
                onToggleTerminal?()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffSelectTheme"))) { notif in
                if let themeId = notif.userInfo?["themeId"] as? String {
                    onSelectTheme(themeId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffSetDiffLayout"))) { notif in
                if let modeStr = notif.userInfo?["mode"] as? String, let m = DiffLayoutMode(rawValue: modeStr) {
                    onSetDiffLayout(m)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffFindInProject"))) { _ in
                onFindInProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffFindNext"))) { _ in
                onFindNext()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffFindPrevious"))) { _ in
                onFindPrevious()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffZoomIn"))) { _ in
                onZoomIn()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffZoomOut"))) { _ in
                onZoomOut()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffResetZoom"))) { _ in
                onResetZoom()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffResetPanelsLayout"))) { _ in
                onResetPanelsLayout()
            }
    }
}
