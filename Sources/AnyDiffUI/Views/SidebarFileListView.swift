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

    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @FocusState private var isSearchFocused: Bool

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
        onToggleWatchMode: (() -> Void)? = nil
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
    }

    private var filteredFiles: [FileDiff] {
        if searchText.isEmpty {
            return fileDiffs
        }
        return fileDiffs.filter { $0.displayPath.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
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
    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(isStreaming ? "Loading \(streamingCount > 0 ? streamingCount : filteredFiles.count)..." : "CHANGES \(filteredFiles.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isStreaming ? .accentColor : Color(theme.gutterForeground))

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

            if case .remote = comparisonTarget {
                // Remote diffs do not have a local directory watcher
            } else if let onToggle = onToggleWatchMode {
                Button(action: onToggle) {
                    Image(systemName: isWatchModeEnabled ? "eye.fill" : "eye.slash")
                        .font(.system(size: 10.5))
                        .foregroundColor(isWatchModeEnabled ? Color(theme.gutterForeground) : Color(theme.gutterForeground).opacity(0.4))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help(isWatchModeEnabled ? "Watch Mode Active: auto-reloading on disk changes (Click to pause, Cmd+Opt+W)" : "Watch Mode Paused: click to enable auto-reload")
            }

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

            Spacer()

            targetComparisonBadge
        }
        .frame(height: 24)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
        case .directBranch(let branch):
            Text("→ \(branch)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(4)
        case .workingTree, .remote:
            let totalAdds = fileDiffs.reduce(0) { $0 + $1.additions }
            let totalDels = fileDiffs.reduce(0) { $0 + $1.deletions }
            HStack(spacing: 5) {
                if totalAdds > 0 {
                    Text("+\(totalAdds)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffAddedGutter))
                }
                if totalDels > 0 {
                    Text("-\(totalDels)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffDeletedGutter))
                }
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
