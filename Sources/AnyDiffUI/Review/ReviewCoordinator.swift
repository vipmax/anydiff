import Foundation
import SwiftUI
import Combine
import AnyDiffCore

@MainActor
public final class ReviewCoordinator: ObservableObject {
    // MARK: - Published State

    @Published public var fileDiffs: [FileDiff] = []
    @Published public var viewStateResetToken: UInt64 = 0
    @Published public var preparedReviewSummary: AgentEditedFilesSummary? = nil
    @Published public var selectedFilePathBeforeReadOnly: String? = nil

    // MARK: - Owned Storage

    public let multiBuffer: MultiBuffer
    public let displayMap: DisplayMap
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    public init(reviewManager: ReviewManager = ReviewManager()) {
        let mb = MultiBuffer()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: reviewManager)
        dm.layoutMode = .unified
        self.multiBuffer = mb
        self.displayMap = dm

        mb.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dm.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Status

    public var isActive: Bool {
        preparedReviewSummary != nil || !fileDiffs.isEmpty
    }

    public func clear() {
        fileDiffs = []
        multiBuffer.clear()
        displayMap.clear()
    }

    // MARK: - Review Loading

    public func loadReviewDiff(
        for summary: AgentEditedFilesSummary,
        workingDirectory: String,
        baseDirectory: String
    ) {
        let isGit = GitService.shared.isRepository(at: workingDirectory)

        if summary.contentMode == .text {
            loadPlainText(
                data: summary.rawTextData ?? Data(),
                filePath: summary.files.first?.path ?? "agent/output.txt"
            )
            return
        }

        // 1. Direct raw diff data attached to the summary
        if let rawData = summary.rawDiffData, !rawData.isEmpty {
            let parsed = GitDiffParser.shared.parseZeroCopy(data: rawData)
            if !parsed.isEmpty {
                loadDiff(files: parsed, rawData: rawData, baseDirectory: baseDirectory)
                return
            }
        }

        // 2. Fetch turn snapshot diff using the base commit hash
        if isGit, let baseHash = summary.baseCommitHash, !baseHash.isEmpty {
            if let diffData = AgentGitChangesDetector.fetchTurnDiffData(
                workingDirectory: workingDirectory,
                baseCommit: baseHash,
                pathFilter: Set(summary.filePaths)
            ), !diffData.isEmpty {
                let parsed = GitDiffParser.shared.parseZeroCopy(data: diffData)
                if !parsed.isEmpty {
                    loadDiff(files: parsed, rawData: diffData, baseDirectory: baseDirectory)
                    return
                }
            }
        }

        // 3. Fallback to working tree path filter
        let pathFilter = Set(summary.filePaths)
        let (files, rawData) = isGit
            ? GitService.shared.diffFiles(at: workingDirectory, target: .workingTree, pathFilter: pathFilter)
            : (files: [], data: nil)

        if !files.isEmpty {
            loadDiff(files: files, rawData: rawData, baseDirectory: baseDirectory)
        } else {
            var synthText = ""
            for file in summary.files {
                synthText += """
                diff --git a/\(file.path) b/\(file.path)
                --- a/\(file.path)
                +++ b/\(file.path)
                @@ -1,\(max(1, file.deletions)) +1,\(max(1, file.additions)) @@
                -    // Original implementation
                +    // Modified by Agent
                +    // Changes: +\(file.additions) -\(file.deletions)

                """
            }
            let data = Data(synthText.utf8)
            let parsed = GitDiffParser.shared.parseZeroCopy(data: data)
            loadDiff(files: parsed, rawData: data, baseDirectory: baseDirectory)
        }
    }

    public func loadDiff(files parsedFiles: [FileDiff], rawData: Data? = nil, baseDirectory: String) {
        let collapsedFilePaths = Set(multiBuffer.excerpts.filter { $0.isCollapsed }.map { $0.filePath })
        self.fileDiffs = parsedFiles

        multiBuffer.clear()
        multiBuffer.setContentMode(.diff)
        displayMap.clear()
        SyntaxHighlighter.shared.clearCache()

        MultiBufferBuilder.append(
            files: parsedFiles,
            rawData: rawData,
            baseDirectory: baseDirectory,
            collapsedPaths: collapsedFilePaths,
            into: multiBuffer
        )

        displayMap.rebuild()
        displayMap.markContentLoaded()
    }

    public func loadPlainText(data: Data, filePath: String) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let displayPath = filePath.isEmpty ? "agent/output.txt" : filePath

        self.fileDiffs = [FileDiff(oldPath: displayPath, newPath: displayPath)]

        multiBuffer.clear()
        multiBuffer.setContentMode(.text)
        displayMap.clear()
        SyntaxHighlighter.shared.clearCache()

        let buffer = Buffer(
            filePath: displayPath,
            lines: lines,
            language: Buffer.detectLanguage(for: displayPath),
            baselineLines: [],
            totalAdditions: 0,
            totalDeletions: 0,
            startLineNumber: 1,
            fullDiskPath: nil,
            diskFileLineCount: lines.count
        )
        buffer.isFullFile = true
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: displayPath,
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: nil,
            isCollapsed: false,
            isFileStart: true
        ))

        displayMap.rebuild()
        displayMap.markContentLoaded()
    }

    public func closeFile(filePath: String) {
        fileDiffs.removeAll { $0.displayPath == filePath }
        multiBuffer.removeFile(filePath: filePath)
        displayMap.rebuild()
        displayMap.markContentLoaded()
    }
}
