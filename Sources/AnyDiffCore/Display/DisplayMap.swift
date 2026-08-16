import Foundation
import Combine

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

    @Published public private(set) var displayLines: [DisplayLine] = []

    public init(multiBuffer: MultiBuffer, reviewManager: ReviewManager) {
        self.multiBuffer = multiBuffer
        self.reviewManager = reviewManager
        rebuild()
    }

    /// Rebuilds the visual DisplayLine array from current MultiBuffer state
    public func rebuild() {
        var lines: [DisplayLine] = []
        var runningMBRow = 0

        for (excerptIdx, excerpt) in multiBuffer.excerpts.enumerated() {
            guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else {
                continue
            }

            let isFirstExcerptOfFile = excerpt.isFileStart || excerptIdx == 0

            // 1. Excerpt Header
            if isFirstExcerptOfFile {
                let fileExcerpts = multiBuffer.excerpts.filter { $0.filePath == excerpt.filePath }
                let adds = buffer.totalAdditions > 0 ? buffer.totalAdditions : fileExcerpts.reduce(0) { $0 + ($1.hunk?.addedLineCount ?? 0) }
                let dels = buffer.totalDeletions > 0 ? buffer.totalDeletions : fileExcerpts.reduce(0) { $0 + ($1.hunk?.deletedLineCount ?? 0) }

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
                continue
            }

            // 2. Top Fold Gap (if first excerpt starts > 1)
            if isFirstExcerptOfFile {
                let topHidden = buffer.fullDiskPath != nil ? (buffer.startLineNumber - 1) : excerpt.bufferRange.lowerBound
                if topHidden >= 3 {
                    lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: topHidden, isTopGap: true)))
                }
            }

            // 3. Dynamic Diff Calculation: compute live diff lines without dropping expanded context
            var diffLinesToRender: [DiffLine] = []
            if !buffer.baselineLines.isEmpty && (excerpt.hunk != nil || buffer.fullDiskPath != nil || buffer.lineCount == excerpt.lineCount) {
                if let cached = buffer.cachedDiffLines, buffer.cachedDiffVersion == buffer.version {
                    diffLinesToRender = cached
                } else {
                    let computed = LineDiffEngine.shared.diffLines(
                        oldLines: buffer.baselineLines,
                        newLines: buffer.lines,
                        oldStartLine: buffer.startLineNumber,
                        newStartLine: buffer.startLineNumber
                    )
                    buffer.cachedDiffLines = computed
                    buffer.cachedDiffVersion = buffer.version
                    diffLinesToRender = computed
                }
                multiBuffer.updateExcerptBufferRange(at: excerptIdx, range: 0..<diffLinesToRender.count)
            } else {
                let clampedLower = max(0, min(buffer.lineCount, excerpt.bufferRange.lowerBound))
                let clampedUpper = max(clampedLower, min(buffer.lineCount, excerpt.bufferRange.upperBound))
                for bRow in clampedLower..<clampedUpper {
                    let lineStr = buffer.line(at: bRow) ?? ""
                    let lineNum = buffer.startLineNumber + bRow
                    diffLinesToRender.append(DiffLine(kind: .unchanged, text: lineStr, oldLineNumber: lineNum, newLineNumber: lineNum))
                }
            }

            let totalDiffLines = diffLinesToRender.count
            let canExpandUp: Bool
            let canExpandDown: Bool
            if buffer.fullDiskPath != nil {
                canExpandUp = (buffer.startLineNumber > 1)
                if let fullCount = buffer.diskFileLineCount {
                    canExpandDown = (buffer.startLineNumber + buffer.lineCount - 1 < fullCount)
                } else {
                    canExpandDown = (excerpt.bufferRange.upperBound < buffer.lineCount)
                }
            } else {
                canExpandUp = (excerpt.bufferRange.lowerBound > 0)
                canExpandDown = (excerpt.bufferRange.upperBound < buffer.lineCount)
            }

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

                var expandInfo: ExpandInfo? = nil
                if totalDiffLines == 1 {
                    if canExpandUp && canExpandDown {
                        expandInfo = ExpandInfo(direction: .upAndDown, excerptIndex: excerptIdx)
                    } else if canExpandUp {
                        expandInfo = ExpandInfo(direction: .up, excerptIndex: excerptIdx)
                    } else if canExpandDown {
                        expandInfo = ExpandInfo(direction: .down, excerptIndex: excerptIdx)
                    }
                } else if idx == 0 && canExpandUp {
                    expandInfo = ExpandInfo(direction: .up, excerptIndex: excerptIdx)
                } else if idx == totalDiffLines - 1 && canExpandDown {
                    expandInfo = ExpandInfo(direction: .down, excerptIndex: excerptIdx)
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
                    wordDiffRanges: dLine.wordDiffRanges,
                    expandInfo: expandInfo
                )
                lines.append(.code(codeInfo))

                // Check for inline review comments on this line
                let lineForComment = dLine.newLineNumber ?? dLine.oldLineNumber ?? (bRow + 1)
                let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                for comment in matchedComments {
                    lines.append(.inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment)))
                }
            }

            runningMBRow += diffLinesToRender.count

            // 4. Fold Gap between excerpts or at bottom of file
            let isLastExcerptOfFile: Bool
            if excerptIdx == multiBuffer.excerpts.count - 1 {
                isLastExcerptOfFile = true
            } else {
                isLastExcerptOfFile = (multiBuffer.excerpts[excerptIdx + 1].filePath != excerpt.filePath)
            }

            if !isLastExcerptOfFile {
                let nextExcerpt = multiBuffer.excerpts[excerptIdx + 1]
                let nextBuf = multiBuffer.buffer(for: nextExcerpt.bufferId)
                let nextStartLine = nextBuf?.startLineNumber ?? (nextExcerpt.bufferRange.lowerBound + 1)
                let currentEndLine = buffer.startLineNumber + buffer.lineCount - 1
                let hiddenBetween = max(0, nextStartLine - currentEndLine - 1)
                if hiddenBetween >= 3 {
                    lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, nextExcerptIndex: excerptIdx + 1, hiddenCount: hiddenBetween, isTopGap: false, isBottomGap: false)))
                }
            } else if isLastExcerptOfFile {
                if let diskCount = buffer.diskFileLineCount {
                    let currentEndLine = buffer.startLineNumber + buffer.lineCount - 1
                    let remaining = max(0, diskCount - currentEndLine)
                    if remaining >= 3 {
                        lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: remaining, isTopGap: false, isBottomGap: true)))
                    }
                }
            }
        }

        self.displayLines = lines
    }

    // MARK: - Lookups and Mapping Helpers

    public var codeLines: [DisplayCodeLineInfo] {
        displayLines.compactMap {
            if case .code(let info) = self.wrappedLine($0) { return info }
            return nil
        }
    }

    private func wrappedLine(_ line: DisplayLine) -> DisplayLine {
        line
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
        var foundCurrent = false
        for line in displayLines {
            if case .code(let info) = line {
                if foundCurrent {
                    return info.multiBufferRow
                }
                if info.multiBufferRow == row {
                    foundCurrent = true
                }
            }
        }
        return nil
    }

    public func previousCodeRow(before row: MultiBufferRow) -> MultiBufferRow? {
        var prevRow: MultiBufferRow? = nil
        for line in displayLines {
            if case .code(let info) = line {
                if info.multiBufferRow == row {
                    return prevRow
                }
                prevRow = info.multiBufferRow
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

    public func isDeleted(multiBufferRow: MultiBufferRow) -> Bool {
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

    public func line(at index: Int) -> DisplayLine? {
        guard index >= 0 && index < displayLines.count else { return nil }
        return displayLines[index]
    }
}