import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore

private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var isDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        self.isDark = Self.readIsDark()
        self.appearanceObservation = NSApp.observe(\NSApplication.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isDark = Self.readIsDark()
            }
        }
    }

    private static func readIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

public struct MainWindowView: View {
    public var initialPath: String?

    @StateObject private var multiBuffer = MultiBuffer()
    @StateObject private var reviewManager = ReviewManager()
    @StateObject private var displayMap: DisplayMap
    @StateObject private var systemAppearance = SystemAppearanceObserver()

    public enum RepoStatus {
        case notGitRepository
        case clean
        case hasChanges
    }

    @State private var currentPath: String? = nil
    @State private var isReloading: Bool = false
    @State private var isStreaming: Bool = false
    @State private var streamingCount: Int = 0
    @State private var currentBranch: String = ""
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var comparisonTarget: ComparisonTarget = .workingTree
    @State private var repoStatus: RepoStatus = .clean
    @State private var fileDiffs: [FileDiff] = []
    @State private var selectedFilePath: String? = nil
    @State private var selectedTheme: Theme = .unifiedDark
    @State private var followsSystemAppearance: Bool = true
    @State private var viewMode: DiffViewMode = .unified
    @State private var contextLines: Int = 3
    @State private var fontSize: CGFloat = 13

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var commentTarget: (filePath: String, lineNumber: Int)? = nil
    @State private var currentFolderName: String = ""
    @State private var showThemePicker: Bool = false
    @State private var showOpenSourcePopover: Bool = false
    @State private var isWindowDropTargeted: Bool = false
    @State private var remoteTarget: GitHubDiffReference? = nil
    @State private var remoteErrorMessage: String? = nil
    @State private var remoteLoadTask: Task<Void, Never>? = nil
    @State private var loadGeneration: UInt64 = 0

    public init(initialPath: String? = nil) {
        self.initialPath = initialPath
        let mb = MultiBuffer()
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        self._multiBuffer = StateObject(wrappedValue: mb)
        self._reviewManager = StateObject(wrappedValue: rm)
        self._displayMap = StateObject(wrappedValue: dm)
    }

    private var activeTheme: Theme {
        if followsSystemAppearance {
            return systemAppearance.isDark ? .unifiedDark : .macOSLight
        }
        return selectedTheme
    }

    private var activeThemeName: String {
        followsSystemAppearance ? "System (\(systemAppearance.isDark ? "Dark" : "Light"))" : selectedTheme.name
    }

    private var commentModalBinding: Binding<IdentifiableCommentTarget?> {
        Binding(
            get: { commentTarget.map { IdentifiableCommentTarget(filePath: $0.filePath, lineNumber: $0.lineNumber) } },
            set: { _ in commentTarget = nil }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            detailView
        }
        .toolbarBackground(Color(activeTheme.background), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(activeTheme.isDark ? .dark : .light, for: .windowToolbar)
        .background(Color(activeTheme.background).ignoresSafeArea())
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.text], isTargeted: $isWindowDropTargeted) { providers in
            handleWindowDrop(providers: providers)
        }
        .overlay(windowDropOverlayView)
        .sheet(item: commentModalBinding) { target in
            commentModalView(for: target)
        }
        .onAppear(perform: handleOnAppear)
        .onChange(of: selectedTheme.id) { _ in updateWindowAppearance() }
        .onChange(of: followsSystemAppearance) { _ in updateWindowAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenProject"))) { _ in
            showOpenSourcePopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenURL"))) { _ in
            showOpenSourcePopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenInBrowser"))) { _ in
            openInBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffReloadDiff"))) { _ in
            reloadCurrentDiff()
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        SidebarFileListView(
            fileDiffs: fileDiffs,
            theme: activeTheme,
            emptyMessage: repoStatus == .notGitRepository ? "Not a Git repository" : "No changed files",
            isReloading: isReloading,
            isStreaming: isStreaming,
            streamingCount: streamingCount,
            comparisonTarget: comparisonTarget,
            currentBranch: currentBranch,
            reviewManager: reviewManager,
            selectedFilePath: $selectedFilePath,
            onReload: { reloadCurrentDiff() }
        )
        .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 800)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if columnVisibility != .detailOnly {
                    themePickerButton
                }
            }
        }
    }

    @ViewBuilder
    private var themePickerButton: some View {
        Button(action: { showThemePicker.toggle() }) {
            Image(systemName: "paintpalette")
                .font(.system(size: 13.0, weight: .regular))
                .foregroundColor(Color(NSColor.secondaryLabelColor))
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Select Color Theme (\(activeThemeName))")
        .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
            ThemePickerPopoverView(
                selectedTheme: $selectedTheme,
                followsSystemAppearance: $followsSystemAppearance,
                isPresented: $showThemePicker
            )
        }
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            if fileDiffs.isEmpty {
                emptyStateDetailView
            } else {
                editorDetailView
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toolbarNavigationItems
            }
        }
        .background(hiddenKeyboardShortcuts)
    }

    @ViewBuilder
    private var emptyStateDetailView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                emptyStatusHeaderView

                OpenSourceContentView(
                    theme: activeTheme,
                    currentLocalPath: currentPath,
                    currentComparisonTarget: comparisonTarget,
                    isInline: true,
                    onOpenLocalFolder: { openGitRepositoryFolder() },
                    onSelectLocalPath: { path in
                        self.currentPath = path
                        loadCurrentDirectoryDiff()
                    },
                    onOpenRemoteURL: { url in
                        loadRemoteDiff(from: url)
                    },
                    onOpenInBrowser: { openInBrowser() }
                )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(activeTheme.background))
    }

    @ViewBuilder
    private var emptyStatusHeaderView: some View {
        VStack(spacing: 6) {
            if repoStatus == .notGitRepository {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                Text("Not a Git Repository")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(activeTheme.foreground))

                Text(currentFolderName.isEmpty ? "Current folder is not a Git repository." : "\"\(currentFolderName)\" is not a Git repository.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(activeTheme.gutterForeground))
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                Text("No Uncommitted Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(activeTheme.foreground))

                Text("Working tree in \(currentFolderName.isEmpty ? "project" : "\"\(currentFolderName)\"") is clean.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(activeTheme.gutterForeground))
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var editorDetailView: some View {
        EditorHostView(
            displayMap: displayMap,
            theme: activeTheme,
            fontSize: fontSize,
            isEditable: (comparisonTarget == .workingTree),
            selectedFilePath: selectedFilePath,
            onCursorChange: { _, _ in },
            onAddCommentRequest: { path, line in
                commentTarget = (filePath: path, lineNumber: line)
            }
        )
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toolbarNavigationItems: some View {
        HStack(spacing: 6) {
            if case .remote(let ref) = comparisonTarget {
                remoteHeaderButton(for: ref)

                Button(action: openInBrowser) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help("Open Pull Request in Browser (Cmd+Shift+B)")

                readOnlyBadge
            } else {
                localHeaderButton

                if repoStatus != .notGitRepository && !currentBranch.isEmpty {
                    BranchPickerView(
                        currentBranch: currentBranch,
                        localBranches: localBranches,
                        remoteBranches: remoteBranches,
                        comparisonTarget: $comparisonTarget,
                        onSelectTarget: { target in
                            self.comparisonTarget = target
                            loadCurrentDirectoryDiff()
                        }
                    )
                }

                if comparisonTarget != .workingTree {
                    readOnlyBadge
                }
            }
        }
    }

    @ViewBuilder
    private func remoteHeaderButton(for ref: GitHubDiffReference) -> some View {
        Button(action: { showOpenSourcePopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text(ref.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Switch Project or Remote Diff (Cmd+O)")
        .popover(isPresented: $showOpenSourcePopover, arrowEdge: .bottom) {
            openSourcePopoverContentView
        }
    }

    @ViewBuilder
    private var localHeaderButton: some View {
        Button(action: { showOpenSourcePopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(currentFolderName.isEmpty ? "AnyDiff" : currentFolderName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Open Git Repository or Diff (Cmd+O)")
        .popover(isPresented: $showOpenSourcePopover, arrowEdge: .bottom) {
            openSourcePopoverContentView
        }
    }

    @ViewBuilder
    private var readOnlyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5))
            Text("Read-Only")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(5)
        .help("Read-only mode.")
    }

    @ViewBuilder
    private var openSourcePopoverContentView: some View {
        OpenSourceContentView(
            theme: activeTheme,
            currentLocalPath: currentPath,
            currentComparisonTarget: comparisonTarget,
            isInline: false,
            onOpenLocalFolder: {
                showOpenSourcePopover = false
                openGitRepositoryFolder()
            },
            onSelectLocalPath: { path in
                showOpenSourcePopover = false
                self.currentPath = path
                loadCurrentDirectoryDiff()
            },
            onOpenRemoteURL: { url in
                showOpenSourcePopover = false
                loadRemoteDiff(from: url)
            },
            onOpenInBrowser: {
                openInBrowser()
            },
            onClose: {
                showOpenSourcePopover = false
            }
        )
    }

    @ViewBuilder
    private var hiddenKeyboardShortcuts: some View {
        Group {
            Button(action: { reloadCurrentDiff() }) {}
                .keyboardShortcut("r", modifiers: .command)
            Button(action: { handleOpenShortcut() }) {}
                .keyboardShortcut("o", modifiers: .command)
            Button(action: { openGitRepositoryFolder() }) {}
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(action: { showOpenSourcePopover = true }) {}
                .keyboardShortcut("u", modifiers: .command)
            Button(action: { openInBrowser() }) {}
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(action: { fontSize = max(9, fontSize - 1) }) {}
                .keyboardShortcut("-", modifiers: .command)
            Button(action: { fontSize = min(28, fontSize + 1) }) {}
                .keyboardShortcut("+", modifiers: .command)
            Button(action: { fontSize = min(28, fontSize + 1) }) {}
                .keyboardShortcut("=", modifiers: .command)
        }
        .opacity(0)
    }

    private func handleOpenShortcut() {
        if showOpenSourcePopover {
            showOpenSourcePopover = false
            openGitRepositoryFolder()
        } else if fileDiffs.isEmpty {
            openGitRepositoryFolder()
        } else {
            showOpenSourcePopover = true
        }
    }

    @ViewBuilder
    private var windowDropOverlayView: some View {
        if isWindowDropTargeted {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(.accentColor)
                    Text("Drop folder or URL to open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(activeTheme.background).opacity(0.95))
                        .shadow(color: .black.opacity(0.35), radius: 24)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.accentColor, lineWidth: 2)
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func commentModalView(for target: IdentifiableCommentTarget) -> some View {
        AddCommentModal(
            filePath: target.filePath,
            lineNumber: target.lineNumber,
            onAdd: { author, content in
                _ = reviewManager.addComment(filePath: target.filePath, lineNumber: target.lineNumber, author: author, content: content)
                displayMap.rebuild()
                commentTarget = nil
            },
            onCancel: {
                commentTarget = nil
            }
        )
    }

    private func handleOnAppear() {
        if let initial = initialPath, (initial.hasPrefix("http://") || initial.hasPrefix("https://") || initial.contains("github.com") || initial.contains("diffshub.com") || initial.contains("#")) {
            loadRemoteDiff(from: initial)
        } else {
            loadCurrentDirectoryDiff()
        }
        updateWindowAppearance()
    }

    private func handleWindowDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                } else if let string = item as? String, let url = URL(string: string) {
                    targetURL = url
                }
                if let url = targetURL {
                    DispatchQueue.main.async {
                        let path = url.path
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                            self.showOpenSourcePopover = false
                            if isDir.boolValue {
                                self.currentPath = path
                            } else {
                                self.currentPath = (path as NSString).deletingLastPathComponent
                            }
                            self.loadCurrentDirectoryDiff()
                        }
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                var stringVal: String?
                if let url = item as? URL {
                    stringVal = url.absoluteString
                } else if let str = item as? String {
                    stringVal = str
                }
                if let str = stringVal {
                    DispatchQueue.main.async {
                        self.showOpenSourcePopover = false
                        self.loadRemoteDiff(from: str)
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        self.showOpenSourcePopover = false
                        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                            let expanded = (trimmed as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: expanded) {
                                self.currentPath = expanded
                                self.loadCurrentDirectoryDiff()
                                return
                            }
                        }
                        self.loadRemoteDiff(from: trimmed)
                    }
                }
            }
            return true
        }
        return false
    }

    private func openInBrowser() {
        if case .remote(let ref) = comparisonTarget {
            if let url = ref.webURL ?? Optional(ref.diffURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func reloadCurrentDiff() {
        if case .remote(let ref) = comparisonTarget {
            loadRemoteDiff(reference: ref)
        } else {
            loadCurrentDirectoryDiff()
        }
    }

    private func updateWindowAppearance() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.backgroundColor = activeTheme.background
                window.titlebarSeparatorStyle = .none
            }
        }
    }

    // MARK: - Remote GitHub Diff Loading

    public func loadRemoteDiff(from urlString: String) {
        guard !isReloading else { return }
        switch GitHubDiffService.shared.parseReference(from: urlString) {
        case .success(let ref):
            RecentSourcesManager.shared.addRemoteURL(urlString)
            loadRemoteDiff(reference: ref)
        case .failure(let err):
            self.remoteErrorMessage = err.localizedDescription
        }
    }

    public func loadRemoteDiff(reference: GitHubDiffReference) {
        guard !isReloading else { return }
        if let webURL = reference.webURL?.absoluteString {
            RecentSourcesManager.shared.addRemoteURL(webURL)
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReloading = true
        isStreaming = true
        remoteErrorMessage = nil

        // Clear existing buffers and caches
        multiBuffer.clear()
        displayMap.clear()
        fileDiffs = []
        selectedFilePath = nil

        self.remoteTarget = reference
        self.comparisonTarget = .remote(reference)
        self.currentFolderName = reference.displayTitle
        self.currentBranch = ""
        self.localBranches = []
        self.remoteBranches = []
        self.multiBuffer.baseDirectory = nil
        NSApp.windows.first?.title = reference.displayTitle
        self.repoStatus = .hasChanges

        let task = Task {
            do {
                var allFiles: [FileDiff] = []
                var initialRenderDone = false
                var lastProgressUpdateTime = Date()

                for try await fileDiff in GitHubDiffService.shared.streamDiff(for: reference) {
                    if Task.isCancelled { break }
                    allFiles.append(fileDiff)

                    // 1. Initial Instant Paint (<50ms): show the first file right away
                    if !initialRenderDone && allFiles.count >= 1 {
                        initialRenderDone = true
                        let firstBatch = allFiles
                        await MainActor.run {
                            guard self.loadGeneration == generation else { return }
                            self.fileDiffs = firstBatch
                            self.appendFileDiffsToMultiBuffer(firstBatch)
                            self.displayMap.rebuild()
                            if let first = firstBatch.first {
                                self.selectedFilePath = first.displayPath
                            }
                        }
                    }

                    // 2. Throttle sidebar progress indicator (every 200ms) with ZERO DisplayMap rebuild
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdateTime) >= 0.2 {
                        lastProgressUpdateTime = now
                        let count = allFiles.count
                        await MainActor.run {
                            guard self.loadGeneration == generation else { return }
                            self.streamingCount = count
                        }
                    }
                }

                // 3. Final single atomic commit: append remaining files and rebuild DisplayMap ONCE
                let finalFiles = allFiles
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.multiBuffer.clear()
                    self.displayMap.clear()
                    self.fileDiffs = finalFiles
                    self.appendFileDiffsToMultiBuffer(finalFiles)
                    self.displayMap.rebuild()

                    self.isStreaming = false
                    self.isReloading = false
                    self.remoteLoadTask = nil
                    self.streamingCount = finalFiles.count
                    if self.selectedFilePath == nil, let first = finalFiles.first {
                        self.selectedFilePath = first.displayPath
                    }
                    if finalFiles.isEmpty {
                        self.repoStatus = .clean
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isStreaming = false
                    self.isReloading = false
                    self.remoteLoadTask = nil
                    self.remoteErrorMessage = error.localizedDescription
                }
            }
        }
        remoteLoadTask = task
    }

    private func appendFileDiffsToMultiBuffer(_ files: [FileDiff]) {
        for file in files {
            let fileAdds = file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
            let fileDels = file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deleted }.count }

            if file.status == .deleted {
                let oldLines = file.hunks.flatMap { $0.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text) }
                let buffer = Buffer(
                    filePath: file.displayPath,
                    lines: [],
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: oldLines,
                    totalAdditions: 0,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: nil,
                    diskFileLineCount: 0
                )
                buffer.isFullFile = true
                multiBuffer.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: .deleted,
                    bufferRange: 0..<0,
                    hunk: file.hunks.first,
                    isCollapsed: false,
                    isFileStart: true
                )
                multiBuffer.addExcerpt(excerpt)
            } else if file.hunks.isEmpty {
                let buffer = Buffer(
                    filePath: file.displayPath,
                    lines: [],
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: [],
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: nil,
                    diskFileLineCount: 0
                )
                buffer.isFullFile = true
                multiBuffer.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: file.status,
                    bufferRange: 0..<0,
                    hunk: nil,
                    isCollapsed: false,
                    isFileStart: true
                )
                multiBuffer.addExcerpt(excerpt)
            } else {
                for (hIdx, hunk) in file.hunks.enumerated() {
                    let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                    let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                    let startLine = hunk.newRange.lowerBound

                    let buffer = Buffer(
                        filePath: file.displayPath,
                        lines: newFileLines,
                        language: Buffer.detectLanguage(for: file.displayPath),
                        baselineLines: oldBaselineLines,
                        totalAdditions: fileAdds,
                        totalDeletions: fileDels,
                        startLineNumber: startLine,
                        fullDiskPath: nil,
                        diskFileLineCount: nil
                    )
                    buffer.isFullFile = (file.status == .added && file.hunks.count == 1)
                    multiBuffer.addBuffer(buffer)

                    let excerpt = Excerpt(
                        bufferId: buffer.id,
                        filePath: file.displayPath,
                        fileStatus: file.status,
                        bufferRange: 0..<buffer.lineCount,
                        hunk: hunk,
                        isCollapsed: false,
                        isFileStart: (hIdx == 0)
                    )
                    multiBuffer.addExcerpt(excerpt)
                }
            }
        }
    }

    // MARK: - Current Directory Diff Loading

    public func loadCurrentDirectoryDiff() {
        // A local project must leave remote mode first. Otherwise fetchGitDiff
        // receives `.remote` and intentionally returns no local diff.
        if case .remote = comparisonTarget {
            remoteLoadTask?.cancel()
            remoteLoadTask = nil
            loadGeneration &+= 1
            isReloading = false
            isStreaming = false
            remoteTarget = nil
            remoteErrorMessage = nil
            comparisonTarget = .workingTree
        }

        guard !isReloading else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReloading = true
        let currentDir = currentPath ?? initialPath ?? FileManager.default.currentDirectoryPath
        multiBuffer.baseDirectory = currentDir
        let folderName = (currentDir as NSString).lastPathComponent
        self.currentFolderName = folderName
        DispatchQueue.main.async {
            NSApp.windows.first?.title = "\(folderName)"
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let isGit = self.isGitRepository(at: currentDir)
            let branch = isGit ? self.fetchCurrentBranch(at: currentDir) : ""
            let branches = isGit ? self.fetchAvailableBranches(at: currentDir) : (local: [], remote: [])
            let diff = isGit ? self.fetchGitDiff(at: currentDir, target: self.comparisonTarget) : nil

            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.currentBranch = branch
                self.localBranches = branches.local
                self.remoteBranches = branches.remote

                guard isGit else {
                    self.repoStatus = .notGitRepository
                    self.loadDiff(text: "")
                    self.isReloading = false
                    return
                }
                RecentSourcesManager.shared.addLocalPath(currentDir)
                if let diff = diff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.repoStatus = .hasChanges
                    self.loadDiff(text: diff)
                } else {
                    self.repoStatus = .clean
                    self.loadDiff(text: "")
                }
                self.isReloading = false
            }
        }
    }

    private func isGitRepository(at path: String) -> Bool {
        return runGit(arguments: ["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
    }

    private func fetchCurrentBranch(at path: String) -> String {
        runGit(arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
    }

    private func fetchAvailableBranches(at path: String) -> (local: [String], remote: [String]) {
        let localOut = runGit(arguments: ["-C", path, "branch", "--format=%(refname:short)"]) ?? ""
        let local = localOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let remoteOut = runGit(arguments: ["-C", path, "branch", "-r", "--format=%(refname:short)"]) ?? ""
        let remote = remoteOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.contains("HEAD") }

        return (local, remote)
    }

    private func fetchGitDiff(at path: String, target: ComparisonTarget = .workingTree) -> String? {
        switch target {
        case .workingTree:
            // 1. Try uncommitted (staged + unstaged) changes: git diff HEAD
            if let out = runGit(arguments: ["-C", path, "diff", "HEAD"]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            // 2. Try unstaged changes: git diff
            if let out = runGit(arguments: ["-C", path, "diff"]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            // 3. Try staged changes: git diff --staged
            if let out = runGit(arguments: ["-C", path, "diff", "--staged"]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            return nil

        case .baseBranch(let base):
            // Triple-dot diff: git diff <base>...
            if let out = runGit(arguments: ["-C", path, "diff", "\(base)..."]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            if let out = runGit(arguments: ["-C", path, "diff", "\(base)..HEAD"]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            return nil

        case .directBranch(let branch):
            // Direct diff against branch: git diff <branch>
            if let out = runGit(arguments: ["-C", path, "diff", branch]), !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return out
            }
            return nil

        case .remote:
            return nil
        }
    }

    private func runGit(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Diff Loading & MultiBuffer Assembly

    public func loadDiff(text: String) {
        let parsedFiles = GitDiffParser.shared.parse(diffText: text)
        self.fileDiffs = parsedFiles

        multiBuffer.clear()
        displayMap.clear()
        LineLayoutCache.shared.clear()
        SyntaxHighlighter.shared.clearCache()

        let baseDir = (multiBuffer.baseDirectory?.isEmpty == false) ? (multiBuffer.baseDirectory ?? FileManager.default.currentDirectoryPath) : FileManager.default.currentDirectoryPath

        for file in parsedFiles {
            let relativePath = file.displayPath
            var fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: fullPath) {
                let components = relativePath.components(separatedBy: "/")
                if components.count > 1 {
                    let subPath = components.dropFirst().joined(separator: "/")
                    let altPath = (baseDir as NSString).appendingPathComponent(subPath)
                    if FileManager.default.fileExists(atPath: altPath) {
                        fullPath = altPath
                    }
                }
            }
            let fileExists = FileManager.default.fileExists(atPath: fullPath)
            let fullDiskText = fileExists ? (try? String(contentsOfFile: fullPath, encoding: .utf8)) : nil
            let fullDiskLineCount = fullDiskText?.components(separatedBy: "\n").count

            let fileAdds = file.additions
            let fileDels = file.deletions

            if let diskText = fullDiskText, let diskCount = fullDiskLineCount {
                // 1. File exists on disk: build ONE full-file buffer with exact baseline lines
                var baselineLines = diskText.components(separatedBy: "\n")
                let sortedHunks = file.hunks.sorted { $0.newRange.lowerBound > $1.newRange.lowerBound }
                for hunk in sortedHunks {
                    let newStart = max(0, min(baselineLines.count, hunk.newRange.lowerBound - 1))
                    let newCount = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.count
                    let newEnd = max(newStart, min(baselineLines.count, newStart + newCount))
                    let oldHunkLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                    baselineLines.replaceSubrange(newStart..<newEnd, with: oldHunkLines)
                }
                let baselineText = baselineLines.joined(separator: "\n")

                let buffer = Buffer(
                    filePath: file.displayPath,
                    text: diskText,
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineText: baselineText,
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: fullPath,
                    diskFileLineCount: diskCount
                )
                buffer.isFullFile = true
                multiBuffer.addBuffer(buffer)

                if file.hunks.isEmpty {
                    let excerpt = Excerpt(
                        bufferId: buffer.id,
                        filePath: file.displayPath,
                        fileStatus: file.status,
                        bufferRange: 0..<buffer.lineCount,
                        hunk: nil,
                        isCollapsed: false,
                        isFileStart: true
                    )
                    multiBuffer.addExcerpt(excerpt)
                } else {
                    for (hIdx, hunk) in file.hunks.enumerated() {
                        let startRow = max(0, min(buffer.lineCount, hunk.newRange.lowerBound - 1))
                        let newCount = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.count
                        let endRow = max(startRow, min(buffer.lineCount, startRow + newCount))
                        let excerpt = Excerpt(
                            bufferId: buffer.id,
                            filePath: file.displayPath,
                            fileStatus: file.status,
                            bufferRange: startRow..<endRow,
                            hunk: hunk,
                            isCollapsed: false,
                            isFileStart: (hIdx == 0)
                        )
                        multiBuffer.addExcerpt(excerpt)
                    }
                }
            } else if file.status == .deleted {
                let oldLines = file.hunks.flatMap { $0.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text) }
                let buffer = Buffer(
                    filePath: file.displayPath,
                    text: "",
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineText: oldLines.joined(separator: "\n"),
                    totalAdditions: 0,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: nil,
                    diskFileLineCount: 0
                )
                buffer.isFullFile = true
                multiBuffer.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: .deleted,
                    bufferRange: 0..<0,
                    hunk: file.hunks.first,
                    isCollapsed: false,
                    isFileStart: true
                )
                multiBuffer.addExcerpt(excerpt)
            } else {
                // File does NOT exist on disk (pasted / mock diff / remote PR)
                if file.hunks.isEmpty {
                    let buffer = Buffer(
                        filePath: file.displayPath,
                        text: "",
                        language: Buffer.detectLanguage(for: file.displayPath),
                        baselineText: "",
                        totalAdditions: fileAdds,
                        totalDeletions: fileDels,
                        startLineNumber: 1,
                        fullDiskPath: nil,
                        diskFileLineCount: 0
                    )
                    buffer.isFullFile = true
                    multiBuffer.addBuffer(buffer)

                    let excerpt = Excerpt(
                        bufferId: buffer.id,
                        filePath: file.displayPath,
                        fileStatus: file.status,
                        bufferRange: 0..<0,
                        hunk: nil,
                        isCollapsed: false,
                        isFileStart: true
                    )
                    multiBuffer.addExcerpt(excerpt)
                } else {
                    for (hIdx, hunk) in file.hunks.enumerated() {
                        let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                        let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                        let startLine = hunk.newRange.lowerBound

                        let buffer = Buffer(
                            filePath: file.displayPath,
                            lines: newFileLines,
                            language: Buffer.detectLanguage(for: file.displayPath),
                            baselineLines: oldBaselineLines,
                            totalAdditions: fileAdds,
                            totalDeletions: fileDels,
                            startLineNumber: startLine,
                            fullDiskPath: nil,
                            diskFileLineCount: nil
                        )
                        buffer.isFullFile = (file.status == .added && file.hunks.count == 1)
                        multiBuffer.addBuffer(buffer)

                        let excerpt = Excerpt(
                            bufferId: buffer.id,
                            filePath: file.displayPath,
                            fileStatus: file.status,
                            bufferRange: 0..<buffer.lineCount,
                            hunk: hunk,
                            isCollapsed: false,
                            isFileStart: (hIdx == 0)
                        )
                        multiBuffer.addExcerpt(excerpt)
                    }
                }
            }
        }

        displayMap.rebuild()
    }

    private func openGitRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository to view uncommitted diffs"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            self.currentPath = path
            // `loadCurrentDirectoryDiff` handles cancellation and the mode
            // transition from a remote stream to the selected local project.
            loadCurrentDirectoryDiff()
        }
    }

    private func expandAllExcerpts() {
        for i in 0..<multiBuffer.excerpts.count {
            multiBuffer.expandExcerptAll(at: i)
        }
        displayMap.rebuild()
    }

    private func collapseAllExcerpts() {
        multiBuffer.collapseAll()
        displayMap.rebuild()
    }
}

struct IdentifiableCommentTarget: Identifiable {
    var id: String { "\(filePath):\(lineNumber)" }
    let filePath: String
    let lineNumber: Int
}

struct ThemePickerPopoverView: View {
    @Binding var selectedTheme: Theme
    @Binding var followsSystemAppearance: Bool
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COLOR THEME")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
            Divider()
            Button(action: {
                followsSystemAppearance = true
                isPresented = false
            }) {
                HStack {
                    Text("System")
                        .font(.system(size: 12))
                    Spacer()
                    if followsSystemAppearance {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            ForEach(Theme.allThemes, id: \.id) { theme in
                Button(action: {
                    selectedTheme = theme
                    followsSystemAppearance = false
                    isPresented = false
                }) {
                    HStack {
                        Text(theme.name)
                            .font(.system(size: 12))
                        Spacer()
                        if followsSystemAppearance == false && selectedTheme.id == theme.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 170)
    }
}

public struct ToolbarHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.secondary.opacity(configuration.isPressed ? 0.24 : 0.14) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}
