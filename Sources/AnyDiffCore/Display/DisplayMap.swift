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
    public private(set) var codeRowToDisplayLineIndex: [Int32] = []
    public var codeLines: [DisplayCodeLineInfo] {
        codeRowToDisplayLineIndex.compactMap { idx in
            let i = Int(idx)
            if i >= 0 && i < displayLines.count, case .code(let info) = displayLines[i] {
                return info
            }
            return nil
        }
    }
    public var codeLineCount: Int { codeRowToDisplayLineIndex.count }
    public var minCodeRow: Int { 0 }
    public var maxCodeRow: Int { codeRowToDisplayLineIndex.isEmpty ? 0 : codeRowToDisplayLineIndex.count - 1 }

    public struct ExcerptVisualRange: Sendable, Equatable {
        public let bufferId: BufferId
        public let startMBRow: Int
        public let endMBRow: Int
    }
    private var excerptVisualRanges: [ExcerptVisualRange] = []

    private struct ExcerptDiffCache {
        let bufferVersion: Int
        let bufferRange: Range<Int>
        let result: (lines: [(line: DiffLine, bufferRow: Int)], additions: Int, deletions: Int)
    }
    private var excerptDiffCache: [UUID: ExcerptDiffCache] = [:]

    public init(multiBuffer: MultiBuffer, reviewManager: ReviewManager) {
        self.multiBuffer = multiBuffer
        self.reviewManager = reviewManager
        rebuild()
    }

    public func clear() {
        displayLines.removeAll(keepingCapacity: false)
        codeRowToDisplayLineIndex.removeAll(keepingCapacity: false)
        excerptVisualRanges.removeAll(keepingCapacity: false)
        excerptDiffCache.removeAll(keepingCapacity: false)
    }

    /// Rebuilds the visual DisplayLine array from current MultiBuffer state
    public func rebuild() {
        var lines: [DisplayLine] = []
        var runningMBRow = 0
        var rowIndices: [Int32] = []
        var visualRanges: [ExcerptVisualRange] = []
        visualRanges.reserveCapacity(multiBuffer.excerpts.count)

        for (excerptIdx, excerpt) in multiBuffer.excerpts.enumerated() {
            guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else {
                continue
            }

            let isFirstExcerptOfFile = excerpt.isFileStart || excerptIdx == 0

            // 1. Excerpt Header (with live additions & deletions)
            if isFirstExcerptOfFile {
                let header = ExcerptHeaderInfo(
                    excerptIndex: excerptIdx,
                    filePath: excerpt.filePath,
                    fileStatus: excerpt.fileStatus,
                    additions: buffer.totalAdditions,
                    deletions: buffer.totalDeletions,
                    isCollapsed: excerpt.isCollapsed
                )
                lines.append(.excerptHeader(header))
            }

            if excerpt.isCollapsed {
                continue
            }

            // 2. Diff Calculation for visible excerpt
            let diffLinesToRender: [(line: DiffLine, bufferRow: Int)]
            if let hunk = excerpt.hunk, buffer.version == 0, excerpt.bufferRange == 0..<buffer.lineCount {
                var currentBufferRow = 0
                diffLinesToRender = hunk.lines.map { dLine in
                    let bRow = currentBufferRow
                    if dLine.kind != .deleted {
                        currentBufferRow += 1
                    }
                    return (line: dLine, bufferRow: bRow)
                }
            } else if !buffer.baselineLines.isEmpty && (buffer.baselineLines != buffer.lines || excerpt.hunk != nil || buffer.fullDiskPath != nil) {
                if let cached = excerptDiffCache[excerpt.id],
                   cached.bufferVersion == buffer.version,
                   cached.bufferRange == excerpt.bufferRange {
                    diffLinesToRender = cached.result.lines
                    if buffer.isFullFile {
                        buffer.totalAdditions = cached.result.additions
                        buffer.totalDeletions = cached.result.deletions
                    }
                } else {
                    let sliceResult = LineDiffEngine.shared.diffLinesForSlice(
                        oldLines: buffer.baselineLines,
                        newLines: buffer.lines,
                        oldStartLine: buffer.startLineNumber,
                        newStartLine: buffer.startLineNumber,
                        targetRange: excerpt.bufferRange
                    )
                    diffLinesToRender = sliceResult.lines
                    if buffer.isFullFile {
                        buffer.totalAdditions = sliceResult.additions
                        buffer.totalDeletions = sliceResult.deletions
                    }
                    excerptDiffCache[excerpt.id] = ExcerptDiffCache(
                        bufferVersion: buffer.version,
                        bufferRange: excerpt.bufferRange,
                        result: sliceResult
                    )
                }
            } else {
                let range = excerpt.bufferRange
                let clamped = max(0, min(buffer.lineCount, range.lowerBound))..<max(0, min(buffer.lineCount, range.upperBound))
                diffLinesToRender = clamped.map { r in
                    let num = buffer.startLineNumber + r
                    let dLine = DiffLine(kind: .unchanged, text: buffer.lines[r], oldLineNumber: num, newLineNumber: num)
                    return (line: dLine, bufferRow: r)
                }
                if buffer.isFullFile {
                    buffer.totalAdditions = 0
                    buffer.totalDeletions = 0
                }
            }

            // 3. Top Fold Gap (if first excerpt starts > 1)
            if isFirstExcerptOfFile && excerpt.fileStatus != .deleted {
                let topHidden = buffer.startLineNumber > 1 ? (buffer.startLineNumber - 1 + excerpt.bufferRange.lowerBound) : excerpt.bufferRange.lowerBound
                if topHidden >= 3 {
                    lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: topHidden, isTopGap: true)))
                }
            }

            let totalDiffLines = diffLinesToRender.count
            let canExpandUp: Bool
            if excerpt.fileStatus == .deleted {
                canExpandUp = false
            } else if buffer.startLineNumber > 1 || excerpt.bufferRange.lowerBound > 0 {
                canExpandUp = true
            } else if excerptIdx > 0 && multiBuffer.excerpts[excerptIdx - 1].filePath == excerpt.filePath {
                canExpandUp = true
            } else {
                canExpandUp = false
            }

            let canExpandDown: Bool
            if excerpt.fileStatus == .deleted {
                canExpandDown = false
            } else if let diskCount = buffer.diskFileLineCount {
                let currentEndLine = buffer.startLineNumber - 1 + excerpt.bufferRange.upperBound
                canExpandDown = (currentEndLine < diskCount)
            } else if excerpt.bufferRange.upperBound < buffer.lineCount {
                canExpandDown = true
            } else if excerptIdx < multiBuffer.excerpts.count - 1 && multiBuffer.excerpts[excerptIdx + 1].filePath == excerpt.filePath {
                canExpandDown = true
            } else {
                canExpandDown = false
            }

            let excerptMBStart = runningMBRow

            for (idx, item) in diffLinesToRender.enumerated() {
                let mbRow = runningMBRow + idx
                let dLine = item.line
                let bRow = item.bufferRow
                let displayLineIdx = lines.count

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
                    displayLineIndex: displayLineIdx,
                    oldLineNumber: dLine.oldLineNumber,
                    newLineNumber: dLine.newLineNumber,
                    diffKind: dLine.kind,
                    text: dLine.text,
                    language: buffer.language,
                    wordDiffRanges: dLine.wordDiffRanges,
                    expandInfo: expandInfo
                )
                lines.append(.code(codeInfo))
                rowIndices.append(Int32(displayLineIdx))

                // Check for inline review comments on this line
                let lineForComment = dLine.newLineNumber ?? dLine.oldLineNumber ?? (bRow + 1)
                let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                for comment in matchedComments {
                    lines.append(.inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment)))
                }
            }

            let excerptMBEnd = runningMBRow + diffLinesToRender.count
            if excerptMBEnd > excerptMBStart {
                visualRanges.append(ExcerptVisualRange(
                    bufferId: excerpt.bufferId,
                    startMBRow: excerptMBStart,
                    endMBRow: excerptMBEnd
                ))
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
                let hiddenBetween: Int
                if nextExcerpt.bufferId == excerpt.bufferId {
                    hiddenBetween = max(0, nextExcerpt.bufferRange.lowerBound - excerpt.bufferRange.upperBound)
                } else {
                    let nextStart = (nextBuf?.startLineNumber ?? 1) + nextExcerpt.bufferRange.lowerBound
                    let currentEnd = buffer.startLineNumber + excerpt.bufferRange.upperBound
                    hiddenBetween = max(0, nextStart - currentEnd)
                }
                if hiddenBetween >= 3 {
                    lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, nextExcerptIndex: excerptIdx + 1, hiddenCount: hiddenBetween, isTopGap: false, isBottomGap: false)))
                }
            } else if isLastExcerptOfFile && excerpt.fileStatus != .deleted {
                let totalLines = buffer.diskFileLineCount ?? (buffer.startLineNumber - 1 + buffer.lineCount)
                let currentEnd = (buffer.startLineNumber - 1) + excerpt.bufferRange.upperBound
                let remaining = max(0, totalLines - currentEnd)
                if remaining >= 3 {
                    lines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: remaining, isTopGap: false, isBottomGap: true)))
                }
            }
        }

        self.codeRowToDisplayLineIndex = rowIndices
        self.excerptVisualRanges = visualRanges
        self.displayLines = lines
    }

    // MARK: - Lookups and Mapping Helpers

    public func codeInfo(for multiBufferRow: MultiBufferRow) -> DisplayCodeLineInfo? {
        guard multiBufferRow >= 0 && multiBufferRow < codeRowToDisplayLineIndex.count else { return nil }
        let lineIdx = Int(codeRowToDisplayLineIndex[multiBufferRow])
        guard lineIdx >= 0 && lineIdx < displayLines.count else { return nil }
        if case .code(let info) = displayLines[lineIdx] {
            return info
        }
        return nil
    }

    public var firstCodeInfo: DisplayCodeLineInfo? {
        guard !codeRowToDisplayLineIndex.isEmpty else { return nil }
        return codeInfo(for: 0)
    }

    public var lastCodeInfo: DisplayCodeLineInfo? {
        guard !codeRowToDisplayLineIndex.isEmpty else { return nil }
        return codeInfo(for: codeRowToDisplayLineIndex.count - 1)
    }

    public func lineText(at multiBufferRow: MultiBufferRow) -> String? {
        codeInfo(for: multiBufferRow)?.text
    }

    public func lineLength(at multiBufferRow: MultiBufferRow) -> Int {
        lineText(at: multiBufferRow)?.count ?? 0
    }

    public func nextCodeRow(after row: MultiBufferRow) -> MultiBufferRow? {
        let next = row + 1
        guard next >= 0 && next < codeRowToDisplayLineIndex.count else { return nil }
        return next
    }

    public func previousCodeRow(before row: MultiBufferRow) -> MultiBufferRow? {
        let prev = row - 1
        guard prev >= 0 && prev < codeRowToDisplayLineIndex.count else { return nil }
        return prev
    }

    public func excerptLocation(for point: MultiBufferPoint) -> ExcerptLocation? {
        guard let info = codeInfo(for: point.row) else { return nil }
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

    public func isDeleted(multiBufferRow: MultiBufferRow) -> Bool {
        codeInfo(for: multiBufferRow)?.diffKind == .deleted
    }

    public func isDeleted(rowRange: Range<Int>) -> Bool {
        let clamped = max(0, rowRange.lowerBound)..<min(codeLineCount, rowRange.upperBound)
        for r in clamped {
            if isDeleted(multiBufferRow: r) {
                return true
            }
        }
        return false
    }

    /// Translates visual MultiBufferPoint to exact (Buffer, BufferPoint)
    public func bufferLocation(for point: MultiBufferPoint) -> (buffer: Buffer, point: BufferPoint, isDeleted: Bool, excerptIndex: Int)? {
        guard let info = codeInfo(for: point.row) else { return nil }
        guard info.excerptIndex >= 0 && info.excerptIndex < multiBuffer.excerpts.count else { return nil }
        let excerpt = multiBuffer.excerpts[info.excerptIndex]
        guard let buf = multiBuffer.buffer(for: excerpt.bufferId) else { return nil }
        let bPt = BufferPoint(row: info.bufferRow, column: point.column)
        return (buf, bPt, info.diffKind == .deleted, info.excerptIndex)
    }

    /// Translates (BufferId, BufferPoint) to visual MultiBufferPoint (targeting non-deleted code line)
    public func visualPoint(for bufferId: BufferId, bufferPoint: BufferPoint) -> MultiBufferPoint? {
        for range in excerptVisualRanges where range.bufferId == bufferId {
            let start = range.startMBRow
            let end = range.endMBRow - 1
            guard start <= end, start >= 0, end < codeRowToDisplayLineIndex.count else { continue }

            var low = start
            var high = end
            while low <= high {
                let mid = (low + high) / 2
                guard let cInfo = codeInfo(for: mid) else { break }

                if cInfo.bufferRow < bufferPoint.row {
                    low = mid + 1
                } else if cInfo.bufferRow > bufferPoint.row {
                    high = mid - 1
                } else {
                    // Match found! Check if mid is non-deleted
                    if cInfo.diffKind != .deleted {
                        return MultiBufferPoint(row: cInfo.multiBufferRow, column: bufferPoint.column)
                    }
                    // If mid was deleted, check forward for the matching non-deleted line
                    var forward = mid + 1
                    while forward <= end, let fInfo = codeInfo(for: forward), fInfo.bufferRow == bufferPoint.row {
                        if fInfo.diffKind != .deleted {
                            return MultiBufferPoint(row: fInfo.multiBufferRow, column: bufferPoint.column)
                        }
                        forward += 1
                    }
                    // If not found forward, check backward
                    var backward = mid - 1
                    while backward >= start, let bInfo = codeInfo(for: backward), bInfo.bufferRow == bufferPoint.row {
                        if bInfo.diffKind != .deleted {
                            return MultiBufferPoint(row: bInfo.multiBufferRow, column: bufferPoint.column)
                        }
                        backward -= 1
                    }
                    // Fallback to mid
                    return MultiBufferPoint(row: cInfo.multiBufferRow, column: bufferPoint.column)
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