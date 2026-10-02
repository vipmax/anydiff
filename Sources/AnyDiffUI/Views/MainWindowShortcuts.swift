import SwiftUI
import AnyDiffCore

public struct MainWindowShortcuts: View {
    public var onSelectPanel: (PanelContent) -> Void
    public var onToggleDiffLayout: () -> Void
    public var onReload: () -> Void
    public var onOpenShortcut: () -> Void
    public var onOpenFolder: () -> Void
    public var onOpenSourcePopover: () -> Void
    public var onOpenBrowser: () -> Void
    public var onToggleSearch: () -> Void
    public var onOpenSearch: () -> Void
    public var onNextSearchMatch: () -> Void
    public var onPreviousSearchMatch: () -> Void
    public var onZoomIn: () -> Void
    public var onZoomOut: () -> Void
    public var onZoomReset: () -> Void
    public var onToggleAgent: () -> Void
    public var onToggleMarkdown: () -> Void
    public var onCancel: () -> Void

    public init(
        onSelectPanel: @escaping (PanelContent) -> Void,
        onToggleDiffLayout: @escaping () -> Void,
        onReload: @escaping () -> Void,
        onOpenShortcut: @escaping () -> Void,
        onOpenFolder: @escaping () -> Void,
        onOpenSourcePopover: @escaping () -> Void,
        onOpenBrowser: @escaping () -> Void,
        onToggleSearch: @escaping () -> Void,
        onOpenSearch: @escaping () -> Void,
        onNextSearchMatch: @escaping () -> Void,
        onPreviousSearchMatch: @escaping () -> Void,
        onZoomIn: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onZoomReset: @escaping () -> Void,
        onToggleAgent: @escaping () -> Void,
        onToggleMarkdown: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSelectPanel = onSelectPanel
        self.onToggleDiffLayout = onToggleDiffLayout
        self.onReload = onReload
        self.onOpenShortcut = onOpenShortcut
        self.onOpenFolder = onOpenFolder
        self.onOpenSourcePopover = onOpenSourcePopover
        self.onOpenBrowser = onOpenBrowser
        self.onToggleSearch = onToggleSearch
        self.onOpenSearch = onOpenSearch
        self.onNextSearchMatch = onNextSearchMatch
        self.onPreviousSearchMatch = onPreviousSearchMatch
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onZoomReset = onZoomReset
        self.onToggleAgent = onToggleAgent
        self.onToggleMarkdown = onToggleMarkdown
        self.onCancel = onCancel
    }

    public var body: some View {
        Group {
            Button(action: { onSelectPanel(.changes) }) {}
                .keyboardShortcut("1", modifiers: .command)
            Button(action: { onSelectPanel(.files) }) {}
                .keyboardShortcut("2", modifiers: .command)
            Button(action: { onSelectPanel(.history) }) {}
                .keyboardShortcut("3", modifiers: .command)
            Button(action: { onSelectPanel(.terminal) }) {}
                .keyboardShortcut("4", modifiers: .command)
            Button(action: onToggleDiffLayout) {}
                .keyboardShortcut("d", modifiers: .command)
            Button(action: onReload) {}
                .keyboardShortcut("r", modifiers: .command)
            Button(action: onOpenShortcut) {}
                .keyboardShortcut("o", modifiers: .command)
            Button(action: onOpenFolder) {}
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(action: onOpenSourcePopover) {}
                .keyboardShortcut("u", modifiers: .command)
            Button(action: onOpenBrowser) {}
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(action: onToggleSearch) {}
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(action: onOpenSearch) {}
                .keyboardShortcut("f", modifiers: .command)
            Button(action: onNextSearchMatch) {}
                .keyboardShortcut("g", modifiers: .command)
            Button(action: onPreviousSearchMatch) {}
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button(action: onZoomOut) {}
                .keyboardShortcut("-", modifiers: .command)
            Button(action: onZoomIn) {}
                .keyboardShortcut("+", modifiers: .command)
            Button(action: onZoomIn) {}
                .keyboardShortcut("=", modifiers: .command)
            Button(action: onZoomReset) {}
                .keyboardShortcut("0", modifiers: .command)
            Button(action: onToggleAgent) {}
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(action: onToggleMarkdown) {}
                .keyboardShortcut("e", modifiers: .command)
            Button(action: onCancel) {}
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
    }
}
