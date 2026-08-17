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

    public private(set) var displayLines: [DisplayLine] = []
    public private(set) var codeRowToDisplayLineIndex: [Int32] = []
    public private(set) var maxLineChars: Int = 80
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

    public struct ExcerptSliceRange: Sendable, Equatable {
        public var displayRange: Range<Int>
        public var codeRange: Range<Int>
    }
    public private(set) var excerptLocations: [ExcerptSliceRange] = []

    private struct ExcerptDiffCache {
        let bufferVersion: Int
        let bufferRange: Range<Int>
        let result: (lines: [(line: DiffLine, bufferRow: Int)], additions: Int, deletions: Int)
    }
    private var excerptDiffCache: [UUID: ExcerptDiffCache] = [:]

    private struct ExcerptChunk {
        let bufferVersion: Int
        let bufferRange: Range<Int>
        let isFileStart: Bool
        let canExpandUp: Bool
        let canExpandDown: Bool
        let topHidden: Int
        let bottomHidden: Int
        let reviewVersion: UInt64
        let isCollapsed: Bool

        let lines: [DisplayLine]
        let codeCount: Int
        let maxChars: Int
    }
    private var excerptChunkCache: [UUID: ExcerptChunk] = [:]

    public init(multiBuffer: MultiBuffer, reviewManager: ReviewManager) {
        self.multiBuffer = multiBuffer
        self.reviewManager = reviewManager
        rebuild()
    }

    public func clear() {
        displayLines.removeAll(keepingCapacity: false)
        codeRowToDisplayLineIndex.removeAll(keepingCapacity: false)
        excerptLocations.removeAll(keepingCapacity: false)
        excerptDiffCache.removeAll(keepingCapacity: false)
        excerptChunkCache.removeAll(keepingCapacity: false)
        maxLineChars = 80
    }

    /// Rebuilds the visual DisplayLine array from current MultiBuffer state
    public func rebuild() {
        displayLines.removeAll(keepingCapacity: true)
        codeRowToDisplayLineIndex.removeAll(keepingCapacity: true)
        excerptLocations.removeAll(keepingCapacity: true)

        var runningMBRow = 0
        var calculatedMaxChars: Int = 80
        let totalExcerpts = multiBuffer.excerpts.count

        excerptLocations.reserveCapacity(totalExcerpts)

        for (excerptIdx, _) in multiBuffer.excerpts.enumerated() {
            guard let chunk = buildChunk(for: excerptIdx, totalExcerpts: totalExcerpts) else {
                continue
            }

            let startDisplayIdx = displayLines.count
            let startCodeRow = codeRowToDisplayLineIndex.count

            for line in chunk.lines {
                switch line {
                case .excerptHeader(var headerInfo):
                    headerInfo.excerptIndex = excerptIdx
                    displayLines.append(.excerptHeader(headerInfo))
                case .foldGap(var gapInfo):
                    gapInfo.excerptIndex = excerptIdx
                    displayLines.append(.foldGap(gapInfo))
                case .code(var codeInfo):
                    codeInfo.excerptIndex = excerptIdx
                    if var exp = codeInfo.expandInfo {
                        exp.excerptIndex = excerptIdx
                        codeInfo.expandInfo = exp
                    }
                    codeInfo.multiBufferRow = runningMBRow
                    codeInfo.displayLineIndex = displayLines.count
                    codeRowToDisplayLineIndex.append(Int32(displayLines.count))
                    displayLines.append(.code(codeInfo))
                    runningMBRow += 1
                case .inlineComment(var commentInfo):
                    commentInfo.excerptIndex = excerptIdx
                    displayLines.append(.inlineComment(commentInfo))
                }
            }

            let endDisplayIdx = displayLines.count
            let endCodeRow = codeRowToDisplayLineIndex.count

            excerptLocations.append(ExcerptSliceRange(
                displayRange: startDisplayIdx..<endDisplayIdx,
                codeRange: startCodeRow..<endCodeRow
            ))

            if chunk.codeCount > 0 {
                calculatedMaxChars = max(calculatedMaxChars, chunk.maxChars)
            }
        }

        self.maxLineChars = calculatedMaxChars
    }

    /// O(File Lines) Scoped recomputation of ONLY the edited excerpt/file
    public func rebuildExcerpt(at excerptIdx: Int) -> (displayDelta: Int, codeDelta: Int, oldDisplayRange: Range<Int>)? {
        guard excerptIdx >= 0 && excerptIdx < multiBuffer.excerpts.count && excerptIdx < excerptLocations.count else {
            rebuild()
            return nil
        }
        let totalExcerpts = multiBuffer.excerpts.count
        guard let chunk = buildChunk(for: excerptIdx, totalExcerpts: totalExcerpts) else {
            rebuild()
            return nil
        }

        let oldLoc = excerptLocations[excerptIdx]
        let oldDisplayRange = oldLoc.displayRange
        let oldCodeRange = oldLoc.codeRange

        var newDisplayLines: [DisplayLine] = []
        newDisplayLines.reserveCapacity(chunk.lines.count)
        var newCodeIndices: [Int32] = []
        newCodeIndices.reserveCapacity(chunk.codeCount)

        var runningMBRow = oldCodeRange.lowerBound
        var currentDisplayIdx = oldDisplayRange.lowerBound

        let nextExcerptIndex = (excerptIdx < totalExcerpts - 1 && multiBuffer.excerpts[excerptIdx + 1].filePath == multiBuffer.excerpts[excerptIdx].filePath) ? (excerptIdx + 1) : nil

        for line in chunk.lines {
            switch line {
            case .code(var codeInfo):
                codeInfo.excerptIndex = excerptIdx
                codeInfo.multiBufferRow = runningMBRow
                codeInfo.displayLineIndex = currentDisplayIdx
                if var exp = codeInfo.expandInfo {
                    exp.excerptIndex = excerptIdx
                    codeInfo.expandInfo = exp
                }
                newDisplayLines.append(.code(codeInfo))
                newCodeIndices.append(Int32(currentDisplayIdx))
                runningMBRow += 1
                currentDisplayIdx += 1
            case .excerptHeader(var headerInfo):
                headerInfo.excerptIndex = excerptIdx
                newDisplayLines.append(.excerptHeader(headerInfo))
                currentDisplayIdx += 1
            case .foldGap(var gapInfo):
                gapInfo.excerptIndex = excerptIdx
                gapInfo.nextExcerptIndex = nextExcerptIndex
                newDisplayLines.append(.foldGap(gapInfo))
                currentDisplayIdx += 1
            case .inlineComment(var commentInfo):
                commentInfo.excerptIndex = excerptIdx
                newDisplayLines.append(.inlineComment(commentInfo))
                currentDisplayIdx += 1
            }
        }

        let displayDelta = newDisplayLines.count - oldDisplayRange.count
        let codeDelta = newCodeIndices.count - oldCodeRange.count

        // 1. Splice displayLines and codeRowToDisplayLineIndex
        displayLines.replaceSubrange(oldDisplayRange, with: newDisplayLines)
        codeRowToDisplayLineIndex.replaceSubrange(oldCodeRange, with: newCodeIndices)

        // 2. Update this excerpt location
        excerptLocations[excerptIdx] = ExcerptSliceRange(
            displayRange: oldDisplayRange.lowerBound..<(oldDisplayRange.upperBound + displayDelta),
            codeRange: oldCodeRange.lowerBound..<(oldCodeRange.upperBound + codeDelta)
        )

        // 3. Shift following excerpt locations & indices if counts changed
        if displayDelta != 0 || codeDelta != 0 {
            for j in (excerptIdx + 1)..<excerptLocations.count {
                let oldD = excerptLocations[j].displayRange
                let oldC = excerptLocations[j].codeRange
                let newD = (oldD.lowerBound + displayDelta)..<(oldD.upperBound + displayDelta)
                let newC = (oldC.lowerBound + codeDelta)..<(oldC.upperBound + codeDelta)
                excerptLocations[j] = ExcerptSliceRange(displayRange: newD, codeRange: newC)

                for k in newC {
                    codeRowToDisplayLineIndex[k] += Int32(displayDelta)
                }
            }
        }

        if chunk.maxChars > maxLineChars {
            maxLineChars = chunk.maxChars
        }

        return (displayDelta: displayDelta, codeDelta: codeDelta, oldDisplayRange: oldDisplayRange)
    }

    /// Builds or retrieves cached ExcerptChunk for a specific excerpt
    private func buildChunk(for excerptIdx: Int, totalExcerpts: Int) -> ExcerptChunk? {
        guard excerptIdx >= 0 && excerptIdx < multiBuffer.excerpts.count else { return nil }
        let excerpt = multiBuffer.excerpts[excerptIdx]
        guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else { return nil }

        let isFirstExcerptOfFile = excerpt.isFileStart || excerptIdx == 0
        let hasReviewComments = reviewManager.hasComments

        // Determine bounds and gap parameters
        let topHidden: Int
        if isFirstExcerptOfFile && excerpt.fileStatus != .deleted {
            let raw = buffer.startLineNumber > 1 ? (buffer.startLineNumber - 1 + excerpt.bufferRange.lowerBound) : excerpt.bufferRange.lowerBound
            topHidden = (raw >= 3) ? raw : 0
        } else {
            topHidden = 0
        }

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
        } else if excerptIdx < totalExcerpts - 1 && multiBuffer.excerpts[excerptIdx + 1].filePath == excerpt.filePath {
            canExpandDown = true
        } else {
            canExpandDown = false
        }

        let isLastExcerptOfFile: Bool
        if excerptIdx == totalExcerpts - 1 {
            isLastExcerptOfFile = true
        } else {
            isLastExcerptOfFile = (multiBuffer.excerpts[excerptIdx + 1].filePath != excerpt.filePath)
        }

        let bottomHidden: Int
        let nextExcerptIndex: Int?
        if !isLastExcerptOfFile {
            let nextExcerpt = multiBuffer.excerpts[excerptIdx + 1]
            let nextBuf = multiBuffer.buffer(for: nextExcerpt.bufferId)
            let raw: Int
            if nextExcerpt.bufferId == excerpt.bufferId {
                raw = max(0, nextExcerpt.bufferRange.lowerBound - excerpt.bufferRange.upperBound)
            } else {
                let nextStart = (nextBuf?.startLineNumber ?? 1) + nextExcerpt.bufferRange.lowerBound
                let currentEnd = buffer.startLineNumber + excerpt.bufferRange.upperBound
                raw = max(0, nextStart - currentEnd)
            }
            bottomHidden = (raw >= 3) ? raw : 0
            nextExcerptIndex = excerptIdx + 1
        } else if excerpt.fileStatus != .deleted {
            let totalLines = buffer.diskFileLineCount ?? (buffer.startLineNumber - 1 + buffer.lineCount)
            let currentEnd = (buffer.startLineNumber - 1) + excerpt.bufferRange.upperBound
            let raw = max(0, totalLines - currentEnd)
            bottomHidden = (raw >= 3) ? raw : 0
            nextExcerptIndex = nil
        } else {
            bottomHidden = 0
            nextExcerptIndex = nil
        }

        // Check Chunk Cache
        if let cached = excerptChunkCache[excerpt.id],
           cached.bufferVersion == buffer.version,
           cached.bufferRange == excerpt.bufferRange,
           cached.isFileStart == isFirstExcerptOfFile,
           cached.canExpandUp == canExpandUp,
           cached.canExpandDown == canExpandDown,
           cached.topHidden == topHidden,
           cached.bottomHidden == bottomHidden,
           cached.reviewVersion == reviewManager.version,
           cached.isCollapsed == excerpt.isCollapsed {
            return cached
        }

        var chunkLines: [DisplayLine] = []
        var chunkMaxChars = 80
        var codeCount = 0

        // 1. Excerpt Header
        if isFirstExcerptOfFile {
            let header = ExcerptHeaderInfo(
                excerptIndex: excerptIdx,
                filePath: excerpt.filePath,
                fileStatus: excerpt.fileStatus,
                additions: buffer.totalAdditions,
                deletions: buffer.totalDeletions,
                isCollapsed: excerpt.isCollapsed
            )
            chunkLines.append(.excerptHeader(header))
        }

        if !excerpt.isCollapsed {
            // 2. Top Fold Gap
            if topHidden > 0 {
                chunkLines.append(.foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: topHidden, isTopGap: true)))
            }

            // 3. Diff Lines
            let diffLinesToRender: [(line: DiffLine, bufferRow: Int)]
            if let hunk = excerpt.hunk, buffer.version == 0, excerpt.bufferRange == 0..<buffer.lineCount {
                var currentBufferRow = 0
                let hunkLines = hunk.lines
                var mappedLines: [(line: DiffLine, bufferRow: Int)] = []
                mappedLines.reserveCapacity(hunkLines.count)
                for dLine in hunkLines {
                    let bRow = currentBufferRow
                    if dLine.kind != .deleted {
                        currentBufferRow += 1
                    }
                    mappedLines.append((line: dLine, bufferRow: bRow))
                }
                diffLinesToRender = mappedLines
            } else if excerpt.fileStatus == .added || !buffer.baselineLines.isEmpty || excerpt.hunk != nil || buffer.fullDiskPath != nil {
                if let cachedDiff = excerptDiffCache[excerpt.id],
                   cachedDiff.bufferVersion == buffer.version,
                   cachedDiff.bufferRange == excerpt.bufferRange {
                    diffLinesToRender = cachedDiff.result.lines
                    if buffer.isFullFile {
                        buffer.totalAdditions = cachedDiff.result.additions
                        buffer.totalDeletions = cachedDiff.result.deletions
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

            let totalDiffLines = diffLinesToRender.count
            codeCount = totalDiffLines

            for (idx, item) in diffLinesToRender.enumerated() {
                let dLine = item.line
                let bRow = item.bufferRow

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

                let lineText = dLine.text
                chunkMaxChars = max(chunkMaxChars, lineText.count)

                let codeInfo = DisplayCodeLineInfo(
                    excerptIndex: excerptIdx,
                    multiBufferRow: 0,
                    bufferRow: bRow,
                    displayLineIndex: 0,
                    oldLineNumber: dLine.oldLineNumber,
                    newLineNumber: dLine.newLineNumber,
                    diffKind: dLine.kind,
                    text: lineText,
                    language: buffer.language,
                    wordDiffRanges: dLine.wordDiffRanges,
                    expandInfo: expandInfo
                )
                chunkLines.append(.code(codeInfo))

                // Inline Comments
                if hasReviewComments {
                    let lineForComment = dLine.newLineNumber ?? dLine.oldLineNumber ?? (bRow + 1)
                    let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                    for comment in matchedComments {
                        chunkLines.append(.inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment)))
                    }
                }
            }

            // 4. Bottom Fold Gap
            if bottomHidden > 0 {
                chunkLines.append(.foldGap(DisplayFoldGapInfo(
                    excerptIndex: excerptIdx,
                    nextExcerptIndex: nextExcerptIndex,
                    hiddenCount: bottomHidden,
                    isTopGap: false,
                    isBottomGap: isLastExcerptOfFile
                )))
            }
        }

        let chunk = ExcerptChunk(
            bufferVersion: buffer.version,
            bufferRange: excerpt.bufferRange,
            isFileStart: isFirstExcerptOfFile,
            canExpandUp: canExpandUp,
            canExpandDown: canExpandDown,
            topHidden: topHidden,
            bottomHidden: bottomHidden,
            reviewVersion: reviewManager.version,
            isCollapsed: excerpt.isCollapsed,
            lines: chunkLines,
            codeCount: codeCount,
            maxChars: chunkMaxChars
        )
        excerptChunkCache[excerpt.id] = chunk
        return chunk
    }

    /// O(1) Instant In-Place update of an edited line without rebuilding 1,000,000 DisplayLines
    public func updateLineInPlace(
        multiBufferRow: MultiBufferRow,
        buffer: Buffer,
        bufferRow: BufferRow,
        newText: String
    ) {
        guard multiBufferRow >= 0 && multiBufferRow < codeRowToDisplayLineIndex.count else { return }
        let lineIdx = Int(codeRowToDisplayLineIndex[multiBufferRow])
        guard lineIdx >= 0 && lineIdx < displayLines.count else { return }

        if case .code(var info) = displayLines[lineIdx] {
            info.text = newText
            // Recalculate intra-line word diff for this line against baseline if applicable
            let baselineLine = (bufferRow >= 0 && bufferRow < buffer.baselineLines.count) ? buffer.baselineLines[bufferRow] : ""
            if !baselineLine.isEmpty && baselineLine != newText {
                let (_, newRanges) = WordDiffEngine.shared.diffWords(oldText: baselineLine, newText: newText)
                info.wordDiffRanges = newRanges
            } else {
                info.wordDiffRanges = []
            }
            displayLines[lineIdx] = .code(info)

            if newText.count > maxLineChars {
                maxLineChars = newText.count
            }
        }
    }

    // MARK: - Lookups and Mapping Helpers

    public func codeInfo(for multiBufferRow: MultiBufferRow) -> DisplayCodeLineInfo? {
        guard multiBufferRow >= 0 && multiBufferRow < codeRowToDisplayLineIndex.count else { return nil }
        let lineIdx = Int(codeRowToDisplayLineIndex[multiBufferRow])
        guard lineIdx >= 0 && lineIdx < displayLines.count else { return nil }
        if case .code(var info) = displayLines[lineIdx] {
            info.multiBufferRow = multiBufferRow
            info.displayLineIndex = lineIdx
            return info
        }
        return nil
    }

    public func multiBufferRow(forDisplayLineIndex lineIdx: Int) -> MultiBufferRow? {
        guard lineIdx >= 0 && lineIdx < displayLines.count else { return nil }
        if case .code(let info) = displayLines[lineIdx] {
            guard info.excerptIndex >= 0 && info.excerptIndex < excerptLocations.count else { return nil }
            let loc = excerptLocations[info.excerptIndex]
            for mbRow in loc.codeRange {
                if mbRow >= 0 && mbRow < codeRowToDisplayLineIndex.count && Int(codeRowToDisplayLineIndex[mbRow]) == lineIdx {
                    return mbRow
                }
            }
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
        for (exIdx, loc) in excerptLocations.enumerated() {
            guard exIdx < multiBuffer.excerpts.count, multiBuffer.excerpts[exIdx].bufferId == bufferId else { continue }
            let start = loc.codeRange.lowerBound
            let end = loc.codeRange.upperBound - 1
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
                        return MultiBufferPoint(row: mid, column: bufferPoint.column)
                    }
                    // If mid was deleted, check forward for the matching non-deleted line
                    var forward = mid + 1
                    while forward <= end, let fInfo = codeInfo(for: forward), fInfo.bufferRow == bufferPoint.row {
                        if fInfo.diffKind != .deleted {
                            return MultiBufferPoint(row: forward, column: bufferPoint.column)
                        }
                        forward += 1
                    }
                    // If not found forward, check backward
                    var backward = mid - 1
                    while backward >= start, let bInfo = codeInfo(for: backward), bInfo.bufferRow == bufferPoint.row {
                        if bInfo.diffKind != .deleted {
                            return MultiBufferPoint(row: backward, column: bufferPoint.column)
                        }
                        backward -= 1
                    }
                    // Fallback to mid
                    return MultiBufferPoint(row: mid, column: bufferPoint.column)
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