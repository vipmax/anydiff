import Foundation

public enum DiffViewMode: String, CaseIterable, Sendable {
    case unified = "Unified Multibuffer"
    case hunksOnly = "Hunks Only"
    case fullFile = "Full File Context"
}

/// Transforms logical MultiBuffer rows into visual DisplayLines
public final class DisplayMap: ObservableObject, @unchecked Sendable {
    public let multiBuffer: MultiBuffer
    public let reviewManager: ReviewManager
    public var viewMode: DiffViewMode = .unified
    public var contextLines: Int = 3

    @Published public private(set) var displayLines: [DisplayLine] = []

    public init(multiBuffer: MultiBuffer, reviewManager: ReviewManager) {
        self.multiBuffer = multiBuffer
        self.reviewManager = reviewManager
        rebuild()
    }

    public func rebuild() {
        var lines: [DisplayLine] = []
        var runningMBRow = 0

        for (excerptIdx, excerpt) in multiBuffer.excerpts.enumerated() {
            guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else {
                runningMBRow += excerpt.lineCount
                continue
            }

            // 1. Excerpt Header
            if excerpt.isFileStart || excerptIdx == 0 {
                let fileExcerpts = multiBuffer.excerpts.filter { $0.filePath == excerpt.filePath }
                let adds = fileExcerpts.reduce(0) { $0 + ($1.hunk?.addedLineCount ?? 0) }
                let dels = fileExcerpts.reduce(0) { $0 + ($1.hunk?.deletedLineCount ?? 0) }
                let header = ExcerptHeaderInfo(
                    excerptIndex: excerptIdx,
                    filePath: excerpt.filePath,
                    fileStatus: excerpt.fileStatus,
                    additions: adds,
                    deletions: dels,
                    isCollapsed: excerpt.isCollapsed
                )
                lines.append(.excerptHeader(header))
            }

            if excerpt.isCollapsed {
                runningMBRow += excerpt.lineCount
                continue
            }

            // 2. Top Fold Gap (if excerpt starts > 0 in buffer)
            if excerpt.bufferRange.lowerBound > 0 {
                let hidden = excerpt.bufferRange.lowerBound
                lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: hidden, isTopGap: true)))
            }

            // 3. Code Lines
            let hunk = excerpt.hunk
            for bufferRow in excerpt.bufferRange {
                let mbRow = runningMBRow + (bufferRow - excerpt.bufferRange.lowerBound)
                let text = buffer.line(at: bufferRow) ?? ""

                // Determine diff kind and line numbers
                var kind: DiffLineKind = .unchanged
                var oldNum: Int? = nil
                var newNum: Int? = bufferRow + 1
                var wordDiffs: [Range<Int>] = []

                if let hunk = hunk {
                    let offsetInHunk = bufferRow - excerpt.bufferRange.lowerBound
                    if offsetInHunk < hunk.lines.count {
                        let dLine = hunk.lines[offsetInHunk]
                        kind = dLine.kind
                        oldNum = dLine.oldLineNumber
                        newNum = dLine.newLineNumber
                        wordDiffs = dLine.wordDiffRanges
                    }
                }

                let codeInfo = DisplayCodeLineInfo(
                    excerptIndex: excerptIdx,
                    multiBufferRow: mbRow,
                    bufferRow: bufferRow,
                    oldLineNumber: oldNum,
                    newLineNumber: newNum,
                    diffKind: kind,
                    text: text,
                    language: buffer.language,
                    wordDiffRanges: wordDiffs
                )
                lines.append(.code(codeInfo))

                // Check for inline review comments on this line
                let lineForComment = newNum ?? oldNum ?? (bufferRow + 1)
                let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                for comment in matchedComments {
                    lines.append(.inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment)))
                }
            }

            // 4. Bottom Fold Gap
            let remaining = buffer.lineCount - excerpt.bufferRange.upperBound
            if remaining > 0 {
                lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: remaining, isTopGap: false)))
            }

            runningMBRow += excerpt.lineCount
        }

        self.displayLines = lines
    }

    public var count: Int {
        displayLines.count
    }

    public func line(at index: Int) -> DisplayLine? {
        guard index >= 0 && index < displayLines.count else { return nil }
        return displayLines[index]
    }
}
