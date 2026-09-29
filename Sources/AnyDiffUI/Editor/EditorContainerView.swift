import SwiftUI
import AnyDiffCore

public struct EditorContainerView: View {
    @ObservedObject public var repo: RepoCoordinator
    @ObservedObject public var review: ReviewCoordinator
    @ObservedObject public var search: SearchCoordinator
    public let theme: Theme
    public let fontSize: CGFloat
    public let activeMarkdownPreviewPath: String?
    public let isReviewActive: Bool

    public let onClosePanel: () -> Void
    public let onToggleLayout: () -> Void
    public let onCloseMarkdown: () -> Void
    public let onOpenFileInEditor: (String) -> Void
    public let onEndReadOnly: () -> Void
    public let onAddComment: (String, Int) -> Void
    public let onOpenExternalIDE: (String, Int?) -> Void
    public let onPreviewMarkdown: (String) -> Void
    public let onOpenInBrowser: () -> Void

    public init(
        repo: RepoCoordinator,
        review: ReviewCoordinator,
        search: SearchCoordinator,
        theme: Theme,
        fontSize: CGFloat,
        activeMarkdownPreviewPath: String?,
        isReviewActive: Bool,
        onClosePanel: @escaping () -> Void,
        onToggleLayout: @escaping () -> Void,
        onCloseMarkdown: @escaping () -> Void,
        onOpenFileInEditor: @escaping (String) -> Void,
        onEndReadOnly: @escaping () -> Void,
        onAddComment: @escaping (String, Int) -> Void,
        onOpenExternalIDE: @escaping (String, Int?) -> Void,
        onPreviewMarkdown: @escaping (String) -> Void,
        onOpenInBrowser: @escaping () -> Void
    ) {
        self.repo = repo
        self.review = review
        self.search = search
        self.theme = theme
        self.fontSize = fontSize
        self.activeMarkdownPreviewPath = activeMarkdownPreviewPath
        self.isReviewActive = isReviewActive
        self.onClosePanel = onClosePanel
        self.onToggleLayout = onToggleLayout
        self.onCloseMarkdown = onCloseMarkdown
        self.onOpenFileInEditor = onOpenFileInEditor
        self.onEndReadOnly = onEndReadOnly
        self.onAddComment = onAddComment
        self.onOpenExternalIDE = onOpenExternalIDE
        self.onPreviewMarkdown = onPreviewMarkdown
        self.onOpenInBrowser = onOpenInBrowser
    }

    // MARK: - Coordinated Properties

    private var isReadOnlyActive: Bool {
        isReviewActive || repo.comparisonTarget.isCommit || review.isActive
    }

    private var displayMap: DisplayMap {
        if search.isActive {
            return search.displayMap
        } else if isReadOnlyActive {
            return review.displayMap
        }
        return repo.displayMap
    }

    private var multiBuffer: MultiBuffer {
        if search.isActive {
            return search.multiBuffer
        } else if isReadOnlyActive {
            return review.multiBuffer
        }
        return repo.multiBuffer
    }

    private var fileDiffs: [FileDiff] {
        isReadOnlyActive ? review.fileDiffs : repo.fileDiffs
    }

    private var diffLayoutMode: DiffLayoutMode {
        if isReadOnlyActive {
            return review.displayMap.layoutMode
        }
        return repo.displayMap.layoutMode
    }

    private var viewStateResetToken: UInt64? {
        isReadOnlyActive ? review.viewStateResetToken : (search.isActive ? search.viewStateResetToken : nil)
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { headerGeo in
                PanelHeaderView(
                    theme: theme,
                    onBack: onClosePanel
                ) {
                    headerLeading(availableWidth: headerGeo.size.width)
                } actions: {
                    headerActions(availableWidth: headerGeo.size.width)
                }
                .frame(width: headerGeo.size.width, height: 28, alignment: .leading)
            }
            .frame(height: 28)

            if search.isActive {
                ProjectSearchBarView(
                    query: $search.query,
                    totalMatchesCount: search.matches.count,
                    activeMatchIndex: search.activeMatchIndex,
                    isSearching: search.isSearching,
                    isTruncated: search.isTruncated,
                    hasExecutedSearch: search.hasExecutedSearch,
                    theme: theme,
                    focusToken: search.focusToken,
                    onSearch: {
                        search.triggerSearch(in: repo.effectiveWorkingDirectory, delay: 0)
                    },
                    onQueryChanged: {
                        search.triggerSearch(in: repo.effectiveWorkingDirectory, delay: 0)
                    },
                    onNextMatch: {
                        search.selectNextMatch()
                    },
                    onPrevMatch: {
                        search.selectPreviousMatch()
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            search.close()
                        }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                if let mdPath = activeMarkdownPreviewPath {
                    MarkdownDocumentView(
                        filePath: mdPath,
                        rootDirectory: repo.effectiveWorkingDirectory,
                        theme: theme,
                        onClose: onCloseMarkdown,
                        onOpenInEditor: {
                            onCloseMarkdown()
                            onOpenFileInEditor(mdPath)
                        }
                    )
                    .id(mdPath)
                } else {
                    editorDetailView

                    if fileDiffs.isEmpty && !isReadOnlyActive && !search.isActive {
                        EmptyDiffView(
                            theme: theme,
                            loadableWorkingDirectory: repo.loadableWorkingDirectory,
                            repoStatus: repo.repoStatus,
                            currentFolderName: repo.currentFolderName,
                            currentLocalPath: repo.currentPath,
                            currentComparisonTarget: repo.comparisonTarget,
                            onOpenLocalFolder: { repo.openGitRepositoryFolder() },
                            onSelectLocalPath: { path in
                                repo.currentPath = path
                                repo.loadCurrentDirectoryDiff()
                            },
                            onOpenRemoteURL: { url in
                                repo.loadRemoteDiff(from: url)
                            },
                            onOpenInBrowser: onOpenInBrowser
                        )
                    } else if search.isActive && search.hasExecutedSearch && search.matches.isEmpty && !search.isSearching && !search.query.isEmpty {
                        SearchEmptyStateView(
                            query: search.query.query,
                            folderName: repo.currentFolderName,
                            theme: theme
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: search.query.query) { _ in
            search.hasExecutedSearch = false
        }
        .background(Color(theme.background))
    }

    // MARK: - Header Views

    private var hasAnyCollapsedFiles: Bool {
        multiBuffer.excerpts.contains { $0.isCollapsed }
    }

    private func toggleCollapseAll() {
        withAnimation(.easeInOut(duration: 0.16)) {
            if hasAnyCollapsedFiles {
                multiBuffer.expandAll()
            } else {
                multiBuffer.collapseAll()
            }
            displayMap.rebuild()
            displayMap.markContentLoaded()
        }
    }

    private var titlePrefix: String {
        if activeMarkdownPreviewPath != nil {
            return "Preview"
        } else if search.isActive {
            return "Search"
        } else if isReviewActive {
            return "Review"
        } else if case .baseBranch(let base) = repo.comparisonTarget {
            return base
        } else if case .directBranch(let branch) = repo.comparisonTarget {
            return branch
        } else if case .remote(let ref) = repo.comparisonTarget {
            return ref.displayTitle
        } else if case .commit(let hash, _) = repo.comparisonTarget {
            return String(hash.prefix(7))
        }
        return "Uncommitted"
    }

    private var commitTooltip: String {
        if case .commit(_, let summary) = repo.comparisonTarget, !summary.isEmpty {
            return summary
        }
        return ""
    }

    @ViewBuilder
    private func headerLeading(availableWidth: CGFloat) -> some View {
        let iconName: String = {
            if activeMarkdownPreviewPath != nil {
                return "doc.text"
            } else if search.isActive {
                return "magnifyingglass"
            } else if case .commit = repo.comparisonTarget {
                return "clock.arrow.circlepath"
            } else {
                return "arrow.triangle.branch"
            }
        }()

        EditorHeaderLeadingView(
            theme: theme,
            availableWidth: availableWidth,
            title: titlePrefix,
            tooltip: commitTooltip,
            iconName: iconName,
            changeCount: activeMarkdownPreviewPath == nil ? fileDiffs.count : nil,
            badges: AnyView(badges(availableWidth: availableWidth))
        )
    }

    @ViewBuilder
    private func badges(availableWidth: CGFloat) -> some View {
        if let mdPath = activeMarkdownPreviewPath {
            MarkdownPreviewBadge(path: mdPath, theme: theme) {
                withAnimation(.easeInOut(duration: 0.16)) { onCloseMarkdown() }
            }
        } else if availableWidth >= 460 || (!search.isActive && repo.comparisonTarget == .workingTree) {
            if search.isActive {
                GlobalSearchBadge(theme: theme) {
                    withAnimation(.easeInOut(duration: 0.16)) { search.close() }
                }
            } else if isReadOnlyActive {
                ReadOnlyDiffBadge(isCommit: repo.comparisonTarget.isCommit, theme: theme) {
                    onEndReadOnly()
                }
            } else if repo.comparisonTarget != .workingTree {
                ReadOnlyBadge()
            }
        }
    }

    @ViewBuilder
    private func headerActions(availableWidth: CGFloat) -> some View {
        let totalAdds = fileDiffs.reduce(0) { $0 + $1.additions }
        let totalDels = fileDiffs.reduce(0) { $0 + $1.deletions }

        EditorHeaderActionsView(
            theme: theme,
            availableWidth: availableWidth,
            hasCollapsedFiles: hasAnyCollapsedFiles,
            diffLayoutMode: diffLayoutMode,
            isSearchActive: search.isActive,
            totalAdds: totalAdds,
            totalDels: totalDels,
            disableHunkNavigation: fileDiffs.isEmpty,
            onPreviousHunk: { NotificationCenter.default.post(name: .goToPreviousHunk, object: nil) },
            onNextHunk: { NotificationCenter.default.post(name: .goToNextHunk, object: nil) },
            onToggleCollapse: toggleCollapseAll,
            onToggleLayout: onToggleLayout,
            onToggleSearch: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    search.toggle(in: repo.effectiveWorkingDirectory, selectedText: displayMap.getSelectionText())
                }
            }
        )
    }

    // MARK: - Editor Detail

    @ViewBuilder
    private var editorDetailView: some View {
        EditorHostView(
            displayMap: displayMap,
            theme: theme,
            fontSize: fontSize,
            isEditable: (!isReadOnlyActive && repo.comparisonTarget == .workingTree),
            selectedFilePath: repo.selectedFilePath,
            viewStateResetToken: viewStateResetToken,
            searchMatches: search.isActive ? search.matches : [],
            activeMatchIndex: search.isActive ? search.activeMatchIndex : nil,
            searchMatchScrollRequest: search.isActive ? search.scrollRequest : nil,
            onCursorChange: { location, _ in
                if let path = location?.filePath, repo.selectedFilePath != path {
                    repo.selectedFilePath = path
                }
            },
            onAddCommentRequest: { path, line in
                onAddComment(path, line)
            },
            onContentEdited: {
                if search.isActive {
                    search.handleContentEdited()
                }
            },
            onCloseFileRequest: { path in
                if isReadOnlyActive {
                    review.closeFile(filePath: path)
                    if repo.selectedFilePath == path {
                        repo.selectedFilePath = review.fileDiffs.first?.displayPath
                    }
                } else {
                    repo.closeFile(filePath: path)
                }
            },
            onOpenExternalIDERequest: { path, line in
                onOpenExternalIDE(path, line)
            },
            onPreviewMarkdownRequest: { path in
                onPreviewMarkdown(path)
            }
        )
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
