import SwiftUI
import AppKit
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

    @State private var cursorLocation: ExcerptLocation? = nil
    @State private var cursorPoint: MultiBufferPoint = .zero

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var commentTarget: (filePath: String, lineNumber: Int)? = nil
    @State private var currentFolderName: String = ""
    @State private var showThemePicker: Bool = false

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
        guard followsSystemAppearance == false else {
            return systemAppearance.isDark ? .unifiedDark : .macOSLight
        }
        return selectedTheme
    }

    private var activeThemeName: String {
        followsSystemAppearance ? "System (\(systemAppearance.isDark ? "Dark" : "Light"))" : selectedTheme.name
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarFileListView(
                fileDiffs: fileDiffs,
                theme: activeTheme,
                emptyMessage: repoStatus == .notGitRepository ? "Not a Git repository" : "No changed files",
                isReloading: isReloading,
                comparisonTarget: comparisonTarget,
                currentBranch: currentBranch,
                reviewManager: reviewManager,
                selectedFilePath: $selectedFilePath,
                onReload: { loadCurrentDirectoryDiff() }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 800)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if columnVisibility != .detailOnly {
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
                }
            }
        } detail: {
            Group {
                if fileDiffs.isEmpty {
                    VStack(spacing: 14) {
                        switch repoStatus {
                        case .notGitRepository:
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 44, weight: .ultraLight))
                                .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                            Text("Not a Git Repository")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(activeTheme.foreground))

                            Text(currentFolderName.isEmpty ? "The selected directory has no Git repository initialized." : "Directory \"\(currentFolderName)\" is not a Git repository.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(activeTheme.gutterForeground))

                            HStack(spacing: 10) {
                                Button(action: { openGitRepositoryFolder() }) {
                                    Label("Open Git Project...", systemImage: "folder")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.top, 4)

                        case .clean, .hasChanges:
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 44, weight: .ultraLight))
                                .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                            Text("No Uncommitted Changes")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(activeTheme.foreground))

                            Text("Working tree in \(currentFolderName.isEmpty ? "project" : "\"\(currentFolderName)\"") is clean.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(activeTheme.gutterForeground))

                            HStack(spacing: 10) {
                                Button(action: { openGitRepositoryFolder() }) {
                                    Label("Open Project...", systemImage: "folder")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button(action: { loadCurrentDirectoryDiff() }) {
                                    HStack(spacing: 6) {
                                        if isReloading {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                        Text(isReloading ? "Reloading..." : "Reload Diff")
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isReloading)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(activeTheme.background))
                } else {
                    EditorHostView(
                        displayMap: displayMap,
                        theme: activeTheme,
                        fontSize: fontSize,
                        isEditable: (comparisonTarget == .workingTree),
                        selectedFilePath: selectedFilePath,
                        onCursorChange: { loc, pt in
                            cursorLocation = loc
                            cursorPoint = pt
                        },
                        onAddCommentRequest: { path, line in
                            commentTarget = (filePath: path, lineNumber: line)
                        }
                    )
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 6) {
                        Button(action: { openGitRepositoryFolder() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text(currentFolderName.isEmpty ? "AnyDiff" : currentFolderName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.primary)
                            }
                        }
                        .buttonStyle(ToolbarHoverButtonStyle())
                        .help("Open Git Repository (Cmd+O)")

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
                            .help("Branch comparison is read-only. Switch to 'Working Tree' in the branch menu to edit.")
                        }
                    }
                }
            }
            .background(
                Group {
                    Button(action: { loadCurrentDirectoryDiff() }) {}
                        .keyboardShortcut("r", modifiers: .command)
                    Button(action: { openGitRepositoryFolder() }) {}
                        .keyboardShortcut("o", modifiers: .command)
                    Button(action: { fontSize = max(9, fontSize - 1) }) {}
                        .keyboardShortcut("-", modifiers: .command)
                    Button(action: { fontSize = min(28, fontSize + 1) }) {}
                        .keyboardShortcut("+", modifiers: .command)
                    Button(action: { fontSize = min(28, fontSize + 1) }) {}
                        .keyboardShortcut("=", modifiers: .command)
                }
                .opacity(0)
            )
        }
        .toolbarBackground(Color(activeTheme.background), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(activeTheme.isDark ? .dark : .light, for: .windowToolbar)
        .background(Color(activeTheme.background).ignoresSafeArea())
        .sheet(item: Binding(
            get: { commentTarget.map { IdentifiableCommentTarget(filePath: $0.filePath, lineNumber: $0.lineNumber) } },
            set: { _ in commentTarget = nil }
        )) { target in
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
        .onAppear {
            loadCurrentDirectoryDiff()
            updateWindowAppearance()
        }
        .onChange(of: selectedTheme.id) { _ in
            updateWindowAppearance()
        }
        .onChange(of: followsSystemAppearance) { _ in
            updateWindowAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenProject"))) { _ in
            openGitRepositoryFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffReloadDiff"))) { _ in
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

    // MARK: - Current Directory Diff Loading

    public func loadCurrentDirectoryDiff() {
        guard !isReloading else { return }
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
                self.currentBranch = branch
                self.localBranches = branches.local
                self.remoteBranches = branches.remote

                guard isGit else {
                    self.repoStatus = .notGitRepository
                    self.loadDiff(text: "")
                    self.isReloading = false
                    return
                }
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
                // File does NOT exist on disk (pasted / mock diff)
                for (hIdx, hunk) in file.hunks.enumerated() {
                    let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                    let linesText = newFileLines.joined(separator: "\n")

                    let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                    let baselineText = oldBaselineLines.joined(separator: "\n")

                    let startLine = hunk.newRange.lowerBound

                    let buffer = Buffer(
                        filePath: file.displayPath,
                        text: linesText,
                        language: Buffer.detectLanguage(for: file.displayPath),
                        baselineText: baselineText,
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
        for i in 0..<multiBuffer.excerpts.count {
            multiBuffer.toggleCollapse(at: i)
        }
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
