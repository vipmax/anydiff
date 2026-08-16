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

            // 3. Dynamic Diff Calculation: compute live hunks using LineDiffEngine
            let liveHunks: [DiffHunk]
            if !buffer.baselineText.isEmpty {
                liveHunks = LineDiffEngine.shared.diff(oldText: buffer.baselineText, newText: buffer.text())
            } else if let h = excerpt.hunk {
                liveHunks = [h]
            } else {
                liveHunks = []
            }

            var diffLinesToRender: [DiffLine] = []
            if !liveHunks.isEmpty {
                for hunk in liveHunks {
                    diffLinesToRender.append(contentsOf: hunk.lines)
                }
            } else {
                for bRow in 0..<buffer.lineCount {
                    let lineStr = buffer.line(at: bRow) ?? ""
                    diffLinesToRender.append(DiffLine(kind: .unchanged, text: lineStr, oldLineNumber: bRow + 1, newLineNumber: bRow + 1))
                }
            }

            // Sync excerpt buffer range with current diff lines
            multiBuffer.updateExcerptBufferRange(at: excerptIdx, range: 0..<diffLinesToRender.count)

            var currentBufferRow = 0
            for (idx, dLine) in diffLinesToRender.enumerated() {
                let mbRow = runningMBRow + idx
                let bRow: Int
                if dLine.kind == .deleted {
                    bRow = max(0, currentBufferRow)
                } else {
                    bRow = currentBufferRow
                    currentBufferRow += 1
                }

                let codeInfo = DisplayCodeLineInfo(
                    excerptIndex: excerptIdx,
                    multiBufferRow: mbRow,
                    bufferRow: bRow,
                    oldLineNumber: dLine.oldLineNumber,
                    newLineNumber: dLine.newLineNumber,
                    diffKind: dLine.kind,
                    text: dLine.text,
                    language: buffer.language,
                    wordDiffRanges: dLine.wordDiffRanges
                )
                lines.append(.code(codeInfo))

                // Check for inline review comments on this line
                let lineForComment = dLine.newLineNumber ?? dLine.oldLineNumber ?? (idx + 1)
                let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                for comment in matchedComments {
                    lines.append(.inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment)))
                }
            }

            // 4. Bottom Fold Gap
            let remaining = max(0, buffer.lineCount - diffLinesToRender.count)
            if remaining > 0 {
                lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: remaining, isTopGap: false)))
            }

            runningMBRow += diffLinesToRender.count
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

    public var codeLines: [DisplayCodeLineInfo] {
        displayLines.compactMap {
            if case .code(let info) = $0 { return info }
            return nil
        }
    }

    public var codeLineCount: Int {
        codeLines.count
    }

    public var minCodeRow: Int {
        codeLines.first?.multiBufferRow ?? 0
    }

    public var maxCodeRow: Int {
        codeLines.last?.multiBufferRow ?? 0
    }

    public func codeInfo(for multiBufferRow: MultiBufferRow) -> DisplayCodeLineInfo? {
        for line in displayLines {
            if case .code(let info) = line, info.multiBufferRow == multiBufferRow {
                return info
            }
        }
        return nil
    }

    public func lineText(at multiBufferRow: MultiBufferRow) -> String? {
        codeInfo(for: multiBufferRow)?.text
    }

    public func lineLength(at multiBufferRow: MultiBufferRow) -> Int {
        lineText(at: multiBufferRow)?.count ?? 0
    }

    public func nextCodeRow(after row: MultiBufferRow) -> MultiBufferRow? {
        for line in displayLines {
            if case .code(let info) = line, info.multiBufferRow > row {
                return info.multiBufferRow
            }
        }
        return nil
    }

    public func previousCodeRow(before row: MultiBufferRow) -> MultiBufferRow? {
        for line in displayLines.reversed() {
            if case .code(let info) = line, info.multiBufferRow < row {
                return info.multiBufferRow
            }
        }
        return nil
    }

    public func excerptLocation(for point: MultiBufferPoint) -> ExcerptLocation? {
        for line in displayLines {
            if case .code(let info) = line, info.multiBufferRow == point.row {
                guard info.excerptIndex >= 0 && info.excerptIndex < multiBuffer.excerpts.count else { return nil }
                let excerpt = multiBuffer.excerpts[info.excerptIndex]
                return ExcerptLocation(
                    excerptIndex: info.excerptIndex,
                    bufferId: excerpt.bufferId,
                    filePath: excerpt.filePath,
                    bufferRow: info.bufferRow,
                    bufferColumn: point.column
                )
            }
        }
        return nil
    }

    public func isDeleted(multiBufferRow: Int) -> Bool {
        for line in displayLines {
            if case .code(let info) = line, info.multiBufferRow == multiBufferRow {
                return info.diffKind == .deleted
            }
        }
        return false
    }

    public func isDeleted(rowRange: Range<Int>) -> Bool {
        for line in displayLines {
            if case .code(let info) = line, rowRange.contains(info.multiBufferRow), info.diffKind == .deleted {
                return true
            }
        }
        return false
    }

    /// Translates visual MultiBufferPoint to exact (Buffer, BufferPoint)
    public func bufferLocation(for point: MultiBufferPoint) -> (buffer: Buffer, point: BufferPoint, isDeleted: Bool, excerptIndex: Int)? {
        for line in displayLines {
            if case .code(let info) = line, info.multiBufferRow == point.row {
                guard info.excerptIndex >= 0 && info.excerptIndex < multiBuffer.excerpts.count else { return nil }
                let excerpt = multiBuffer.excerpts[info.excerptIndex]
                guard let buf = multiBuffer.buffer(for: excerpt.bufferId) else { return nil }
                let bPt = BufferPoint(row: info.bufferRow, column: point.column)
                return (buf, bPt, info.diffKind == .deleted, info.excerptIndex)
            }
        }
        return nil
    }

    /// Translates (BufferId, BufferPoint) to visual MultiBufferPoint
    public func visualPoint(for bufferId: BufferId, bufferPoint: BufferPoint) -> MultiBufferPoint? {
        for line in displayLines {
            if case .code(let info) = line, info.diffKind != .deleted {
                guard info.excerptIndex >= 0 && info.excerptIndex < multiBuffer.excerpts.count else { continue }
                let excerpt = multiBuffer.excerpts[info.excerptIndex]
                if excerpt.bufferId == bufferId && info.bufferRow == bufferPoint.row {
                    return MultiBufferPoint(row: info.multiBufferRow, column: bufferPoint.column)
                }
            }
        }
        return nil
    }
}
