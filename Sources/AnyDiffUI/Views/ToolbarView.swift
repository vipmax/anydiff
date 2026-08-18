import SwiftUI
import AnyDiffCore

public struct ToolbarView: View {
    @Binding public var selectedTheme: Theme
    @Binding public var viewMode: DiffViewMode
    @Binding public var contextLines: Int
    @Binding public var fontSize: CGFloat
    public var isWatchMode: Binding<Bool>?
    @ObservedObject public var reviewManager: ReviewManager
    public var onOpenGitRepo: () -> Void
    public var onPasteDiff: () -> Void
    public var onReload: () -> Void
    public var onExpandAll: () -> Void
    public var onCollapseAll: () -> Void

    public init(
        selectedTheme: Binding<Theme>,
        viewMode: Binding<DiffViewMode>,
        contextLines: Binding<Int>,
        fontSize: Binding<CGFloat>,
        isWatchMode: Binding<Bool>? = nil,
        reviewManager: ReviewManager,
        onOpenGitRepo: @escaping () -> Void,
        onPasteDiff: @escaping () -> Void,
        onReload: @escaping () -> Void,
        onExpandAll: @escaping () -> Void,
        onCollapseAll: @escaping () -> Void
    ) {
        self._selectedTheme = selectedTheme
        self._viewMode = viewMode
        self._contextLines = contextLines
        self._fontSize = fontSize
        self.isWatchMode = isWatchMode
        self.reviewManager = reviewManager
        self.onOpenGitRepo = onOpenGitRepo
        self.onPasteDiff = onPasteDiff
        self.onReload = onReload
        self.onExpandAll = onExpandAll
        self.onCollapseAll = onCollapseAll
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                reloadAndSourceMenu
                Divider().frame(height: 16)
                viewModePicker
                contextAndExcerptControls
                Divider().frame(height: 16)
                fontSizeControls
                Divider().frame(height: 16)
                themePickerMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(selectedTheme.gutterBackground))
    }

    @ViewBuilder
    private var reloadAndSourceMenu: some View {
        Button(action: onReload) {
            Image(systemName: "arrow.clockwise")
        }
        .help("Reload Git Diff (Cmd+R)")
        .keyboardShortcut("r", modifiers: .command)
        .buttonStyle(.plain)

        if let watch = isWatchMode {
            Button(action: { watch.wrappedValue.toggle() }) {
                Image(systemName: watch.wrappedValue ? "bolt.fill" : "bolt.slash")
                    .foregroundColor(watch.wrappedValue ? .green : .secondary)
            }
            .help(watch.wrappedValue ? "Watch Mode Active (Auto-reloads diff on file changes). Click to pause." : "Watch Mode Paused: click to enable auto-reload.")
            .buttonStyle(.plain)
        }

        Menu {
            Button(action: onReload) {
                Label("Reload Current Directory Diff", systemImage: "arrow.clockwise")
            }
            Button(action: onOpenGitRepo) {
                Label("Open Local Git Repo...", systemImage: "folder")
            }
            Button(action: onPasteDiff) {
                Label("Paste Git Diff...", systemImage: "doc.on.clipboard")
            }
        } label: {
            Label("Diff Source", systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var viewModePicker: some View {
        Picker("", selection: $viewMode) {
            ForEach(DiffViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
    }

    @ViewBuilder
    private var contextAndExcerptControls: some View {
        Menu {
            Button("0 Lines (Hunk Only)") { contextLines = 0 }
            Button("3 Lines (Standard)") { contextLines = 3 }
            Button("5 Lines") { contextLines = 5 }
            Button("10 Lines") { contextLines = 10 }
        } label: {
            Label("Context: \(contextLines)L", systemImage: "arrow.up.and.down.text.horizontal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Button(action: onExpandAll) {
            Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
        }
        .help("Expand all excerpts")
        .buttonStyle(.plain)

        Button(action: onCollapseAll) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
        }
        .help("Collapse all excerpts")
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var fontSizeControls: some View {
        HStack(spacing: 6) {
            Button(action: { fontSize = max(9, fontSize - 1) }) {
                Text("A").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Decrease font size (Cmd+-)")
            .keyboardShortcut("-", modifiers: .command)

            Text("\(Int(fontSize))pt")
                .font(.system(size: 11, design: .monospaced))

            Button(action: { fontSize = min(28, fontSize + 1) }) {
                Text("A").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Increase font size (Cmd+=)")
            .keyboardShortcut("=", modifiers: .command)
        }
    }

    @ViewBuilder
    private var themePickerMenu: some View {
        Menu {
            ForEach(Theme.allThemes, id: \.id) { theme in
                Button(theme.name) {
                    selectedTheme = theme
                }
            }
        } label: {
            Label(selectedTheme.name, systemImage: "paintpalette")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
