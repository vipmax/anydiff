import SwiftUI
import AnyDiffCore

public struct ToolbarView: View {
    @Binding public var selectedTheme: Theme
    @Binding public var viewMode: DiffViewMode
    @Binding public var contextLines: Int
    @Binding public var fontSize: CGFloat
    @ObservedObject public var reviewManager: ReviewManager
    public var onOpenGitRepo: () -> Void
    public var onPasteDiff: () -> Void
    public var onExpandAll: () -> Void
    public var onCollapseAll: () -> Void

    public init(
        selectedTheme: Binding<Theme>,
        viewMode: Binding<DiffViewMode>,
        contextLines: Binding<Int>,
        fontSize: Binding<CGFloat>,
        reviewManager: ReviewManager,
        onOpenGitRepo: @escaping () -> Void,
        onPasteDiff: @escaping () -> Void,
        onExpandAll: @escaping () -> Void,
        onCollapseAll: @escaping () -> Void
    ) {
        self._selectedTheme = selectedTheme
        self._viewMode = viewMode
        self._contextLines = contextLines
        self._fontSize = fontSize
        self.reviewManager = reviewManager
        self.onOpenGitRepo = onOpenGitRepo
        self.onPasteDiff = onPasteDiff
        self.onExpandAll = onExpandAll
        self.onCollapseAll = onCollapseAll
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Source Buttons
            Menu {
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

            Divider().frame(height: 16)

            // View Mode Picker
            Picker("", selection: $viewMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            // Context Lines Menu
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

            // Expand / Collapse all
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

            Spacer()

            // Font Size Stepper
            HStack(spacing: 4) {
                Button(action: { fontSize = max(10, fontSize - 1) }) {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.plain)

                Text("\(Int(fontSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 28)

                Button(action: { fontSize = min(22, fontSize + 1) }) {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)

            // Theme Picker Menu
            Menu {
                ForEach(Theme.allThemes) { theme in
                    Button(theme.name) {
                        selectedTheme = theme
                    }
                }
            } label: {
                Label(selectedTheme.name, systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 16)

            // Review Decision Menu
            Menu {
                Button(action: { reviewManager.decision = .approved }) {
                    Label("Approve PR", systemImage: "checkmark.seal.fill")
                }
                Button(action: { reviewManager.decision = .changesRequested }) {
                    Label("Request Changes", systemImage: "exclamationmark.triangle.fill")
                }
                Button(action: { reviewManager.decision = .commented }) {
                    Label("Submit Comments", systemImage: "bubble.left.and.bubble.right.fill")
                }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(decisionColor)
                        .frame(width: 8, height: 8)
                    Text(reviewManager.decision.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(decisionColor.opacity(0.15))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(selectedTheme.gutterBackground))
    }

    private var decisionColor: Color {
        switch reviewManager.decision {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .blue
        case .pending: return .orange
        }
    }
}
