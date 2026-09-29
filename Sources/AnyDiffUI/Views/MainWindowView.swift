import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore


public struct MainWindowView: View {
    public var initialPath: String?

    @StateObject private var repo: RepoCoordinator
    @StateObject private var review: ReviewCoordinator
    @StateObject private var reviewManager: ReviewManager
    @StateObject private var search: SearchCoordinator
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @StateObject private var agentCoordinator = AgentSessionCoordinator(enablePeriodicAutoUpdate: true)
    @StateObject private var panelLayout = PanelLayoutManager()

    @State private var toolcallColorMode = AgentDisplayPreferences.toolcallColorMode
    @State private var activeMarkdownPreviewPath: String? = nil

    private var isReadOnlyActive: Bool {
        agentCoordinator.activeReviewSummary != nil || repo.comparisonTarget.isCommit || review.isActive
    }

    private var activeMultiBuffer: MultiBuffer {
        if search.isActive {
            return search.multiBuffer
        } else if isReadOnlyActive {
            return review.multiBuffer
        }
        return repo.multiBuffer
    }

    private var activeDisplayMap: DisplayMap {
        if search.isActive {
            return search.displayMap
        } else if isReadOnlyActive {
            return review.displayMap
        }
        return repo.displayMap
    }

    private var activeFileDiffs: [FileDiff] {
        isReadOnlyActive ? review.fileDiffs : repo.fileDiffs
    }

    public typealias RepoStatus = RepoCoordinator.RepoStatus

    @State private var selectedTheme: Theme = .vesper
    @State private var followsSystemAppearance: Bool = true
    @AppStorage("preferredDiffLayoutMode") private var preferredDiffLayoutMode: String = DiffLayoutMode.unified.rawValue
    @State private var fontSize: CGFloat = 13

    private static let isLeftPanelOpenKey = "anydiff_is_left_panel_open"
    @State private var columnVisibility: NavigationSplitViewVisibility = {
        let isOpen = UserDefaults.standard.object(forKey: isLeftPanelOpenKey) as? Bool ?? true
        return isOpen ? .all : .doubleColumn
    }()
    @State private var commentTarget: (filePath: String, lineNumber: Int)? = nil
    @State private var showOpenSourcePopover: Bool = false
    @State private var isWindowDropTargeted: Bool = false

    public var effectiveWorkingDirectory: String {
        repo.effectiveWorkingDirectory
    }
    public var effectiveBaseDirectory: String {
        repo.effectiveBaseDirectory
    }

    public init(initialPath: String? = nil) {
        self.initialPath = initialPath
        let rm = ReviewManager()
        let review = ReviewCoordinator(reviewManager: rm)
        let repo = RepoCoordinator(initialPath: initialPath, reviewManager: rm)
        let search = SearchCoordinator(reviewManager: rm)
        repo.search = search

        self._repo = StateObject(wrappedValue: repo)
        self._reviewManager = StateObject(wrappedValue: rm)
        self._review = StateObject(wrappedValue: review)
        self._search = StateObject(wrappedValue: search)
    }

    private var diffLayoutMode: DiffLayoutMode {
        if isReadOnlyActive {
            return review.displayMap.layoutMode
        }
        return DiffLayoutMode(rawValue: preferredDiffLayoutMode) ?? .unified
    }

    private func setDiffLayoutMode(_ mode: DiffLayoutMode) {
        if isReadOnlyActive {
            review.displayMap.layoutMode = mode
            return
        }
        preferredDiffLayoutMode = mode.rawValue
        repo.displayMap.layoutMode = mode
        search.displayMap.layoutMode = .unified
    }

    private func toggleDiffLayoutMode() {
        if isReadOnlyActive {
            let nextMode: DiffLayoutMode = (review.displayMap.layoutMode == .unified ? .sideBySide : .unified)
            review.displayMap.layoutMode = nextMode
        } else {
            setDiffLayoutMode(diffLayoutMode == .unified ? .sideBySide : .unified)
        }
    }

    private func toggleLeftPanel() {
        withAnimation(.easeInOut(duration: 0.12)) {
            if columnVisibility == .all {
                columnVisibility = .doubleColumn
            } else {
                columnVisibility = .all
            }
        }
    }

    private func toggleRightPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            panelLayout.toggleRightPanel()
            agentCoordinator.isPanelOpen = panelLayout.isRightPanelOpen
        }
    }

    private var activeTheme: Theme {
        if followsSystemAppearance {
            return systemAppearance.isDark ? .vesper : .macOSLight
        }
        return selectedTheme
    }

    private var commentModalBinding: Binding<IdentifiableCommentTarget?> {
        Binding(
            get: { commentTarget.map { IdentifiableCommentTarget(filePath: $0.filePath, lineNumber: $0.lineNumber) } },
            set: { _ in commentTarget = nil }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            panelView(for: .left)
                .navigationSplitViewColumnWidth(min: panelLayout.minWidth(for: .left), ideal: panelLayout.idealWidth(for: .left), max: panelLayout.maxWidth(for: .left))
        } content: {
            panelView(for: .center)
                .navigationSplitViewColumnWidth(min: panelLayout.minWidth(for: .center), ideal: panelLayout.idealWidth(for: .center), max: panelLayout.maxWidth(for: .center))
                .toolbar {
                    ToolbarItem(id: "mainWindowToolbarNav", placement: .navigation) {
                        toolbarNavigationItems
                    }
                    ToolbarItem(id: "mainWindowToolbarSpacer", placement: .automatic) {
                        Spacer()
                    }
                    ToolbarItem(id: "mainWindowToolbarTrailing", placement: .primaryAction) {
                        windowToolbarTrailingItems
                    }
                }
                .background(hiddenKeyboardShortcuts)
        } detail: {
            panelView(for: .right)
                .navigationSplitViewColumnWidth(min: panelLayout.minWidth(for: .right), ideal: panelLayout.idealWidth(for: .right), max: panelLayout.maxWidth(for: .right))
        }
        .onChange(of: columnVisibility) { newVisibility in
            let isOpen = (newVisibility == .all)
            UserDefaults.standard.set(isOpen, forKey: Self.isLeftPanelOpenKey)
            updateWindowAppearance()
        }
        .preferredColorScheme(activeTheme.isDark ? .dark : .light)
        .environment(\.colorScheme, activeTheme.isDark ? .dark : .light)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(activeTheme.isDark ? .dark : .light, for: .windowToolbar)
        .background(Color(activeTheme.background).ignoresSafeArea())
        .background(WindowAppearanceConfigurator(theme: activeTheme))
        .modifier(WindowDropModifier(
            isTargeted: $isWindowDropTargeted,
            theme: activeTheme,
            onOpenFolder: { path in
                showOpenSourcePopover = false
                repo.currentPath = path
                repo.loadCurrentDirectoryDiff()
            },
            onOpenRemote: { str in
                showOpenSourcePopover = false
                repo.loadRemoteDiff(from: str)
            }
        ))
        .overlay {
            AgentImagePreviewOverlay(coordinator: agentCoordinator, theme: activeTheme)
        }
        .sheet(item: commentModalBinding) { target in
            commentModalView(for: target)
        }
        .onAppear(perform: handleOnAppear)
        .onChange(of: agentCoordinator.activeReviewSummary) { newSummary in
            if let summary = newSummary {
                if activeMarkdownPreviewPath != nil {
                    closeMarkdownPreview()
                }
                if panelLayout.slot(for: .editor) == nil {
                    panelLayout.assign(.editor, to: .center)
                }
                // beginReview preloads the review before switching modes. The
                // fallback handles any coordinator-driven activation that did
                // not go through that path.
                if review.preparedReviewSummary == summary {
                    review.preparedReviewSummary = nil
                } else {
                    review.displayMap.layoutMode = .unified
                    review.loadReviewDiff(for: summary, workingDirectory: effectiveWorkingDirectory, baseDirectory: effectiveBaseDirectory)
                }
            } else {
                review.preparedReviewSummary = nil
                review.clear()
                if let savedPath = review.selectedFilePathBeforeReadOnly {
                    repo.selectedFilePath = savedPath
                    review.selectedFilePathBeforeReadOnly = nil
                }
                if repo.multiBuffer.excerpts.isEmpty && repo.fileDiffs.isEmpty {
                    repo.loadCurrentDirectoryDiff()
                }
            }
        }
        .onChange(of: selectedTheme.id) { _ in updateWindowAppearance() }
        .onChange(of: followsSystemAppearance) { _ in updateWindowAppearance() }
        .onChange(of: repo.isWatchModeEnabled) { enabled in
            repo.setWatchModeEnabled(enabled)
        }
        .onDisappear {
            repo.stopWatcher()
        }
        .modifier(MainWindowEventsModifier(
            onUpdateAppearance: { updateWindowAppearance() },
            onFocusEditor: {
                if activeMarkdownPreviewPath != nil {
                    closeMarkdownPreview()
                }
                if panelLayout.slot(for: .editor) == nil {
                    panelLayout.assign(.editor, to: .center)
                }
            },
            onOpenProject: { showOpenSourcePopover = true },
            onOpenInBrowser: { openInBrowser() },
            onReloadDiff: { reloadCurrentDiff() },
            onToggleWatchMode: { repo.isWatchModeEnabled.toggle() },
            onToggleLeftPanel: {
                withAnimation(.easeInOut(duration: 0.12)) {
                    toggleLeftPanel()
                }
            },
            onToggleRightPanel: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toggleRightPanel()
                }
            },
            onSelectTheme: { themeId in
                if themeId == "system" {
                    followsSystemAppearance = true
                } else if let t = Theme.allThemes.first(where: { $0.id == themeId }) {
                    followsSystemAppearance = false
                    selectedTheme = t
                }
            },
            onSetDiffLayout: { m in
                withAnimation(.easeInOut(duration: 0.15)) {
                    setDiffLayoutMode(m)
                }
            },
            onFindInProject: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    search.open(in: effectiveWorkingDirectory, selectedText: activeDisplayMap.getSelectionText())
                }
            },
            onFindNext: { search.selectNextMatch() },
            onFindPrevious: { search.selectPreviousMatch() },
            onZoomIn: { fontSize = min(28, fontSize + 1) },
            onZoomOut: { fontSize = max(9, fontSize - 1) },
            onResetZoom: { fontSize = 13 },
            onResetPanelsLayout: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelLayout.resetToDefaults()
                }
            },
            onToolcallColorModeChanged: { mode in
                toolcallColorMode = mode
            }
        ))
    }


    @ViewBuilder
    private func panelView(for slot: PanelSlot) -> some View {
        if slot == .right && !panelLayout.isRightPanelOpen {
            Color.clear
        } else {
            switch panelLayout.content(for: slot) {
            case .changes:
                changesPanelView(for: slot)
            case .files:
                filesPanelView(for: slot)
            case .history:
                historyPanelView(for: slot)
            case .editor:
                editorPanelView(for: slot)
            case .agent:
                agentPanelView(for: slot)
            case nil:
                EmptyPanelView(
                    slot: slot,
                    theme: activeTheme,
                    currentOccupant: { panelLayout.slot(for: $0) },
                    onSelect: { content in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            panelLayout.assign(content, to: slot)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func changesPanelView(for slot: PanelSlot) -> some View {
        SidebarFileListView(
            repo: repo,
            fileDiffs: activeFileDiffs,
            theme: activeTheme,
            emptyMessage: isReadOnlyActive ? (repo.comparisonTarget.isCommit ? "No changed files in commit" : "No files in review") : (repo.repoStatus == .notGitRepository ? "Not a Git repository" : "No changed files"),
            reviewManager: reviewManager,
            onReload: { reloadCurrentDiff() },
            onBack: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.clear(slot)
                }
            },
            onSwitchToFiles: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.files, to: .left)
                }
            } : nil,
            onSwitchToHistory: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.history, to: .left)
                }
            } : nil
        )
    }

    @ViewBuilder
    private func filesPanelView(for slot: PanelSlot) -> some View {
        FilesPanelView(
            rootDirectory: effectiveWorkingDirectory,
            fileDiffs: activeFileDiffs,
            openFilePaths: Set(activeDisplayMap.multiBuffer.excerpts.map(\.filePath)),
            theme: activeTheme,
            selectedFilePath: $repo.selectedFilePath,
            onOpenFile: { path in
                if activeMarkdownPreviewPath != nil {
                    let isMd = path.hasSuffix(".md") || path.hasSuffix(".markdown") || path.hasSuffix(".mdx")
                    if isMd {
                        openMarkdownPreview(path: path)
                        return
                    } else {
                        closeMarkdownPreview()
                    }
                }
                openFileInEditor(path: path)
            },
            onOpenExternalIDE: { path in
                openInExternalIDE(filePath: path)
            },
            onPreviewMarkdown: { path in
                openMarkdownPreview(path: path)
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.clear(slot)
                }
            },
            onSwitchToChanges: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.changes, to: .left)
                }
            } : nil,
            onSwitchToHistory: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.history, to: .left)
                }
            } : nil
        )
        .id(effectiveWorkingDirectory)
    }

    @ViewBuilder
    private func historyPanelView(for slot: PanelSlot) -> some View {
        HistoryPanelView(
            directory: effectiveWorkingDirectory,
            theme: activeTheme,
            comparisonTarget: repo.comparisonTarget,
            workingChangesCount: repo.fileDiffs.count,
            reloadToken: repo.reloadToken,
            onSelectCommit: { commit in
                selectCommit(commit)
            },
            onSelectCommitFile: { commit, filePath in
                selectCommit(commit, targetFilePath: filePath)
            },
            onSelectWorkingChanges: {
                selectWorkingChanges()
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.clear(slot)
                }
            },
            onSwitchToChanges: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.changes, to: .left)
                }
            } : nil,
            onSwitchToFiles: slot == .left ? {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(.files, to: .left)
                }
            } : nil
        )
        .id(effectiveWorkingDirectory)
    }

    private func selectCommit(_ commit: GitCommit, targetFilePath: String? = nil) {
        if activeMarkdownPreviewPath != nil {
            closeMarkdownPreview()
        }
        if panelLayout.slot(for: .editor) == nil {
            panelLayout.assign(.editor, to: .center)
        }
        if let target = targetFilePath {
            repo.selectedFilePath = target
        }
        if case .commit(let currentHash, _) = repo.comparisonTarget, currentHash == commit.hash {
            if let target = targetFilePath {
                focusFileInMultiBuffer(target)
            }
            return
        }
        if review.selectedFilePathBeforeReadOnly == nil {
            review.selectedFilePathBeforeReadOnly = repo.selectedFilePath
        }
        repo.selectedCommit = commit
        repo.comparisonTarget = .commit(hash: commit.hash, summary: commit.summary)
        loadCommitDiff(hash: commit.hash, targetFilePath: targetFilePath)
    }

    private func focusFileInMultiBuffer(_ filePath: String) {
        if activeMarkdownPreviewPath != nil {
            closeMarkdownPreview()
        }
        if panelLayout.slot(for: .editor) == nil {
            panelLayout.assign(.editor, to: .center)
        }
        repo.selectedFilePath = filePath
        let post = {
            NotificationCenter.default.post(
                name: .focusFileInEditor,
                object: FileNavigationRequest(filePath: filePath, lineNumber: nil, endLineNumber: nil)
            )
        }
        post()
        DispatchQueue.main.async {
            post()
        }
    }

    private func selectWorkingChanges() {
        guard repo.comparisonTarget != .workingTree else { return }
        endReadOnlyDiff()
    }

    private func loadCommitDiff(hash: String, targetFilePath: String? = nil) {
        let dir = effectiveWorkingDirectory
        guard !dir.isEmpty else { return }
        review.multiBuffer.baseDirectory = dir
        review.displayMap.layoutMode = diffLayoutMode

        DispatchQueue.global(qos: .userInitiated).async {
            let (files, rawData) = GitService.shared.diffFiles(at: dir, target: .commit(hash: hash, summary: ""))
            DispatchQueue.main.async {
                guard case .commit(let currentHash, _) = self.repo.comparisonTarget, currentHash == hash else { return }
                self.review.viewStateResetToken &+= 1
                self.review.loadDiff(files: files, rawData: rawData, baseDirectory: self.effectiveBaseDirectory)
                if let sel = self.repo.selectedFilePath, files.contains(where: { $0.displayPath == sel }) {
                    self.repo.selectedFilePath = sel
                } else {
                    self.repo.selectedFilePath = files.first?.displayPath
                }
                if let target = targetFilePath {
                    self.focusFileInMultiBuffer(target)
                }
            }
        }
    }

    @ViewBuilder
    private func editorPanelView(for slot: PanelSlot) -> some View {
        EditorContainerView(
            repo: repo,
            review: review,
            search: search,
            theme: activeTheme,
            fontSize: fontSize,
            activeMarkdownPreviewPath: activeMarkdownPreviewPath,
            isReviewActive: agentCoordinator.activeReviewSummary != nil || review.isActive,
            onClosePanel: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.clear(slot)
                }
            },
            onToggleLayout: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    toggleDiffLayoutMode()
                }
            },
            onCloseMarkdown: {
                closeMarkdownPreview()
            },
            onOpenFileInEditor: { path in
                openFileInEditor(path: path)
            },
            onEndReadOnly: {
                endReadOnlyDiff()
            },
            onAddComment: { path, line in
                commentTarget = (filePath: path, lineNumber: line)
            },
            onOpenExternalIDE: { path, line in
                openInExternalIDE(filePath: path, line: line)
            },
            onPreviewMarkdown: { path in
                openMarkdownPreview(path: path)
            },
            onOpenInBrowser: {
                openInBrowser()
            }
        )
    }

    @ViewBuilder
    private func agentPanelView(for slot: PanelSlot) -> some View {
        AgentContainerView(
            coordinator: agentCoordinator,
            theme: activeTheme,
            workingDirectory: effectiveWorkingDirectory,
            selectedFilePath: repo.selectedFilePath,
            fileDiffsSummary: currentDiffSummary,
            toolcallColorMode: toolcallColorMode,
            onClose: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.clear(slot)
                }
            },
            onReview: { summary in beginReview(summary: summary) },
            onOpenURL: { url in handleOpenURL(url) }
        )
    }

    @ViewBuilder
    private var windowToolbarTrailingItems: some View {
        RightPanelToggleButton(
            isOpen: panelLayout.isRightPanelOpen,
            title: panelLayout.rightContent?.title ?? "Right Panel",
            onToggle: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelLayout.toggleRightPanel()
                    agentCoordinator.isPanelOpen = panelLayout.isRightPanelOpen
                }
            }
        )
    }

    private var currentDiffSummary: String {
        guard !repo.fileDiffs.isEmpty else { return "No uncommitted changes." }
        var summary = "Repository: \(repo.currentFolderName)\n"
        summary += "Changed Files (\(repo.fileDiffs.count)):\n"
        for file in repo.fileDiffs.prefix(25) {
            summary += "- \(file.displayPath) (+\(file.additions), -\(file.deletions))\n"
        }
        if repo.fileDiffs.count > 25 {
            summary += "...and \(repo.fileDiffs.count - 25) more files\n"
        }
        return summary
    }



    @ViewBuilder
    private var toolbarNavigationItems: some View {
        MainWindowToolbarLeadingView(
            repo: repo,
            theme: activeTheme,
            showOpenSourcePopover: $showOpenSourcePopover,
            onOpenInBrowser: {
                openInBrowser()
            }
        )
    }

    @ViewBuilder
    private var hiddenKeyboardShortcuts: some View {
        MainWindowShortcuts(
            onSelectPanel: { panel in
                withAnimation(.easeInOut(duration: 0.18)) {
                    panelLayout.assign(panel, to: .left)
                }
            },
            onToggleDiffLayout: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    toggleDiffLayoutMode()
                }
            },
            onReload: { reloadCurrentDiff() },
            onOpenShortcut: { handleOpenShortcut() },
            onOpenFolder: { repo.openGitRepositoryFolder() },
            onOpenSourcePopover: { showOpenSourcePopover = true },
            onOpenBrowser: { openInBrowser() },
            onToggleSearch: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    search.toggle(in: effectiveWorkingDirectory, selectedText: activeDisplayMap.getSelectionText())
                }
            },
            onOpenSearch: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    search.open(in: effectiveWorkingDirectory, selectedText: activeDisplayMap.getSelectionText())
                }
            },
            onNextSearchMatch: { search.selectNextMatch() },
            onPreviousSearchMatch: { search.selectPreviousMatch() },
            onZoomIn: { fontSize = min(28, fontSize + 1) },
            onZoomOut: { fontSize = max(9, fontSize - 1) },
            onZoomReset: { fontSize = 13 },
            onToggleAgent: {
                toggleRightPanel()
            },
            onToggleMarkdown: {
                if let mdPath = activeMarkdownPreviewPath {
                    closeMarkdownPreview()
                    openFileInEditor(path: mdPath)
                } else if let selectedPath = repo.selectedFilePath,
                          (selectedPath.hasSuffix(".md") || selectedPath.hasSuffix(".markdown") || selectedPath.hasSuffix(".mdx")) {
                    openMarkdownPreview(path: selectedPath)
                }
            },
            onCancel: {
                if search.isActive {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        search.close()
                    }
                } else if activeMarkdownPreviewPath != nil {
                    closeMarkdownPreview()
                } else if isReadOnlyActive {
                    endReadOnlyDiff()
                }
            }
        )
    }


    private func beginReview(summary: AgentEditedFilesSummary) {
        if activeMarkdownPreviewPath != nil {
            closeMarkdownPreview()
        }
        if panelLayout.slot(for: .editor) == nil {
            panelLayout.assign(.editor, to: .center)
        }
        search.close()
        review.selectedFilePathBeforeReadOnly = repo.selectedFilePath
        review.viewStateResetToken &+= 1
        review.clear()
        review.displayMap.layoutMode = .unified
        review.loadReviewDiff(for: summary, workingDirectory: effectiveWorkingDirectory, baseDirectory: effectiveBaseDirectory)
        if let firstFile = summary.files.first?.path {
            let matched = review.displayMap.matchFilePath(firstFile) ?? firstFile
            focusFileInMultiBuffer(matched)
        }
        review.preparedReviewSummary = summary
        agentCoordinator.startReview(summary: summary)
    }

    private func endReadOnlyDiff() {
        if agentCoordinator.activeReviewSummary != nil {
            agentCoordinator.exitReview()
            review.preparedReviewSummary = nil
        }
        if case .commit = repo.comparisonTarget {
            repo.selectedCommit = nil
            repo.showCommitDetailPopover = false
            repo.comparisonTarget = .workingTree
        }
        review.clear()
        if let savedPath = review.selectedFilePathBeforeReadOnly {
            repo.selectedFilePath = savedPath
            review.selectedFilePathBeforeReadOnly = nil
        }
    }

    public func openMarkdownPreview(path: String) {
        if panelLayout.slot(for: .editor) == nil {
            panelLayout.assign(.editor, to: .center)
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            activeMarkdownPreviewPath = path
        }
    }

    public func closeMarkdownPreview() {
        if let current = SelectionQuoteStore.shared.currentQuote,
           current.source == .markdown || current.id.hasPrefix("markdown:") {
            SelectionQuoteStore.shared.clearQuote(scopedToId: current.id)
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            activeMarkdownPreviewPath = nil
        }
    }

    private func handleOpenURL(_ url: URL) {
        let target = FileLinkParser.parse(url: url, workingDirectory: effectiveWorkingDirectory)
        switch target.targetType {
        case .web(let webURL):
            NSWorkspace.shared.open(webURL)

        case .directory(let dirPath):
            let dirURL = URL(fileURLWithPath: dirPath)
            NSWorkspace.shared.open(dirURL)

        case .file(let filePath, let line, let endLine):
            openFileInEditor(path: filePath, line: line, endLine: endLine)

        case .custom(let customURL):
            NSWorkspace.shared.open(customURL)
        }
    }

    public func openFileInEditor(path: String, line: Int? = nil, endLine: Int? = nil) {
        if activeMarkdownPreviewPath != nil {
            closeMarkdownPreview()
        }
        if panelLayout.slot(for: .editor) == nil {
            panelLayout.assign(.editor, to: .center)
        }
        let baseDir = effectiveWorkingDirectory
        let resolvedRelativePath: String
        if (path as NSString).isAbsolutePath {
            if path.hasPrefix(baseDir) {
                let suffix = String(path.dropFirst(baseDir.count))
                resolvedRelativePath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                resolvedRelativePath = (path as NSString).lastPathComponent
            }
        } else {
            resolvedRelativePath = path
        }
        if let targetFile = activeDisplayMap.matchFilePath(resolvedRelativePath) ?? activeDisplayMap.matchFilePath(path) {
            repo.selectedFilePath = targetFile
            NotificationCenter.default.post(
                name: .focusFileInEditor,
                object: FileNavigationRequest(filePath: targetFile, lineNumber: line, endLineNumber: endLine)
            )
            return
        }
        repo.openFile(path: path, line: line, endLine: endLine)
    }

    public func closeFileFromEditor(filePath: String) {
        if isReadOnlyActive {
            review.closeFile(filePath: filePath)
            if repo.selectedFilePath == filePath {
                repo.selectedFilePath = review.fileDiffs.first?.displayPath
            }
            return
        }
        repo.closeFile(filePath: filePath)
    }

    public func openInExternalIDE(filePath: String, line: Int? = nil) {
        let baseDir = effectiveWorkingDirectory
        let fullPath = (filePath as NSString).isAbsolutePath ? filePath : (baseDir as NSString).appendingPathComponent(filePath)
        let lineArg = line != nil ? "-g '\(fullPath):\(line!)'" : "'\(fullPath)'"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "cursor \(lineArg) 2>/dev/null || code \(lineArg) 2>/dev/null || open '\(fullPath)'"]
            try? process.run()
        }
    }

    private func handleOpenShortcut() {
        if showOpenSourcePopover {
            showOpenSourcePopover = false
            repo.openGitRepositoryFolder()
        } else if repo.fileDiffs.isEmpty {
            repo.openGitRepositoryFolder()
        } else {
            showOpenSourcePopover = true
        }
    }


    @ViewBuilder
    private func commentModalView(for target: IdentifiableCommentTarget) -> some View {
        AddCommentModal(
            filePath: target.filePath,
            lineNumber: target.lineNumber,
            onAdd: { author, content in
                _ = reviewManager.addComment(filePath: target.filePath, lineNumber: target.lineNumber, author: author, content: content)
                activeDisplayMap.rebuild()
                commentTarget = nil
            },
            onCancel: {
                commentTarget = nil
            }
        )
    }

    private func handleOnAppear() {
        agentCoordinator.isPanelOpen = panelLayout.isRightPanelOpen
        if let storedThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") {
            if storedThemeId == "system" {
                followsSystemAppearance = true
            } else if let t = Theme.allThemes.first(where: { $0.id == storedThemeId }) {
                selectedTheme = t
                followsSystemAppearance = false
            }
        }
        if let initial = initialPath, (initial.hasPrefix("http://") || initial.hasPrefix("https://") || initial.contains("github.com") || initial.contains("diffshub.com") || initial.contains("#")) {
            repo.loadRemoteDiff(from: initial)
        } else {
            repo.loadCurrentDirectoryDiff()
        }
        updateWindowAppearance()
    }


    private func openInBrowser() {
        if case .remote(let ref) = repo.comparisonTarget {
            if let url = ref.webURL ?? Optional(ref.diffURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func reloadCurrentDiff() {
        if let reviewSummary = agentCoordinator.activeReviewSummary {
            review.loadReviewDiff(for: reviewSummary, workingDirectory: effectiveWorkingDirectory, baseDirectory: effectiveBaseDirectory)
            return
        }
        if case .commit(let hash, _) = repo.comparisonTarget {
            loadCommitDiff(hash: hash)
            return
        }
        if case .remote(let ref) = repo.comparisonTarget {
            repo.loadRemoteDiff(reference: ref)
        } else {
            repo.loadCurrentDirectoryDiff()
        }
    }

    private func updateWindowAppearance() {
        for window in NSApp.windows {
            window.backgroundColor = activeTheme.background
            window.appearance = NSAppearance(named: activeTheme.isDark ? .darkAqua : .aqua)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            updateSplitViewDividers(in: window, color: activeTheme.panelDivider)
        }
    }
}

