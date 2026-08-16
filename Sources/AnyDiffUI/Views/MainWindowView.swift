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

    @State private var fileDiffs: [FileDiff] = []
    @State private var selectedFilePath: String? = nil
    @State private var selectedTheme: Theme = .unifiedDark
    @State private var followsSystemAppearance: Bool = true
    @State private var viewMode: DiffViewMode = .unified
    @State private var contextLines: Int = 3
    @State private var fontSize: CGFloat = 13

    @State private var cursorLocation: ExcerptLocation? = nil
    @State private var cursorPoint: MultiBufferPoint = .zero

    @State private var showPasteModal: Bool = false
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
        NavigationSplitView {
            SidebarFileListView(
                fileDiffs: fileDiffs,
                theme: activeTheme,
                reviewManager: reviewManager,
                selectedFilePath: $selectedFilePath
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 800)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 12) {
                        Button(action: { openGitRepositoryFolder() }) {
                            Image(systemName: "folder")
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                        }
                        .buttonStyle(.plain)
                        .help("Open Git Repository (Cmd+O)")

                        Button(action: { loadCurrentDirectoryDiff() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                        }
                        .buttonStyle(.plain)
                        .help("Reload Git Diff (Cmd+R)")

                        Button(action: { showThemePicker.toggle() }) {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 13.0, weight: .regular))
                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                .opacity(0.85)
                        }
                        .buttonStyle(.plain)
                        .help("Select Color Theme (\(activeThemeName))")
                        .popover(isPresented: $showThemePicker, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("COLOR THEME")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 6)
                                Divider()
                                Button(action: {
                                    followsSystemAppearance = true
                                    showThemePicker = false
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
                                        showThemePicker = false
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
                }
            }
        } detail: {
            EditorHostView(
                displayMap: displayMap,
                theme: activeTheme,
                fontSize: fontSize,
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
            .background(
                // Global keyboard shortcuts (Cmd+R reload, Cmd+O open folder, Cmd+-/Cmd+= zoom)
                Group {
                    Button(action: { loadCurrentDirectoryDiff() }) {}
                        .keyboardShortcut("r", modifiers: .command)
                    Button(action: { openGitRepositoryFolder() }) {}
                        .keyboardShortcut("o", modifiers: .command)
                    Button(action: { fontSize = max(9, fontSize - 1) }) {}
                        .keyboardShortcut("-", modifiers: .command)
                    Button(action: { fontSize = min(28, fontSize + 1) }) {}
                        .keyboardShortcut("=", modifiers: .command)
                }
                .opacity(0)
            )
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(activeTheme.isDark ? .dark : .light, for: .windowToolbar)
        .background(Color(activeTheme.background).ignoresSafeArea())
        .sheet(isPresented: $showPasteModal) {
            PasteDiffModal(
                onLoadDiff: { text in
                    loadDiff(text: text)
                    showPasteModal = false
                },
                onCancel: {
                    showPasteModal = false
                }
            )
        }
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
        }
    }

    // MARK: - Current Directory Diff Loading

    public func loadCurrentDirectoryDiff() {
        let currentDir = initialPath ?? FileManager.default.currentDirectoryPath
        multiBuffer.baseDirectory = currentDir
        let folderName = (currentDir as NSString).lastPathComponent
        self.currentFolderName = folderName
        DispatchQueue.main.async {
            NSApp.windows.first?.title = "\(folderName)"
        }
        if let diff = fetchGitDiff(at: currentDir), !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadDiff(text: diff)
        } else {
            // Fallback to sample demo diff if working tree has no changes
            loadDiff(text: SampleDiffs.swiftMultiBufferDiff)
            _ = reviewManager.addComment(
                filePath: "Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift",
                lineNumber: 18,
                author: "Senior Reviewer",
                content: "Great job! Using MultiBufferUndoManager here aligns perfectly with Zed's transaction history."
            )
            displayMap.rebuild()
        }
    }

    private func fetchGitDiff(at path: String) -> String? {
        // 1. Try uncommitted (staged + unstaged) changes: git diff HEAD
        if let out = runGit(arguments: ["-C", path, "diff", "HEAD"]), !out.isEmpty {
            return out
        }
        // 2. Try unstaged changes: git diff
        if let out = runGit(arguments: ["-C", path, "diff"]), !out.isEmpty {
            return out
        }
        // 3. Try staged changes: git diff --staged
        if let out = runGit(arguments: ["-C", path, "diff", "--staged"]), !out.isEmpty {
            return out
        }
        // 4. Try latest commit diff: git show -p HEAD
        if let out = runGit(arguments: ["-C", path, "show", "-p", "HEAD"]), !out.isEmpty {
            return out
        }
        return nil
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
            let fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
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
            let folderName = (path as NSString).lastPathComponent
            self.currentFolderName = folderName
            DispatchQueue.main.async {
                NSApp.windows.first?.title = "\(folderName)"
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "diff", "HEAD"]

            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    loadDiff(text: output)
                } else {
                    // Try fallback to unstaged diff
                    let process2 = Process()
                    process2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process2.arguments = ["-C", path, "diff"]
                    let pipe2 = Pipe()
                    let errPipe2 = Pipe()
                    process2.standardOutput = pipe2
                    process2.standardError = errPipe2
                    try process2.run()
                    let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
                    process2.waitUntilExit()
                    if let output2 = String(data: data2, encoding: .utf8), !output2.isEmpty {
                        loadDiff(text: output2)
                    }
                }
            } catch {}
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
