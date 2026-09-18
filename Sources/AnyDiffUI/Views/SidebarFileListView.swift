import SwiftUI
import AnyDiffCore

public struct SidebarFileListView: View {
    public var fileDiffs: [FileDiff]
    public var theme: Theme
    public var emptyMessage: String
    public var isReloading: Bool
    public var isStreaming: Bool
    public var streamingCount: Int
    public var comparisonTarget: ComparisonTarget
    public var isWatchModeEnabled: Bool
    @ObservedObject public var reviewManager: ReviewManager
    @Binding public var selectedFilePath: String?
    public var onReload: () -> Void
    public var onToggleWatchMode: (() -> Void)?
    public var onBack: (() -> Void)?
    public var onSwitchToFiles: (() -> Void)?
    public var onSwitchToHistory: (() -> Void)?

    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @FocusState private var isSearchFocused: Bool
    @State private var isTitleHovered: Bool = false

    public init(
        fileDiffs: [FileDiff],
        theme: Theme,
        emptyMessage: String = "No changed files",
        isReloading: Bool = false,
        isStreaming: Bool = false,
        streamingCount: Int = 0,
        comparisonTarget: ComparisonTarget = .workingTree,
        isWatchModeEnabled: Bool = true,
        reviewManager: ReviewManager,
        selectedFilePath: Binding<String?>,
        onReload: @escaping () -> Void,
        onToggleWatchMode: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onSwitchToFiles: (() -> Void)? = nil,
        onSwitchToHistory: (() -> Void)? = nil
    ) {
        self.fileDiffs = fileDiffs
        self.theme = theme
        self.emptyMessage = emptyMessage
        self.isReloading = isReloading
        self.isStreaming = isStreaming
        self.streamingCount = streamingCount
        self.comparisonTarget = comparisonTarget
        self.isWatchModeEnabled = isWatchModeEnabled
        self.reviewManager = reviewManager
        self._selectedFilePath = selectedFilePath
        self.onReload = onReload
        self.onToggleWatchMode = onToggleWatchMode
        self.onBack = onBack
        self.onSwitchToFiles = onSwitchToFiles
        self.onSwitchToHistory = onSwitchToHistory
    }

    private var filteredFiles: [FileDiff] {
        if searchText.isEmpty {
            return fileDiffs
        }
        return fileDiffs.filter { $0.displayPath.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { headerGeo in
                PanelHeaderView(
                    theme: theme,
                    onBack: onBack
                ) {
                    headerLeadingView(availableWidth: headerGeo.size.width)
                } actions: {
                    headerTrailingActions(availableWidth: headerGeo.size.width)
                }
                .frame(width: headerGeo.size.width, height: 28, alignment: .leading)
            }
            .frame(height: 28)

            if isSearchVisible {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            fileListArea
        }
        .background(Color(theme.background).ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .windowToolbar)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(theme.gutterForeground))
                .font(.system(size: 11))
            TextField("Filter changed files...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color(theme.foreground))
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(theme.gutterForeground))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color(theme.gutterBackground))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func headerLeadingView(availableWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            if let onSwitch = onSwitchToFiles {
                Button(action: onSwitch) {
                    Text(isStreaming ? "Loading..." : "CHANGES")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(isStreaming ? .accentColor : Color(theme.foreground))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isTitleHovered ? Color(theme.gutterForeground).opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isTitleHovered = hovering
                }
                .help("Switch to Project Files (Cmd+2)")
            } else {
                Text(isStreaming ? "Loading..." : "CHANGES")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(isStreaming ? .accentColor : Color(theme.foreground))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .lineLimit(1)
                    .fixedSize()
            }

            if availableWidth >= 165 || isStreaming {
                let count = isStreaming ? (streamingCount > 0 ? streamingCount : filteredFiles.count) : filteredFiles.count
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Color(theme.gutterForeground).opacity(0.12))
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    @ViewBuilder
    private func headerTrailingActions(availableWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            // Action buttons progressively collapse/hide when space is tight
            if availableWidth >= 215 || isReloading {
                Button(action: onReload) {
                    ZStack {
                        if isReloading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(theme.gutterForeground))
                        }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .disabled(isReloading)
                .help("Reload Git Diff (Cmd+R)")
            }

            if availableWidth >= 245 || isSearchVisible {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchVisible.toggle()
                        if isSearchVisible {
                            isSearchFocused = true
                        } else {
                            searchText = ""
                            isSearchFocused = false
                        }
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5))
                        .foregroundColor(isSearchVisible ? Color(theme.foreground) : Color(theme.gutterForeground))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help(isSearchVisible ? "Hide Search" : "Filter changed files")
            }

            // +- stats or branch badge is ALWAYS at the far right edge ("справа справа")
            targetComparisonBadge
                .padding(.leading, (availableWidth >= 215 || isReloading) ? 2 : 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var targetComparisonBadge: some View {
        switch comparisonTarget {
        case .baseBranch(let base):
            Text("\(base)...")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(4)
                .lineLimit(1)
        case .directBranch(let branch):
            Text("→ \(branch)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
        case .commit(let hash, _):
            HStack(spacing: 5) {
                Text(String(hash.prefix(7)))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)
                    .lineLimit(1)

                let totalAdds = fileDiffs.reduce(0) { $0 + $1.additions }
                let totalDels = fileDiffs.reduce(0) { $0 + $1.deletions }
                if totalAdds > 0 {
                    Text("+\(totalAdds)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffAddedGutter))
                        .lineLimit(1)
                }
                if totalDels > 0 {
                    Text("-\(totalDels)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffDeletedGutter))
                        .lineLimit(1)
                }
            }
            .fixedSize()
        case .workingTree, .remote:
            let totalAdds = fileDiffs.reduce(0) { $0 + $1.additions }
            let totalDels = fileDiffs.reduce(0) { $0 + $1.deletions }
            if totalAdds > 0 || totalDels > 0 {
                HStack(spacing: 5) {
                    if totalAdds > 0 {
                        Text("+\(totalAdds)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(theme.diffAddedGutter))
                            .lineLimit(1)
                    }
                    if totalDels > 0 {
                        Text("-\(totalDels)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(theme.diffDeletedGutter))
                            .lineLimit(1)
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var fileListArea: some View {
        if filteredFiles.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text(searchText.isEmpty ? emptyMessage : "No matching files")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VirtualizedFileListView(
                files: filteredFiles,
                theme: theme,
                reviewManager: reviewManager,
                selectedFilePath: $selectedFilePath
            )
            .background(Color(theme.background))
        }
    }
}
