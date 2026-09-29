import Foundation
import SwiftUI
import Combine
import AppKit
import AnyDiffCore

@MainActor
public final class RepoCoordinator: ObservableObject {
    public enum RepoStatus {
        case notGitRepository
        case clean
        case hasChanges
    }

    // MARK: - Published State

    @Published public var currentPath: String? = nil
    @Published public var currentFolderName: String = ""
    @Published public var currentBranch: String = ""
    @Published public var localBranches: [String] = []
    @Published public var remoteBranches: [String] = []
    @Published public var comparisonTarget: ComparisonTarget = .workingTree
    @Published public var repoStatus: RepoStatus = .clean
    @Published public var fileDiffs: [FileDiff] = []
    @Published public var selectedCommit: GitCommit? = nil
    @Published public var showCommitDetailPopover: Bool = false
    @Published public var selectedFilePath: String? = nil
    @Published public var manuallyOpenedFilePaths: Set<String> = []
    @Published public var isWatchModeEnabled: Bool = true
    @Published public var isReloading: Bool = false
    @Published public var isStreaming: Bool = false
    @Published public var streamingCount: Int = 0
    @Published public var remoteTarget: GitHubDiffReference? = nil
    @Published public var remoteErrorMessage: String? = nil

    // MARK: - Owned Storage

    public let multiBuffer: MultiBuffer
    public let displayMap: DisplayMap

    // MARK: - External Delegates & References

    public weak var search: SearchCoordinator? = nil
    public var onFileSystemChanged: (() -> Void)? = nil
    public var onSelectFile: ((String) -> Void)? = nil

    // MARK: - Internal Watcher & Task State

    public private(set) var folderWatcher: FolderWatcher? = nil
    private var remoteLoadTask: Task<Void, Never>? = nil
    private var gitStateReloadWorkItem: DispatchWorkItem? = nil
    private var hasPendingGitStateReload: Bool = false
    private var loadGeneration: UInt64 = 0
    public var reloadToken: UInt64 { loadGeneration }
    private var watchRefreshGeneration: UInt64 = 0
    private var pendingWatchPaths: Set<String> = []
    private var watchRefreshInFlight: Bool = false
    private var cancellables: Set<AnyCancellable> = []

    public let initialPath: String?

    // MARK: - Initialization

    public init(initialPath: String? = nil, reviewManager: ReviewManager = ReviewManager()) {
        self.initialPath = initialPath
        let mb = MultiBuffer()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: reviewManager)
        let initialLayout = (UserDefaults.standard.string(forKey: "preferredDiffLayoutMode").flatMap(DiffLayoutMode.init)) ?? .unified
        dm.layoutMode = initialLayout
        self.multiBuffer = mb
        self.displayMap = dm

        mb.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Directory Resolution

    public var loadableWorkingDirectory: String? {
        let candidate: String?
        if let currentPath, !currentPath.isEmpty {
            candidate = currentPath
        } else if let initialPath, !initialPath.isEmpty {
            candidate = initialPath
        } else {
            candidate = nil
        }

        guard let candidate else { return nil }
        let resolved = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard !resolved.isEmpty, resolved != home else { return nil }
        return resolved
    }

    public var effectiveWorkingDirectory: String {
        if let loadableWorkingDirectory {
            return loadableWorkingDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var effectiveBaseDirectory: String {
        if let base = multiBuffer.baseDirectory, !base.isEmpty {
            return (base as NSString).expandingTildeInPath
        }
        return effectiveWorkingDirectory
    }

    public func externalFilePath(for relativePath: String) -> String? {
        let base = effectiveBaseDirectory
        guard !base.isEmpty else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(relativePath).path
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

        multiBuffer.clear()
        displayMap.clear()
        fileDiffs = []
        selectedFilePath = nil
        search?.reset()

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
                            self.displayMap.markContentLoaded()
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
                    self.displayMap.markContentLoaded()

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

    public func appendFileDiffsToMultiBuffer(_ files: [FileDiff], rawData: Data? = nil, into destination: MultiBuffer? = nil) {
        MultiBufferBuilder.append(
            files: files,
            rawData: rawData,
            baseDirectory: effectiveBaseDirectory,
            into: destination ?? multiBuffer
        )
    }

    // MARK: - Current Directory Diff Loading

    public func loadCurrentDirectoryDiff() {
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

        let currentDir = effectiveWorkingDirectory
        guard !currentDir.isEmpty else {
            clearLocalDirectoryState()
            return
        }

        guard !isReloading else {
            hasPendingGitStateReload = true
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReloading = true
        if multiBuffer.baseDirectory != currentDir {
            search?.reset()
            manuallyOpenedFilePaths.removeAll()
            selectedFilePath = nil
            selectedCommit = nil
            if case .commit = comparisonTarget {
                comparisonTarget = .workingTree
            }
        }
        multiBuffer.baseDirectory = currentDir
        let folderName = (currentDir as NSString).lastPathComponent
        self.currentFolderName = folderName
        DispatchQueue.main.async {
            NSApplication.shared.windows.first?.title = "\(folderName)"
        }

        if isWatchModeEnabled {
            let resolvedDir = URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path
            if folderWatcher == nil || folderWatcher?.watchedURL.path != resolvedDir {
                restartWatcher(for: currentDir)
            }
        }

        let currentTarget = self.comparisonTarget
        DispatchQueue.global(qos: .userInitiated).async {
            let isGit = GitService.shared.isRepository(at: currentDir)
            let branch = isGit ? GitService.shared.currentBranch(at: currentDir) : ""
            let branches = isGit ? GitService.shared.branches(at: currentDir) : (local: [], remote: [])
            let (files, rawData) = isGit ? GitService.shared.diffFiles(at: currentDir, target: currentTarget) : (files: [], data: nil)

            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.currentBranch = branch
                self.localBranches = branches.local
                self.remoteBranches = branches.remote

                defer {
                    self.isReloading = false
                    if self.hasPendingGitStateReload {
                        self.hasPendingGitStateReload = false
                        self.scheduleGitStateReload()
                    }
                }

                guard isGit else {
                    self.repoStatus = .notGitRepository
                    self.loadDiff(files: [])
                    return
                }
                RecentSourcesManager.shared.addLocalPath(currentDir)
                if !files.isEmpty {
                    self.repoStatus = .hasChanges
                    self.loadDiff(files: files, rawData: rawData)
                } else {
                    self.repoStatus = .clean
                    self.loadDiff(files: [])
                }
            }
        }
    }

    public func clearLocalDirectoryState() {
        loadGeneration &+= 1
        gitStateReloadWorkItem?.cancel()
        gitStateReloadWorkItem = nil
        hasPendingGitStateReload = false
        isReloading = false
        isStreaming = false
        streamingCount = 0

        folderWatcher?.stop()
        folderWatcher = nil
        pendingWatchPaths.removeAll()
        watchRefreshGeneration &+= 1
        watchRefreshInFlight = false

        currentFolderName = ""
        currentBranch = ""
        localBranches = []
        remoteBranches = []
        repoStatus = .notGitRepository
        selectedFilePath = nil
        selectedCommit = nil
        if case .commit = comparisonTarget {
            comparisonTarget = .workingTree
        }
        manuallyOpenedFilePaths.removeAll()
        multiBuffer.baseDirectory = nil
        search?.reset()
        loadDiff(files: [])

        DispatchQueue.main.async {
            NSApp.windows.first?.title = "AnyDiff"
        }
    }

    public func setWatchModeEnabled(_ enabled: Bool) {
        isWatchModeEnabled = enabled
        if enabled {
            guard let currentDir = loadableWorkingDirectory else {
                stopWatcher()
                return
            }
            restartWatcher(for: currentDir)
            startPendingWatchRefresh(directory: currentDir)
        } else {
            stopWatcher()
        }
    }

    public func stopWatcher() {
        folderWatcher?.stop()
        folderWatcher = nil
        pendingWatchPaths.removeAll()
        watchRefreshGeneration &+= 1
    }

    public func restartWatcher(for directoryPath: String) {
        folderWatcher?.stop()
        folderWatcher = nil

        guard isWatchModeEnabled, !directoryPath.isEmpty else { return }
        guard loadableWorkingDirectory == URL(fileURLWithPath: directoryPath).standardizedFileURL.path else { return }

        let watcher = FolderWatcher(url: URL(fileURLWithPath: directoryPath)) { [weak self] events in
            guard let self else { return }
            Task { @MainActor in
                self.handleFolderWatcherEvents(events)
            }
        }
        watcher.start()
        self.folderWatcher = watcher
    }

    public func scheduleGitStateReload() {
        gitStateReloadWorkItem?.cancel()
        if isReloading {
            hasPendingGitStateReload = true
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isWatchModeEnabled else { return }
            if self.isReloading {
                self.hasPendingGitStateReload = true
                return
            }
            self.loadCurrentDirectoryDiff()
        }
        gitStateReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    public func handleFolderWatcherEvents(_ events: [FileSystemChangeEvent]) {
        guard isWatchModeEnabled else { return }
        if case .remote = comparisonTarget { return }

        let meaningful = events.filter { !FolderWatcher.shouldIgnore(path: $0.path) }
        guard !meaningful.isEmpty else { return }

        if isReloading {
            DispatchQueue.main.async {
                self.hasPendingGitStateReload = true
            }
            return
        }

        // Check if any event was caused by git commit, checkout, branch switch, add/reset
        let hasGitStateChange = meaningful.contains { event in
            event.path.contains("/.git/HEAD")
                || event.path.contains("/.git/refs/")
                || event.path.hasSuffix("/.git/index")
                || event.path.hasSuffix("/.git/packed-refs")
                || event.path.hasSuffix("/.git/commondir")
        }

        if hasGitStateChange {
            DispatchQueue.main.async {
                self.onFileSystemChanged?()
                self.scheduleGitStateReload()
            }
            return
        }

        let currentDir = effectiveWorkingDirectory
        let resolvedCurrentDir = URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path

        var changedPaths = Set<String>()
        var hasRenameEvents = false

        for event in meaningful {
            let resolvedEventPath = URL(fileURLWithPath: event.path).resolvingSymlinksInPath().path
            if resolvedEventPath == resolvedCurrentDir {
                continue
            }

            let prefix = resolvedCurrentDir.hasSuffix("/") ? resolvedCurrentDir : resolvedCurrentDir + "/"
            guard resolvedEventPath.hasPrefix(prefix) else { continue }
            let relative = String(resolvedEventPath.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }

            // Skip files currently being typed in by the user in main diff or search.
            if multiBuffer.isFileDirty(filePath: relative) || (search?.multiBuffer.isFileDirty(filePath: relative) == true) {
                continue
            }

            if multiBuffer.shouldIgnoreSelfSavedEvent(
                filePath: relative,
                diskPath: resolvedEventPath,
                threshold: 3.0
            ) || (search?.multiBuffer.shouldIgnoreSelfSavedEvent(
                filePath: relative,
                diskPath: resolvedEventPath,
                threshold: 3.0
            ) == true) {
                continue
            }

            changedPaths.insert(relative)
            if event.changeTypes.contains(.renamed) {
                hasRenameEvents = true
            }
        }

        guard !changedPaths.isEmpty else { return }
        DispatchQueue.main.async {
            self.onFileSystemChanged?()
            self.pendingWatchPaths.formUnion(changedPaths)
            guard !self.watchRefreshInFlight else { return }
            self.startPendingWatchRefresh(directory: resolvedCurrentDir, checkRenames: hasRenameEvents)
        }
    }

    private func startPendingWatchRefresh(directory: String, checkRenames: Bool = false) {
        guard loadableWorkingDirectory == URL(fileURLWithPath: directory).standardizedFileURL.path,
              !pendingWatchPaths.isEmpty,
              !watchRefreshInFlight else { return }
        let paths = pendingWatchPaths
        pendingWatchPaths.removeAll()
        watchRefreshInFlight = true

        // Snapshot all currently displayed buffers in O(Excerpts)
        var snapshots: [String: [(BufferId, Int)]] = [:]
        snapshots.reserveCapacity(multiBuffer.excerpts.count)
        for excerpt in multiBuffer.excerpts {
            let version = multiBuffer.buffer(for: excerpt.bufferId)?.version ?? -1
            snapshots[excerpt.filePath, default: []].append((excerpt.bufferId, version))
        }
        watchRefreshGeneration &+= 1
        let refreshGeneration = watchRefreshGeneration
        let target = comparisonTarget

        DispatchQueue.global(qos: .userInitiated).async {
            var effectivePaths = paths
            if checkRenames {
                for path in paths {
                    let renames = GitService.shared.renamedPaths(at: directory, relatedTo: path)
                    effectivePaths.formUnion(renames)
                }
            }
            let result = GitService.shared.diffFiles(at: directory, target: target, pathFilter: effectivePaths)
            DispatchQueue.main.async {
                defer {
                    self.watchRefreshInFlight = false
                    if self.isWatchModeEnabled && self.comparisonTarget == target {
                        let currentDir = self.effectiveWorkingDirectory
                        self.startPendingWatchRefresh(directory: URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path)
                    }
                }
                guard self.isWatchModeEnabled,
                      self.watchRefreshGeneration == refreshGeneration,
                      self.comparisonTarget == target else { return }

                // Group current excerpts by path for fast O(1) comparison
                var currentByPath: [String: [(BufferId, Int)]] = [:]
                for excerpt in self.multiBuffer.excerpts {
                    let version = self.multiBuffer.buffer(for: excerpt.bufferId)?.version ?? -1
                    currentByPath[excerpt.filePath, default: []].append((excerpt.bufferId, version))
                }

                // Dirty buffers and any buffer edited since the read began are
                // left untouched. They will be reflected on a later explicit
                // reload after the user saves/finishes editing.
                let candidatePaths = effectivePaths
                    .union(result.files.map(\.displayPath))
                    .union(result.files.filter { $0.status == .renamed }.map(\.oldPath))
                var safePaths = Set(candidatePaths.filter { path in
                    guard !self.multiBuffer.isFileDirty(filePath: path) else { return false }
                    let current = currentByPath[path] ?? []
                    guard let expected = snapshots[path] else { return current.isEmpty }
                    guard expected.count == current.count else { return false }
                    return expected.elementsEqual(current) { lhs, rhs in
                        lhs.0 == rhs.0 && lhs.1 == rhs.1
                    }
                })
                // A rename is one logical file transition. Never apply only
                // its new side when the old side was edited or changed during
                // the async read; that would duplicate the dirty content.
                for rename in result.files where rename.status == .renamed {
                    guard safePaths.contains(rename.oldPath), safePaths.contains(rename.newPath) else {
                        safePaths.remove(rename.oldPath)
                        safePaths.remove(rename.newPath)
                        safePaths.remove(rename.displayPath)
                        continue
                    }
                }
                guard !safePaths.isEmpty else { return }

                var searchPathsToInvalidate: Set<String> = []
                for path in safePaths {
                    let diff = result.files.first { $0.displayPath == path }
                    self.applyWatchedFile(path: path, diff: diff, rawData: result.data)
                    if let search = self.search, let fullPath = self.externalFilePath(for: path),
                       search.applyWatchedFile(path: path, fullDiskPath: fullPath) {
                        searchPathsToInvalidate.insert(path)
                    }
                }
                self.displayMap.rebuild(invalidatingPaths: safePaths)
                self.displayMap.markContentLoaded()
                self.updateWatchedFileDiffs(result.files, safePaths: safePaths)
                if !searchPathsToInvalidate.isEmpty {
                    self.search?.recalculateAfterWatch(invalidatedPaths: searchPathsToInvalidate)
                }
            }
        }
    }

    private func updateWatchedFileDiffs(_ refreshed: [FileDiff], safePaths: Set<String>) {
        let oldFiles = fileDiffs
        let refreshedByDisplay = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.displayPath, $0) })
        let renamedByOld = Dictionary(uniqueKeysWithValues: refreshed.filter { $0.status == .renamed }.map { ($0.oldPath, $0) })
        var updated: [FileDiff] = []
        var consumed = Set<String>()

        for oldFile in oldFiles {
            if let rename = renamedByOld[oldFile.displayPath], safePaths.contains(oldFile.displayPath) {
                updated.append(rename)
                consumed.insert(rename.displayPath)
            } else if safePaths.contains(oldFile.displayPath) {
                if let replacement = refreshedByDisplay[oldFile.displayPath] {
                    updated.append(replacement)
                    consumed.insert(replacement.displayPath)
                }
            } else {
                updated.append(oldFile)
            }
        }

        for file in refreshed where safePaths.contains(file.displayPath) && !consumed.contains(file.displayPath) {
            updated.append(file)
        }
        fileDiffs = updated
        if fileDiffs.isEmpty {
            repoStatus = .clean
            selectedFilePath = nil
        } else {
            repoStatus = .hasChanges
            if let current = selectedFilePath,
               (fileDiffs.contains(where: { $0.displayPath == current || $0.newPath == current || $0.oldPath == current }) ||
                multiBuffer.excerpts.contains(where: { $0.filePath == current })) {
                // Keep existing selection intact
            } else {
                selectedFilePath = fileDiffs.first?.displayPath
            }
        }
    }

    private func applyWatchedFile(path: String, diff: FileDiff?, rawData: Data?) {
        if let fullPath = externalFilePath(for: path),
           let externalText = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            if let existingBuffer = multiBuffer.buffers.values.first(where: {
                $0.filePath == path && $0.isFullFile && !$0.isLazySlice
            }), existingBuffer.text() == externalText {
                return
            }

            if multiBuffer.applyExternalTextUpdate(
                filePath: path,
                newText: externalText,
                updateBaseline: multiBuffer.contentMode == .text
            ) {
                return
            }
        }

        let collapsed = multiBuffer.excerpts
            .filter { $0.filePath == path }
            .contains { $0.isCollapsed }

        let rebuilt = MultiBuffer()
        rebuilt.baseDirectory = multiBuffer.baseDirectory
        if let diff {
            MultiBufferBuilder.append(
                files: [diff],
                rawData: rawData,
                baseDirectory: effectiveBaseDirectory,
                collapsedPaths: collapsed ? [path] : [],
                into: rebuilt
            )
        }
        multiBuffer.replaceFile(
            filePath: path,
            buffers: Array(rebuilt.buffers.values),
            excerpts: rebuilt.excerpts
        )
    }

    // MARK: - Diff Loading & MultiBuffer Assembly

    public func loadDiff(text: String) {
        let data = Data(text.utf8)
        loadDiff(data: data)
    }

    public func loadDiff(data: Data) {
        let parsedFiles = GitDiffParser.shared.parseZeroCopy(data: data)
        loadDiff(files: parsedFiles, rawData: data)
    }

    public func loadDiff(files parsedFiles: [FileDiff], rawData: Data? = nil) {
        let collapsedFilePaths = Set(multiBuffer.excerpts.filter { $0.isCollapsed }.map { $0.filePath })
        var allFiles = parsedFiles
        for cleanPath in manuallyOpenedFilePaths {
            if !allFiles.contains(where: { $0.displayPath == cleanPath }) {
                let cleanDiff = FileDiff(oldPath: cleanPath, newPath: cleanPath, status: .unmodified, hunks: [])
                let insertIndex = allFiles.firstIndex(where: {
                    $0.displayPath.localizedStandardCompare(cleanPath) == .orderedDescending
                }) ?? allFiles.count
                allFiles.insert(cleanDiff, at: insertIndex)
            }
        }

        self.fileDiffs = allFiles

        multiBuffer.clear()
        multiBuffer.setContentMode(.diff)
        displayMap.clear()
        SyntaxHighlighter.shared.clearCache()

        MultiBufferBuilder.append(
            files: allFiles,
            rawData: rawData,
            baseDirectory: effectiveBaseDirectory,
            collapsedPaths: collapsedFilePaths,
            into: multiBuffer
        )

        displayMap.rebuild()
        displayMap.markContentLoaded()

        let currentSelected = selectedFilePath
        if let sel = currentSelected, parsedFiles.contains(where: { $0.displayPath == sel }) {
            self.selectedFilePath = sel
        } else if self.selectedFilePath == nil || !parsedFiles.contains(where: { $0.displayPath == self.selectedFilePath }) {
            self.selectedFilePath = parsedFiles.first?.displayPath
        }
    }

    public func openGitRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository to view uncommitted diffs"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            self.currentPath = path
            loadCurrentDirectoryDiff()
        }
    }

    // MARK: - Editor File Opening & Closing

    public func openFile(path: String, line: Int? = nil, endLine: Int? = nil) {
        let baseDir = effectiveWorkingDirectory
        let resolvedRelativePath: String
        let fullDiskPath: String

        if (path as NSString).isAbsolutePath {
            fullDiskPath = path
            if path.hasPrefix(baseDir) {
                let suffix = String(path.dropFirst(baseDir.count))
                resolvedRelativePath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                resolvedRelativePath = (path as NSString).lastPathComponent
            }
        } else {
            resolvedRelativePath = path
            fullDiskPath = (baseDir as NSString).appendingPathComponent(path)
        }

        // 1. Check if already present in displayMap
        if let targetFile = displayMap.matchFilePath(resolvedRelativePath) ?? displayMap.matchFilePath(path) {
            selectedFilePath = targetFile
            NotificationCenter.default.post(
                name: .focusFileInEditor,
                object: FileNavigationRequest(filePath: targetFile, lineNumber: line, endLineNumber: endLine)
            )
            return
        }

        // 2. Not present: read from disk and insert as clean unmodified buffer
        guard let clean = MultiBufferBuilder.makeCleanFileBuffer(
            fullDiskPath: fullDiskPath,
            relativePath: resolvedRelativePath
        ) else { return }

        let insertIndex = fileDiffs.firstIndex(where: {
            $0.displayPath.localizedStandardCompare(resolvedRelativePath) == .orderedDescending
        }) ?? fileDiffs.count
        fileDiffs.insert(clean.fileDiff, at: insertIndex)

        multiBuffer.replaceFile(filePath: resolvedRelativePath, buffers: [clean.buffer], excerpts: [clean.excerpt])
        manuallyOpenedFilePaths.insert(resolvedRelativePath)

        displayMap.rebuild()
        selectedFilePath = resolvedRelativePath

        NotificationCenter.default.post(
            name: .focusFileInEditor,
            object: FileNavigationRequest(filePath: resolvedRelativePath, lineNumber: line, endLineNumber: endLine)
        )
    }

    public func closeFile(filePath: String) {
        fileDiffs.removeAll { $0.displayPath == filePath }
        multiBuffer.removeFile(filePath: filePath)
        manuallyOpenedFilePaths.remove(filePath)
        displayMap.rebuild()
        displayMap.markContentLoaded()
        if selectedFilePath == filePath {
            selectedFilePath = fileDiffs.first?.displayPath
        }
    }
}
