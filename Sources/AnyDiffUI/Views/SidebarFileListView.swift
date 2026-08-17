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
    public var currentBranch: String
    @ObservedObject public var reviewManager: ReviewManager
    @Binding public var selectedFilePath: String?
    public var onReload: () -> Void

    @State private var searchText: String = ""

    public init(
        fileDiffs: [FileDiff],
        theme: Theme,
        emptyMessage: String = "No changed files",
        isReloading: Bool = false,
        isStreaming: Bool = false,
        streamingCount: Int = 0,
        comparisonTarget: ComparisonTarget = .workingTree,
        currentBranch: String = "",
        reviewManager: ReviewManager,
        selectedFilePath: Binding<String?>,
        onReload: @escaping () -> Void
    ) {
        self.fileDiffs = fileDiffs
        self.theme = theme
        self.emptyMessage = emptyMessage
        self.isReloading = isReloading
        self.isStreaming = isStreaming
        self.streamingCount = streamingCount
        self.comparisonTarget = comparisonTarget
        self.currentBranch = currentBranch
        self.reviewManager = reviewManager
        self._selectedFilePath = selectedFilePath
        self.onReload = onReload
    }

    private var filteredFiles: [FileDiff] {
        if searchText.isEmpty {
            return fileDiffs
        }
        return fileDiffs.filter { $0.displayPath.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
                .overlay(Color(theme.excerptHeaderBorder).opacity(0.65))
            headerBar
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
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            TextField("Filter changed files...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color(theme.gutterBackground))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 6) {
            Text(isStreaming ? "STREAMING (\(streamingCount > 0 ? streamingCount : filteredFiles.count)...)" : "CHANGED FILES (\(filteredFiles.count))")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isStreaming ? .accentColor : .secondary)

            Button(action: onReload) {
                ZStack {
                    if isReloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .disabled(isReloading)
            .help("Reload Git Diff (Cmd+R)")

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
        case .remote(let ref):
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 8.5))
                Text(ref.owner != nil ? "GitHub" : "Remote")
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(4)
        case .workingTree:
            let totalAdds = fileDiffs.reduce(0) { $0 + $1.additions }
            let totalDels = fileDiffs.reduce(0) { $0 + $1.deletions }
            HStack(spacing: 5) {
                if totalAdds > 0 {
                    Text("+\(totalAdds)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if totalDels > 0 {
                    Text("-\(totalDels)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
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
                selectedFilePath: $selectedFilePath,
                onSelectFile: { path in
                    selectedFilePath = path
                }
            )
            .background(Color(theme.background))
        }
    }
}
