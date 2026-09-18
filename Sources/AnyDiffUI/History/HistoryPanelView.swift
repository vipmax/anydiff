import SwiftUI
import AppKit
import AnyDiffCore

public struct HistoryPanelView: View {
    public var directory: String
    public var theme: Theme
    public var comparisonTarget: ComparisonTarget
    public var workingChangesCount: Int
    public var reloadToken: UInt64
    public var onSelectCommit: (GitCommit) -> Void
    public var onSelectCommitFile: ((GitCommit, String) -> Void)?
    public var onSelectWorkingChanges: () -> Void
    public var onBack: (() -> Void)?
    public var onSwitchToChanges: (() -> Void)?
    public var onSwitchToFiles: (() -> Void)?

    @State private var commits: [GitCommit] = []
    @State private var graphRows: [GraphRow] = []
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreCommits: Bool = true
    @State private var showAllBranches: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @FocusState private var isSearchFocused: Bool
    @State private var isTitleHovered: Bool = false

    private static let batchSize = 150

    public init(
        directory: String,
        theme: Theme,
        comparisonTarget: ComparisonTarget,
        workingChangesCount: Int = 0,
        reloadToken: UInt64 = 0,
        onSelectCommit: @escaping (GitCommit) -> Void,
        onSelectCommitFile: ((GitCommit, String) -> Void)? = nil,
        onSelectWorkingChanges: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        onSwitchToChanges: (() -> Void)? = nil,
        onSwitchToFiles: (() -> Void)? = nil
    ) {
        self.directory = directory
        self.theme = theme
        self.comparisonTarget = comparisonTarget
        self.workingChangesCount = workingChangesCount
        self.reloadToken = reloadToken
        self.onSelectCommit = onSelectCommit
        self.onSelectCommitFile = onSelectCommitFile
        self.onSelectWorkingChanges = onSelectWorkingChanges
        self.onBack = onBack
        self.onSwitchToChanges = onSwitchToChanges
        self.onSwitchToFiles = onSwitchToFiles
    }

    private var selectedCommitHash: String? {
        if case .commit(let hash, _) = comparisonTarget {
            return hash
        }
        return nil
    }

    private var isWorkingChangesSelected: Bool {
        comparisonTarget == .workingTree
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

            if isLoading && commits.isEmpty {
                loadingView
            } else if commits.isEmpty {
                emptyView
            } else {
                VirtualizedCommitGraphListView(
                    rows: graphRows,
                    directory: directory,
                    selectedCommitHash: selectedCommitHash,
                    isWorkingChangesSelected: isWorkingChangesSelected,
                    workingChangesFileCount: workingChangesCount,
                    theme: theme,
                    onSelectCommit: onSelectCommit,
                    onSelectCommitFile: onSelectCommitFile,
                    onSelectWorkingChanges: onSelectWorkingChanges,
                    onLoadMore: {
                        loadMoreCommits()
                    }
                )
            }
        }
        .background(Color(theme.background).ignoresSafeArea())
        .onAppear {
            loadInitialCommits()
        }
        .onChange(of: directory) { newDir in
            loadInitialCommits(directory: newDir, clearImmediately: true)
        }
        .onChange(of: reloadToken) { _ in
            loadInitialCommits(directory: directory, clearImmediately: commits.isEmpty)
        }
        .onChange(of: showAllBranches) { _ in
            loadInitialCommits(clearImmediately: true)
        }
        .onChange(of: searchText) { _ in
            rebuildGraphLayout()
        }
    }

    @ViewBuilder
    private func headerLeadingView(availableWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            if let onSwitch = onSwitchToChanges ?? onSwitchToFiles {
                Button(action: onSwitch) {
                    Text("HISTORY")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(theme.foreground))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isTitleHovered ? Color(theme.gutterForeground).opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isTitleHovered = $0 }
                .help("Switch to Git Changes (Cmd+1)")
            } else {
                Text("HISTORY")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(theme.foreground))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .lineLimit(1)
                    .fixedSize()
            }

            if availableWidth >= 160 && !commits.isEmpty {
                Text("\(commits.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground))
            }
        }
    }

    @ViewBuilder
    private func headerTrailingActions(availableWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            // Toggle All Branches / Current Branch
            Button(action: {
                showAllBranches.toggle()
            }) {
                Image(systemName: showAllBranches ? "arrow.triangle.branch" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 11))
                    .foregroundColor(showAllBranches ? .accentColor : Color(theme.gutterForeground))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help(showAllBranches ? "Showing all branches (--all)" : "Showing current branch only")

            // Toggle Search
            Button(action: {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isSearchVisible.toggle()
                    if isSearchVisible {
                        isSearchFocused = true
                    } else {
                        searchText = ""
                    }
                }
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(isSearchVisible ? .accentColor : Color(theme.gutterForeground))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Filter commits (Cmd+F)")

            // Reload
            Button(action: {
                loadInitialCommits()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(Color(theme.gutterForeground))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(isLoading ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoading)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Reload commit history")
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(theme.gutterForeground))
                .font(.system(size: 11))

            TextField("Filter commits (message, author, hash)...", text: $searchText)
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
    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading commit history...")
                .font(.system(size: 12))
                .foregroundColor(Color(theme.gutterForeground))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.5))
            Text("No commits found")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(theme.foreground))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading & Graph Construction

    private func loadInitialCommits(directory targetDir: String? = nil, clearImmediately: Bool = true) {
        let dir = targetDir ?? directory
        guard !dir.isEmpty else {
            commits = []
            graphRows = []
            isLoading = false
            hasMoreCommits = false
            return
        }

        if clearImmediately {
            commits = []
            graphRows = []
        }
        isLoading = true
        hasMoreCommits = true

        let all = showAllBranches
        let limit = Self.batchSize

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = GitLogReader.shared.readCommits(
                directory: dir,
                limit: limit,
                skip: 0,
                all: all
            )

            DispatchQueue.main.async {
                guard self.directory == dir else { return }
                self.commits = loaded
                self.hasMoreCommits = loaded.count >= limit
                self.isLoading = false
                self.rebuildGraphLayout()
            }
        }
    }

    private func loadMoreCommits() {
        guard !isLoadingMore, hasMoreCommits, !directory.isEmpty else { return }
        isLoadingMore = true

        let dir = directory
        let all = showAllBranches
        let skip = commits.count
        let limit = Self.batchSize

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = GitLogReader.shared.readCommits(
                directory: dir,
                limit: limit,
                skip: skip,
                all: all
            )

            DispatchQueue.main.async {
                if loaded.isEmpty {
                    self.hasMoreCommits = false
                } else {
                    self.commits.append(contentsOf: loaded)
                    self.hasMoreCommits = loaded.count >= limit
                    self.rebuildGraphLayout()
                }
                self.isLoadingMore = false
            }
        }
    }

    private func rebuildGraphLayout() {
        let filtered: [GitCommit]
        if searchText.isEmpty {
            filtered = commits
        } else {
            let query = searchText.lowercased()
            filtered = commits.filter { commit in
                commit.summary.lowercased().contains(query) ||
                commit.authorName.lowercased().contains(query) ||
                commit.shortHash.lowercased().contains(query) ||
                commit.hash.lowercased().contains(query)
            }
        }

        let includeWorkingChanges = searchText.isEmpty
        self.graphRows = GitGraphLayoutEngine.shared.buildLayout(
            commits: filtered,
            includeWorkingChanges: includeWorkingChanges
        )
    }
}
