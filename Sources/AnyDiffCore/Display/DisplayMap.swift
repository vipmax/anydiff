import Foundation
import Combine

public enum DiffViewMode: String, CaseIterable, Sendable {
    case unified = "Unified Multibuffer"
    case hunksOnly = "Hunks Only"
    case fullFile = "Full File Context"
}

/// Transforms logical MultiBuffer rows into visual DisplayLines using a zero-allocation Virtual Range Index
public final class DisplayMap: ObservableObject, @unchecked Sendable {
    public let multiBuffer: MultiBuffer
    public let reviewManager: ReviewManager
    public var viewMode: DiffViewMode = .unified

    public private(set) var maxLineChars: Int = 80

    public struct ExcerptSliceRange: Sendable, Equatable {
        public var displayRange: Range<Int>
        public var codeRange: Range<Int>
        public var excerptIndex: Int
        public var isFileStart: Bool
        public var isCollapsed: Bool
        public var topHidden: Int
        public var bottomHidden: Int
        public var nextExcerptIndex: Int?
        public var hasHeader: Bool
        public var hasTopGap: Bool
        public var hasBottomGap: Bool
        public var codeLineCount: Int

        public init(
            displayRange: Range<Int>,
            codeRange: Range<Int>,
            excerptIndex: Int,
            isFileStart: Bool,
            isCollapsed: Bool,
            topHidden: Int,
            bottomHidden: Int,
            nextExcerptIndex: Int?,
            hasHeader: Bool,
            hasTopGap: Bool,
            hasBottomGap: Bool,
            codeLineCount: Int
        ) {
            self.displayRange = displayRange
            self.codeRange = codeRange
            self.excerptIndex = excerptIndex
            self.isFileStart = isFileStart
            self.isCollapsed = isCollapsed
            self.topHidden = topHidden
            self.bottomHidden = bottomHidden
            self.nextExcerptIndex = nextExcerptIndex
            self.hasHeader = hasHeader
            self.hasTopGap = hasTopGap
            self.hasBottomGap = hasBottomGap
            self.codeLineCount = codeLineCount
        }
    }

    public private(set) var excerptLocations: [ExcerptSliceRange] = []
    /// Increments when the owning MultiBuffer has been loaded with new content.
    /// UI adapters use this to reset transient editor state such as the cursor.
    @Published public private(set) var loadRevision: UInt64 = 0

    public var displayLineCount: Int {
        excerptLocations.last?.displayRange.upperBound ?? 0
    }

    /// Compatibility snapshot. Prefer `displayLine(at:)` or `visibleLines(in:)` in production;
    /// this property intentionally materializes the complete display.
    public var displayLines: [DisplayLine] {
        displayLines(in: 0..<displayLineCount)
    }

    public var codeLineCount: Int {
        excerptLocations.last?.codeRange.upperBound ?? 0
    }

    public var minCodeRow: Int { 0 }
    public var maxCodeRow: Int { codeLineCount == 0 ? 0 : codeLineCount - 1 }

    /// MultiBuffer row for the first code line actually present in the display.
    /// This skips collapsed excerpts while still placing the cursor after any
    /// top hidden-lines fold gap.
    public var firstVisibleCodeRow: MultiBufferRow? {
        excerptLocations.first(where: { !$0.isCollapsed && $0.codeLineCount > 0 })?.codeRange.lowerBound
    }

    public func markContentLoaded() {
        loadRevision &+= 1
    }

    /// Compatibility snapshot. Prefer `codeInfo(for:)` or `visibleLines(in:)` in production;
    /// this property intentionally materializes every code line.
    public var codeLines: [DisplayCodeLineInfo] {
        var all: [DisplayCodeLineInfo] = []
        all.reserveCapacity(codeLineCount)
        for loc in excerptLocations {
            let items = generateVisibleLineItems(for: loc, requestedDisplayRange: loc.displayRange)
            for item in items {
                if case .code(let info) = item.line {
                    all.append(info)
                }
            }
        }
        return all
    }

    private struct ExcerptDiffCache {
        let bufferVersion: Int
        let bufferRange: Range<Int>
        let result: (lines: [(line: DiffLine, bufferRow: Int)], additions: Int, deletions: Int)
    }
    private var excerptDiffCache: [UUID: ExcerptDiffCache] = [:]
    private static let hunkRankStride = 256
    /// One UInt32 per 256 hunk lines. Unlike `excerptDiffCache`, this stays tiny
    /// even after every hunk in a mega-diff has been visited.
    private var hunkBufferRowRankCache: [UUID: [UInt32]] = [:]

    public init(multiBuffer: MultiBuffer, reviewManager: ReviewManager) {
        self.multiBuffer = multiBuffer
        self.reviewManager = reviewManager
        rebuild()
    }

    public func clear() {
        excerptLocations.removeAll(keepingCapacity: false)
        excerptDiffCache.removeAll(keepingCapacity: false)
        hunkBufferRowRankCache.removeAll(keepingCapacity: false)
        maxLineChars = 80
    }

    // MARK: - Rebuild & Range Indexing

    /// Rebuilds the prefix-sum Virtual Range Index across excerpts in O(Excerpts)
    public func rebuild() {
        excerptLocations.removeAll(keepingCapacity: true)
        excerptDiffCache.removeAll(keepingCapacity: false)
        hunkBufferRowRankCache.removeAll(keepingCapacity: false)

        var runningDisplayIdx = 0
        var runningMBRow = 0
        let calculatedMaxChars = 80
        let totalExcerpts = multiBuffer.excerpts.count

        excerptLocations.reserveCapacity(totalExcerpts)

        for (excerptIdx, excerpt) in multiBuffer.excerpts.enumerated() {
            guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else { continue }

            let isFirstExcerptOfFile = excerpt.isFileStart || (excerptIdx == 0) || (excerptIdx > 0 && multiBuffer.excerpts[excerptIdx - 1].filePath != excerpt.filePath)
            let isLastExcerptOfFile = (excerptIdx == totalExcerpts - 1) || (excerptIdx < totalExcerpts - 1 && multiBuffer.excerpts[excerptIdx + 1].filePath != excerpt.filePath)

            let topHidden: Int
            if isFirstExcerptOfFile && excerpt.fileStatus != .deleted {
                let raw = buffer.startLineNumber > 1 ? (buffer.startLineNumber - 1 + excerpt.bufferRange.lowerBound) : excerpt.bufferRange.lowerBound
                topHidden = (raw >= 3) ? raw : 0
            } else {
                topHidden = 0
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

            let hasHeader = isFirstExcerptOfFile
            let hasTopGap = (!excerpt.isCollapsed && topHidden > 0)
            // The diff does not contain the total line count after its last hunk.
            // Keep an unknown-size expansion affordance for local lazy slices;
            // resolving the actual boundary is deferred until the user clicks it.
            let hasUnknownLocalTail = isLastExcerptOfFile &&
                excerpt.fileStatus != .deleted &&
                buffer.isLazySlice &&
                buffer.fullDiskPath != nil &&
                buffer.diskFileLineCount == nil
            let hasBottomGap = (!excerpt.isCollapsed && (bottomHidden > 0 || hasUnknownLocalTail))

            let codeCount: Int
            if excerpt.isCollapsed {
                codeCount = 0
            } else if let hunk = excerpt.hunk, usesOriginalHunk(excerpt: excerpt, buffer: buffer) {
                codeCount = !hunk.lineSpans.isEmpty ? hunk.lineSpans.count : hunk.lines.count
            } else {
                codeCount = getCachedDiffLines(for: excerptIdx).count
            }

            let totalDisplayCount = (hasHeader ? 1 : 0) + (hasTopGap ? 1 : 0) + codeCount + (hasBottomGap ? 1 : 0)

            let displayRange = runningDisplayIdx..<(runningDisplayIdx + totalDisplayCount)
            let codeRange = runningMBRow..<(runningMBRow + codeCount)

            let slice = ExcerptSliceRange(
                displayRange: displayRange,
                codeRange: codeRange,
                excerptIndex: excerptIdx,
                isFileStart: isFirstExcerptOfFile,
                isCollapsed: excerpt.isCollapsed,
                topHidden: topHidden,
                bottomHidden: bottomHidden,
                nextExcerptIndex: nextExcerptIndex,
                hasHeader: hasHeader,
                hasTopGap: hasTopGap,
                hasBottomGap: hasBottomGap,
                codeLineCount: codeCount
            )
            excerptLocations.append(slice)

            runningDisplayIdx += totalDisplayCount
            runningMBRow += codeCount
        }

        self.maxLineChars = calculatedMaxChars
    }

    /// O(File Lines) Scoped recomputation of ONLY the edited excerpt/file
    @discardableResult
    public func rebuildExcerpt(at excerptIdx: Int) -> (displayDelta: Int, codeDelta: Int, oldDisplayRange: Range<Int>)? {
        guard excerptIdx >= 0 && excerptIdx < excerptLocations.count else {
            rebuild()
            return nil
        }
        let oldLoc = excerptLocations[excerptIdx]
        let oldDisplayRange = oldLoc.displayRange
        let oldCodeRange = oldLoc.codeRange

        rebuild()
        guard excerptIdx < excerptLocations.count else { return nil }
        let newLoc = excerptLocations[excerptIdx]

        let displayDelta = newLoc.displayRange.count - oldDisplayRange.count
        let codeDelta = newLoc.codeRange.count - oldCodeRange.count
        return (displayDelta: displayDelta, codeDelta: codeDelta, oldDisplayRange: oldDisplayRange)
    }

    // MARK: - On-Demand Viewport Line Generation

    public struct VisibleLineItem: Sendable {
        public let displayLineIndex: Int
        public let multiBufferRow: MultiBufferRow?
        public let line: DisplayLine
    }

    public subscript(index: Int) -> DisplayLine? {
        displayLine(at: index)
    }

    public func line(at index: Int) -> DisplayLine? {
        displayLine(at: index)
    }

    public func displayLine(at index: Int) -> DisplayLine? {
        guard index >= 0 && index < displayLineCount else { return nil }
        guard let loc = excerptLocation(forDisplayLineIndex: index) else { return nil }
        let items = generateVisibleLineItems(for: loc, requestedDisplayRange: index..<(index + 1))
        return items.first?.line
    }

    public func displayLines(in range: Range<Int>) -> [DisplayLine] {
        visibleLines(in: range).map { $0.line }
    }

    public func visibleLines(in range: Range<Int>) -> [VisibleLineItem] {
        let clamped = max(0, range.lowerBound)..<min(displayLineCount, range.upperBound)
        guard !clamped.isEmpty else { return [] }

        guard let firstLocIdx = excerptIndex(forDisplayLineIndex: clamped.lowerBound),
              let lastLocIdx = excerptIndex(forDisplayLineIndex: clamped.upperBound - 1) else {
            return []
        }

        var result: [VisibleLineItem] = []
        result.reserveCapacity(clamped.count)

        for locIdx in firstLocIdx...lastLocIdx {
            guard locIdx < excerptLocations.count else { break }
            let loc = excerptLocations[locIdx]
            let items = generateVisibleLineItems(for: loc, requestedDisplayRange: clamped)
            result.append(contentsOf: items)
        }
        return result
    }

    private func generateVisibleLineItems(for loc: ExcerptSliceRange, requestedDisplayRange: Range<Int>) -> [VisibleLineItem] {
        let excerptIdx = loc.excerptIndex
        guard excerptIdx >= 0 && excerptIdx < multiBuffer.excerpts.count else { return [] }
        let excerpt = multiBuffer.excerpts[excerptIdx]
        guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else { return [] }

        var items: [VisibleLineItem] = []
        var currentDisplayIdx = loc.displayRange.lowerBound

        // 1. Excerpt Header
        if loc.hasHeader {
            if requestedDisplayRange.contains(currentDisplayIdx) {
                let header = ExcerptHeaderInfo(
                    excerptIndex: excerptIdx,
                    filePath: excerpt.filePath,
                    fileStatus: excerpt.fileStatus,
                    additions: buffer.totalAdditions,
                    deletions: buffer.totalDeletions,
                    isCollapsed: excerpt.isCollapsed
                )
                items.append(VisibleLineItem(displayLineIndex: currentDisplayIdx, multiBufferRow: nil, line: .excerptHeader(header)))
            }
            currentDisplayIdx += 1
        }

        if !loc.isCollapsed {
            // 2. Top Fold Gap
            if loc.hasTopGap {
                if requestedDisplayRange.contains(currentDisplayIdx) {
                    items.append(VisibleLineItem(displayLineIndex: currentDisplayIdx, multiBufferRow: nil, line: .foldGap(DisplayFoldGapInfo(excerptIndex: excerptIdx, hiddenCount: loc.topHidden, isTopGap: true))))
                }
                currentDisplayIdx += 1
            }

            // 3. Code Lines (Direct slice indexing in O(1))
            if loc.codeLineCount > 0 {
                let codeStartDisplayIdx = currentDisplayIdx
                let startCodeIdx = max(0, requestedDisplayRange.lowerBound - codeStartDisplayIdx)
                let endCodeIdx = min(loc.codeLineCount, requestedDisplayRange.upperBound - codeStartDisplayIdx)

                if startCodeIdx < endCodeIdx {
                    let diffLines = getDiffLines(for: excerptIdx, in: startCodeIdx..<endCodeIdx)
                    let canExpandUp = (loc.topHidden > 0 || buffer.startLineNumber > 1 || excerpt.bufferRange.lowerBound > 0)
                    let canExpandDown = loc.hasBottomGap
                    let totalDiffLines = loc.codeLineCount

                    for (sliceOffset, item) in diffLines.enumerated() {
                        let idx = startCodeIdx + sliceOffset
                        let dLine = item.line
                        let bRow = item.bufferRow
                        let lineDisplayIdx = codeStartDisplayIdx + idx
                        let lineMBRow = loc.codeRange.lowerBound + idx

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
                            multiBufferRow: lineMBRow,
                            bufferRow: bRow,
                            displayLineIndex: lineDisplayIdx,
                            oldLineNumber: dLine.oldLineNumber,
                            newLineNumber: dLine.newLineNumber,
                            diffKind: dLine.kind,
                            text: dLine.text,
                            language: buffer.language,
                            wordDiffRanges: dLine.wordDiffRanges,
                            expandInfo: expandInfo
                        )
                        items.append(VisibleLineItem(displayLineIndex: lineDisplayIdx, multiBufferRow: lineMBRow, line: .code(codeInfo)))

                        if reviewManager.hasComments {
                            let lineForComment = dLine.newLineNumber ?? dLine.oldLineNumber ?? (bRow + 1)
                            let matchedComments = reviewManager.comments(for: excerpt.filePath, lineNumber: lineForComment)
                            for comment in matchedComments {
                                items.append(VisibleLineItem(displayLineIndex: lineDisplayIdx, multiBufferRow: lineMBRow, line: .inlineComment(DisplayCommentInfo(comment: comment, excerptIndex: excerptIdx, lineNumber: lineForComment))))
                            }
                        }
                    }
                }
                currentDisplayIdx += loc.codeLineCount
            }

            // 4. Bottom Fold Gap
            if loc.hasBottomGap {
                if requestedDisplayRange.contains(currentDisplayIdx) {
                    let isLast = (loc.nextExcerptIndex == nil)
                    items.append(VisibleLineItem(displayLineIndex: currentDisplayIdx, multiBufferRow: nil, line: .foldGap(DisplayFoldGapInfo(
                        excerptIndex: excerptIdx,
                        nextExcerptIndex: loc.nextExcerptIndex,
                        hiddenCount: loc.bottomHidden,
                        isCountKnown: loc.bottomHidden > 0,
                        isTopGap: false,
                        isBottomGap: isLast
                    ))))
                }
                currentDisplayIdx += 1
            }
        }

        return items
    }

    /// Returns only the requested hunk slice for immutable zero-copy data. Edited
    /// buffers still use the existing full diff cache because they are small and
    /// recomputing their line diff for every painted frame would be expensive.
    private func getDiffLines(for excerptIdx: Int, in requestedRange: Range<Int>) -> [(line: DiffLine, bufferRow: Int)] {
        guard excerptIdx >= 0 && excerptIdx < multiBuffer.excerpts.count else { return [] }
        let excerpt = multiBuffer.excerpts[excerptIdx]
        guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else { return [] }

        if let hunk = excerpt.hunk, usesOriginalHunk(excerpt: excerpt, buffer: buffer) {
            let totalCount = !hunk.lineSpans.isEmpty ? hunk.lineSpans.count : hunk.lines.count
            let clamped = max(0, requestedRange.lowerBound)..<min(totalCount, requestedRange.upperBound)
            guard !clamped.isEmpty else { return [] }

            var currentBufferRow = bufferRow(beforeHunkLine: clamped.lowerBound, in: hunk)
            var mappedLines: [(line: DiffLine, bufferRow: Int)] = []
            mappedLines.reserveCapacity(clamped.count)

            if !hunk.lineSpans.isEmpty {
                for index in clamped {
                    let span = hunk.lineSpans[index]
                    let dLine = DiffLine(
                        kind: span.kind,
                        text: buffer.storage.text(for: span) ?? "",
                        oldLineNumber: span.oldLineNumber > 0 ? Int(span.oldLineNumber) : nil,
                        newLineNumber: span.newLineNumber > 0 ? Int(span.newLineNumber) : nil
                    )
                    mappedLines.append((line: dLine, bufferRow: currentBufferRow))
                    if span.kind != .deleted {
                        currentBufferRow += 1
                    }
                }
            } else {
                for index in clamped {
                    let dLine = hunk.lines[index]
                    mappedLines.append((line: dLine, bufferRow: currentBufferRow))
                    if dLine.kind != .deleted {
                        currentBufferRow += 1
                    }
                }
            }
            return mappedLines
        }

        let allLines = getCachedDiffLines(for: excerptIdx)
        let clamped = max(0, requestedRange.lowerBound)..<min(allLines.count, requestedRange.upperBound)
        guard !clamped.isEmpty else { return [] }
        return Array(allLines[clamped])
    }

    private func getCachedDiffLines(for excerptIdx: Int) -> [(line: DiffLine, bufferRow: Int)] {
        guard excerptIdx >= 0 && excerptIdx < multiBuffer.excerpts.count else { return [] }
        let excerpt = multiBuffer.excerpts[excerptIdx]
        guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else { return [] }

        if let cached = excerptDiffCache[excerpt.id],
           cached.bufferVersion == buffer.version,
           cached.bufferRange == excerpt.bufferRange {
            return cached.result.lines
        }

        if excerpt.fileStatus == .added || !buffer.baselineLines.isEmpty || excerpt.hunk != nil || buffer.fullDiskPath != nil {
            let sliceResult = LineDiffEngine.shared.diffLinesForSlice(
                oldLines: buffer.baselineLines,
                newLines: buffer.lines,
                oldStartLine: buffer.startLineNumber,
                newStartLine: buffer.startLineNumber,
                targetRange: excerpt.bufferRange
            )
            if buffer.isFullFile {
                buffer.totalAdditions = sliceResult.additions
                buffer.totalDeletions = sliceResult.deletions
            }
            excerptDiffCache[excerpt.id] = ExcerptDiffCache(
                bufferVersion: buffer.version,
                bufferRange: excerpt.bufferRange,
                result: sliceResult
            )
            return sliceResult.lines
        } else {
            let range = excerpt.bufferRange
            let clamped = max(0, min(buffer.lineCount, range.lowerBound))..<max(0, min(buffer.lineCount, range.upperBound))
            let lines = clamped.map { r in
                let num = buffer.startLineNumber + r
                let dLine = DiffLine(kind: .unchanged, text: buffer.lines[r], oldLineNumber: num, newLineNumber: num)
                return (line: dLine, bufferRow: r)
            }
            let res = (lines: lines, additions: 0, deletions: 0)
            excerptDiffCache[excerpt.id] = ExcerptDiffCache(
                bufferVersion: buffer.version,
                bufferRange: excerpt.bufferRange,
                result: res
            )
            return lines
        }
    }

    private func bufferRow(beforeHunkLine lineIndex: Int, in hunk: DiffHunk) -> Int {
        guard lineIndex > 0 else { return 0 }
        let checkpoints = hunkBufferRowRankCheckpoints(for: hunk)
        let block = min(lineIndex / Self.hunkRankStride, max(0, checkpoints.count - 1))
        var row = checkpoints.isEmpty ? 0 : Int(checkpoints[block])
        let blockStart = block * Self.hunkRankStride

        if !hunk.lineSpans.isEmpty {
            for index in blockStart..<min(lineIndex, hunk.lineSpans.count) where hunk.lineSpans[index].kind != .deleted {
                row += 1
            }
        } else {
            for index in blockStart..<min(lineIndex, hunk.lines.count) where hunk.lines[index].kind != .deleted {
                row += 1
            }
        }
        return row
    }

    private func hunkBufferRowRankCheckpoints(for hunk: DiffHunk) -> [UInt32] {
        if let cached = hunkBufferRowRankCache[hunk.id] {
            return cached
        }

        let count = !hunk.lineSpans.isEmpty ? hunk.lineSpans.count : hunk.lines.count
        var checkpoints: [UInt32] = []
        checkpoints.reserveCapacity((count + Self.hunkRankStride - 1) / Self.hunkRankStride)
        var row: UInt32 = 0

        for index in 0..<count {
            if index % Self.hunkRankStride == 0 {
                checkpoints.append(row)
            }
            let kind = !hunk.lineSpans.isEmpty ? hunk.lineSpans[index].kind : hunk.lines[index].kind
            if kind != .deleted {
                row &+= 1
            }
        }

        hunkBufferRowRankCache[hunk.id] = checkpoints
        return checkpoints
    }

    private func usesOriginalHunk(excerpt: Excerpt, buffer: Buffer) -> Bool {
        guard buffer.version == 0, excerpt.hunk != nil else { return false }
        if excerpt.fileStatus == .deleted {
            return excerpt.bufferRange.isEmpty
        }
        return excerpt.bufferRange == 0..<buffer.lineCount
    }

    // MARK: - Lookups & Coordinate Mapping Helpers (Binary Search O(log N))

    public func excerptIndex(forDisplayLineIndex lineIdx: Int) -> Int? {
        guard !excerptLocations.isEmpty else { return nil }
        var low = 0
        var high = excerptLocations.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = excerptLocations[mid].displayRange
            if lineIdx < range.lowerBound {
                high = mid - 1
            } else if lineIdx >= range.upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    public func excerptLocation(forDisplayLineIndex lineIdx: Int) -> ExcerptSliceRange? {
        guard let idx = excerptIndex(forDisplayLineIndex: lineIdx) else { return nil }
        return excerptLocations[idx]
    }

    public func excerptIndex(forCodeRow codeRow: Int) -> Int? {
        guard !excerptLocations.isEmpty else { return nil }
        var low = 0
        var high = excerptLocations.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = excerptLocations[mid].codeRange
            if codeRow < range.lowerBound {
                high = mid - 1
            } else if codeRow >= range.upperBound {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    public func codeInfo(for multiBufferRow: MultiBufferRow) -> DisplayCodeLineInfo? {
        guard let locIdx = excerptIndex(forCodeRow: multiBufferRow) else { return nil }
        let loc = excerptLocations[locIdx]
        let offset = multiBufferRow - loc.codeRange.lowerBound
        guard offset >= 0 && offset < loc.codeLineCount else { return nil }

        let targetDisplayIdx = loc.displayRange.lowerBound + (loc.hasHeader ? 1 : 0) + (loc.hasTopGap ? 1 : 0) + offset
        let items = generateVisibleLineItems(for: loc, requestedDisplayRange: targetDisplayIdx..<(targetDisplayIdx + 1))
        for item in items {
            if case .code(let info) = item.line {
                return info
            }
        }
        return nil
    }

    public func multiBufferRow(forDisplayLineIndex lineIdx: Int) -> MultiBufferRow? {
        guard let loc = excerptLocation(forDisplayLineIndex: lineIdx) else { return nil }
        guard !loc.isCollapsed else { return nil }

        let codeStartDisplayIdx = loc.displayRange.lowerBound + (loc.hasHeader ? 1 : 0) + (loc.hasTopGap ? 1 : 0)
        let codeOffset = lineIdx - codeStartDisplayIdx
        if codeOffset >= 0 && codeOffset < loc.codeLineCount {
            return loc.codeRange.lowerBound + codeOffset
        }
        return nil
    }

    public func displayLineIndex(forMultiBufferRow mbRow: MultiBufferRow) -> Int? {
        guard let locIdx = excerptIndex(forCodeRow: mbRow) else { return nil }
        let loc = excerptLocations[locIdx]
        let codeOffset = mbRow - loc.codeRange.lowerBound
        return loc.displayRange.lowerBound + (loc.hasHeader ? 1 : 0) + (loc.hasTopGap ? 1 : 0) + codeOffset
    }

    public var firstCodeInfo: DisplayCodeLineInfo? {
        guard codeLineCount > 0 else { return nil }
        return codeInfo(for: 0)
    }

    public var lastCodeInfo: DisplayCodeLineInfo? {
        guard codeLineCount > 0 else { return nil }
        return codeInfo(for: codeLineCount - 1)
    }

    public func lineText(at multiBufferRow: MultiBufferRow) -> String? {
        codeInfo(for: multiBufferRow)?.text
    }

    public func lineLength(at multiBufferRow: MultiBufferRow) -> Int {
        lineText(at: multiBufferRow)?.count ?? 0
    }

    public func nextCodeRow(after row: MultiBufferRow) -> MultiBufferRow? {
        let next = row + 1
        guard next >= 0 && next < codeLineCount else { return nil }
        return next
    }

    public func previousCodeRow(before row: MultiBufferRow) -> MultiBufferRow? {
        let prev = row - 1
        guard prev >= 0 && prev < codeLineCount else { return nil }
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
            guard loc.codeLineCount > 0 else { continue }

            let start = loc.codeRange.lowerBound
            let end = loc.codeRange.upperBound - 1

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
                    if cInfo.diffKind != .deleted {
                        return MultiBufferPoint(row: mid, column: bufferPoint.column)
                    } else {
                        var candidate = mid + 1
                        while candidate <= end {
                            if let candInfo = codeInfo(for: candidate), candInfo.diffKind != .deleted {
                                return MultiBufferPoint(row: candidate, column: bufferPoint.column)
                            }
                            candidate += 1
                        }
                        var prevCandidate = mid - 1
                        while prevCandidate >= start {
                            if let prevInfo = codeInfo(for: prevCandidate), prevInfo.diffKind != .deleted {
                                return MultiBufferPoint(row: prevCandidate, column: bufferPoint.column)
                            }
                            prevCandidate -= 1
                        }
                        return MultiBufferPoint(row: mid, column: bufferPoint.column)
                    }
                }
            }
        }
        return nil
    }
}
