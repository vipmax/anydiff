import SwiftUI
import AnyDiffCore

public struct MainWindowView: View {
    public var initialPath: String?

    @StateObject private var multiBuffer = MultiBuffer()
    @StateObject private var reviewManager = ReviewManager()
    @StateObject private var displayMap: DisplayMap

    @State private var fileDiffs: [FileDiff] = []
    @State private var selectedFilePath: String? = nil
    @State private var selectedTheme: Theme = .zedGray
    @State private var viewMode: DiffViewMode = .unified
    @State private var contextLines: Int = 3
    @State private var fontSize: CGFloat = 13

    @State private var cursorLocation: ExcerptLocation? = nil
    @State private var cursorPoint: MultiBufferPoint = .zero

    @State private var showPasteModal: Bool = false
    @State private var commentTarget: (filePath: String, lineNumber: Int)? = nil

    public init(initialPath: String? = nil) {
        self.initialPath = initialPath
        let mb = MultiBuffer()
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        self._multiBuffer = StateObject(wrappedValue: mb)
        self._reviewManager = StateObject(wrappedValue: rm)
        self._displayMap = StateObject(wrappedValue: dm)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarFileListView(
                fileDiffs: fileDiffs,
                reviewManager: reviewManager,
                selectedFilePath: $selectedFilePath
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 800)
        } detail: {
            VStack(spacing: 0) {
                // Custom CoreText MultiBuffer Editor Canvas
                EditorHostView(
                    displayMap: displayMap,
                    theme: selectedTheme,
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

                Divider()

                // Bottom Status Bar
                StatusBarView(
                    currentCursorLocation: cursorLocation,
                    currentCursorPoint: cursorPoint,
                    totalFiles: fileDiffs.count,
                    totalAdditions: fileDiffs.reduce(0) { $0 + $1.additions },
                    totalDeletions: fileDiffs.reduce(0) { $0 + $1.deletions },
                    totalComments: reviewManager.comments.count,
                    theme: selectedTheme
                )
                .zIndex(10)
            }
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
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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

        for file in parsedFiles {
            for (hIdx, hunk) in file.hunks.enumerated() {
                // Build excerpt text from hunk lines
                let linesText = hunk.lines.map(\.text).joined(separator: "\n")
                let buffer = Buffer(
                    filePath: file.displayPath,
                    text: linesText,
                    language: Buffer.detectLanguage(for: file.displayPath)
                )
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "diff", "HEAD"]

            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                loadDiff(text: output)
            } else {
                // Try fallback to unstaged diff
                let process2 = Process()
                process2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process2.arguments = ["-C", path, "diff"]
                let pipe2 = Pipe()
                process2.standardOutput = pipe2
                try? process2.run()
                process2.waitUntilExit()
                let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
                if let output2 = String(data: data2, encoding: .utf8), !output2.isEmpty {
                    loadDiff(text: output2)
                }
            }
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
