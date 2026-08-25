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

    public struct ExcerptFlags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let isFileStart    = ExcerptFlags(rawValue: 1 << 0)
        public static let isCollapsed    = ExcerptFlags(rawValue: 1 << 1)
        public static let hasHeader      = ExcerptFlags(rawValue: 1 << 2)
        public static let hasTopGap      = ExcerptFlags(rawValue: 1 << 3)
        public static let hasBottomGap   = ExcerptFlags(rawValue: 1 << 4)
        public static let hasNextExcerpt = ExcerptFlags(rawValue: 1 << 5)
    }

    /// Compact 36-byte virtual slice range indexing an excerpt inside DisplayMap
    public struct ExcerptSliceRange: Sendable, Equatable {
        public var displayStart: UInt32
        public var displayCount: UInt32
        public var codeStart: UInt32
        public var codeCount: UInt32
        public var excerptIndex32: UInt32
        public var topHidden32: UInt32
        public var bottomHidden32: UInt32
        public var nextExcerptIndex32: UInt32
        public var flags: ExcerptFlags

        @inlinable
        public var displayRange: Range<Int> {
            Int(displayStart)..<Int(displayStart + displayCount)
        }

        @inlinable
        public var codeRange: Range<Int> {
            Int(codeStart)..<Int(codeStart + codeCount)
        }

        @inlinable
        public var excerptIndex: Int {
            Int(excerptIndex32)
        }

        @inlinable
        public var topHidden: Int {
            Int(topHidden32)
        }

        @inlinable
        public var bottomHidden: Int {
            Int(bottomHidden32)
        }

        @inlinable
        public var nextExcerptIndex: Int? {
            flags.contains(.hasNextExcerpt) ? Int(nextExcerptIndex32) : nil
        }

        @inlinable
        public var isFileStart: Bool {
            flags.contains(.isFileStart)
        }

        @inlinable
        public var isCollapsed: Bool {
            flags.contains(.isCollapsed)
        }

        @inlinable
        public var hasHeader: Bool {
            flags.contains(.hasHeader)
        }

        @inlinable
        public var hasTopGap: Bool {
            flags.contains(.hasTopGap)
        }

        @inlinable
        public var hasBottomGap: Bool {
            flags.contains(.hasBottomGap)
        }

        @inlinable
        public var codeLineCount: Int {
            Int(codeCount)
        }

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
            self.displayStart = UInt32(clamping: max(0, displayRange.lowerBound))
            self.displayCount = UInt32(clamping: max(0, displayRange.count))
            self.codeStart = UInt32(clamping: max(0, codeRange.lowerBound))
            self.codeCount = UInt32(clamping: max(0, codeLineCount))
            self.excerptIndex32 = UInt32(clamping: max(0, excerptIndex))
            self.topHidden32 = UInt32(clamping: max(0, topHidden))
            self.bottomHidden32 = UInt32(clamping: max(0, bottomHidden))

            var f: ExcerptFlags = []
            if isFileStart { f.insert(.isFileStart) }
            if isCollapsed { f.insert(.isCollapsed) }
            if hasHeader { f.insert(.hasHeader) }
            if hasTopGap { f.insert(.hasTopGap) }
            if hasBottomGap { f.insert(.hasBottomGap) }
            if let next = nextExcerptIndex {
                f.insert(.hasNextExcerpt)
                self.nextExcerptIndex32 = UInt32(clamping: max(0, next))
            } else {
                self.nextExcerptIndex32 = 0xFFFF_FFFF
            }
            self.flags = f
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
        var calculatedMaxChars = 80
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
            } else if multiBuffer.contentMode == .diff,
                      let hunk = excerpt.hunk,
                      usesOriginalHunk(excerpt: excerpt, buffer: buffer) {
                if !hunk.lineSpans.isEmpty {
                    codeCount = hunk.lineSpans.count
                    for span in hunk.lineSpans { calculatedMaxChars = max(calculatedMaxChars, Int(span.length)) }
                } else {
                    codeCount = hunk.lines.count
                    for line in hunk.lines { calculatedMaxChars = max(calculatedMaxChars, line.text.count) }
                }
            } else {
                let diffLines = getCachedDiffLines(for: excerptIdx)
                codeCount = diffLines.count
                for item in diffLines { calculatedMaxChars = max(calculatedMaxChars, item.line.text.count) }
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

    /// O(Excerpt Lines) Scoped recomputation of ONLY the edited excerpt/file
    @discardableResult
    public func rebuildExcerpt(at excerptIdx: Int) -> (displayDelta: Int, codeDelta: Int, oldDisplayRange: Range<Int>)? {
        guard excerptIdx >= 0 && excerptIdx < excerptLocations.count && excerptIdx < multiBuffer.excerpts.count else {
            rebuild()
            return nil
        }
        let excerpt = multiBuffer.excerpts[excerptIdx]
        guard let buffer = multiBuffer.buffer(for: excerpt.bufferId) else {
            rebuild()
            return nil
        }

        let oldLoc = excerptLocations[excerptIdx]
        let oldDisplayRange = oldLoc.displayRange
        let oldDisplayCount = oldDisplayRange.count
        let oldCodeCount = oldLoc.codeLineCount

        // 1. Invalidate only this excerpt's cache entry
        excerptDiffCache.removeValue(forKey: excerpt.id)

        // 2. Recompute codeCount for this excerpt ONLY
        let newCodeCount: Int
        if excerpt.isCollapsed {
            newCodeCount = 0
        } else if multiBuffer.contentMode == .diff,
                  let hunk = excerpt.hunk,
                  usesOriginalHunk(excerpt: excerpt, buffer: buffer) {
            if !hunk.lineSpans.isEmpty {
                newCodeCount = hunk.lineSpans.count
                for span in hunk.lineSpans { maxLineChars = max(maxLineChars, Int(span.length)) }
            } else {
                newCodeCount = hunk.lines.count
                for line in hunk.lines { maxLineChars = max(maxLineChars, line.text.count) }
            }
        } else {
            let diffLines = getCachedDiffLines(for: excerptIdx)
            newCodeCount = diffLines.count
            for item in diffLines { maxLineChars = max(maxLineChars, item.line.text.count) }
        }

        // 3. Recompute total display line count for this excerpt ONLY
        let newTotalDisplayCount = (oldLoc.hasHeader ? 1 : 0) + (oldLoc.hasTopGap ? 1 : 0) + newCodeCount + (oldLoc.hasBottomGap ? 1 : 0)

        let displayDelta = newTotalDisplayCount - oldDisplayCount
        let codeDelta = newCodeCount - oldCodeCount

        // 4. Update the excerpt slice in-place
        excerptLocations[excerptIdx].displayCount = UInt32(newTotalDisplayCount)
        excerptLocations[excerptIdx].codeCount = UInt32(newCodeCount)

        // 5. If counts changed (e.g. newline added/deleted), shift subsequent excerpts with fast SIMD-friendly integer additions
        if displayDelta != 0 || codeDelta != 0 {
            for i in (excerptIdx + 1)..<excerptLocations.count {
                excerptLocations[i].displayStart = UInt32(Int(excerptLocations[i].displayStart) + displayDelta)
                excerptLocations[i].codeStart = UInt32(Int(excerptLocations[i].codeStart) + codeDelta)
            }
        }

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

        if multiBuffer.contentMode == .diff,
           let hunk = excerpt.hunk,
           usesOriginalHunk(excerpt: excerpt, buffer: buffer) {
            let totalCount = !hunk.lineSpans.isEmpty ? hunk.lineSpans.count : hunk.lines.count
            let clamped = max(0, requestedRange.lowerBound)..<min(totalCount, requestedRange.upperBound)
            guard !clamped.isEmpty else { return [] }

            // Small zero-copy hunks are materialized as a unit so adjacent
            // deleted/added pairs receive word highlights on the first paint.
            // Large hunks retain viewport-only materialization.
            let materializedRange: Range<Int>
            if !hunk.lineSpans.isEmpty && totalCount <= 4_096 {
                materializedRange = 0..<totalCount
            } else {
                materializedRange = clamped
            }
            let hunkBufferBaseRow = buffer.isFullFile ? excerpt.bufferRange.lowerBound : 0
            var currentBufferRow = hunkBufferBaseRow
                + bufferRow(beforeHunkLine: materializedRange.lowerBound, in: hunk)
            var mappedLines: [(line: DiffLine, bufferRow: Int)] = []
            mappedLines.reserveCapacity(materializedRange.count)

            if !hunk.lineSpans.isEmpty {
                for index in materializedRange {
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
                var presentationLines = mappedLines.map(\.line)
                LineDiffEngine.shared.refreshWordDiffs(in: &presentationLines)
                for index in mappedLines.indices {
                    mappedLines[index].line = presentationLines[index]
                }
            } else {
                for index in materializedRange {
                    let dLine = hunk.lines[index]
                    mappedLines.append((line: dLine, bufferRow: currentBufferRow))
                    if dLine.kind != .deleted {
                        currentBufferRow += 1
                    }
                }
            }
            let requestedStart = clamped.lowerBound - materializedRange.lowerBound
            let requestedEnd = clamped.upperBound - materializedRange.lowerBound
            return Array(mappedLines[requestedStart..<requestedEnd])
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

        if multiBuffer.contentMode == .diff &&
            (excerpt.fileStatus == .added || !buffer.baselineLines.isEmpty || excerpt.hunk != nil || buffer.fullDiskPath != nil) {
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
        guard multiBuffer.contentMode == .diff else { return false }
        guard let hunk = excerpt.hunk else { return false }
        if buffer.version == 0 {
            if excerpt.fileStatus == .deleted {
                return excerpt.bufferRange.isEmpty
            }
            return excerpt.bufferRange == 0..<buffer.lineCount
        }
        guard excerpt.stableHunkBufferVersion == buffer.version,
              hunk.lineSpans.isEmpty,
              excerpt.fileStatus != .deleted else { return false }
        let editableCount = hunk.lines.reduce(into: 0) { count, line in
            if line.kind != .deleted { count += 1 }
        }
        return editableCount == excerpt.bufferRange.count
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

    /// Resolves an ExcerptLocation (filePath + bufferRow + bufferColumn) to the visual MultiBufferPoint
    public func multiBufferPoint(for location: ExcerptLocation) -> MultiBufferPoint? {
        guard !multiBuffer.excerpts.isEmpty else { return nil }

        var bestMatch: (excerptIndex: Int, row: Int)? = nil

        for (idx, excerpt) in multiBuffer.excerpts.enumerated() {
            if excerpt.filePath == location.filePath {
                if excerpt.bufferRange.contains(location.bufferRow) {
                    bestMatch = (idx, location.bufferRow)
                    break
                } else if bestMatch == nil {
                    let clampedRow = max(excerpt.bufferRange.lowerBound, min(max(excerpt.bufferRange.lowerBound, excerpt.bufferRange.upperBound - 1), location.bufferRow))
                    bestMatch = (idx, clampedRow)
                }
            }
        }

        if let match = bestMatch, let mbRow = multiBuffer.multiBufferRow(excerptIndex: match.excerptIndex, bufferRow: match.row) {
            let maxCol = lineLength(at: mbRow)
            let clampedCol = max(0, min(maxCol, location.bufferColumn))
            return MultiBufferPoint(row: mbRow, column: clampedCol)
        }

        return nil
    }

    /// Finds the first code row for the given file path
    public func firstCodeRow(forFilePath filePath: String) -> MultiBufferRow? {
        guard !multiBuffer.excerpts.isEmpty else { return nil }
        for loc in excerptLocations {
            guard loc.excerptIndex >= 0 && loc.excerptIndex < multiBuffer.excerpts.count else { continue }
            let excerpt = multiBuffer.excerpts[loc.excerptIndex]
            guard excerpt.filePath == filePath else { continue }
            if loc.codeLineCount > 0 {
                return loc.codeRange.lowerBound
            }
        }
        return nil
    }

    /// Finds the code row in DisplayMap closest to the given file path and line number
    public func codeRow(forFilePath filePath: String, lineNumber: Int) -> MultiBufferRow? {
        guard !multiBuffer.excerpts.isEmpty else { return nil }

        var bestRow: MultiBufferRow? = nil
        var minDiff = Int.max
        var exactOldRow: MultiBufferRow? = nil

        for loc in excerptLocations {
            guard loc.excerptIndex >= 0 && loc.excerptIndex < multiBuffer.excerpts.count else { continue }
            let excerpt = multiBuffer.excerpts[loc.excerptIndex]
            guard excerpt.filePath == filePath else { continue }

            for row in loc.codeRange {
                if let info = codeInfo(for: row) {
                    // A replacement has both an old/deleted and a new/added
                    // line with the same number. Cursor/viewport restoration
                    // must target the editable new side.
                    if info.newLineNumber == lineNumber && info.diffKind != .deleted {
                        return row
                    }
                    if info.oldLineNumber == lineNumber && exactOldRow == nil {
                        exactOldRow = row
                    }
                    let lineNum = info.newLineNumber ?? info.oldLineNumber ?? 0
                    let diff = abs(lineNum - lineNumber)
                    if diff < minDiff {
                        minDiff = diff
                        bestRow = row
                    }
                }
            }
        }

        return exactOldRow ?? bestRow
    }

    /// Finds the display line index closest to the given file path and line number
    public func displayLineIndex(forFilePath filePath: String, lineNumber: Int?, isHeader: Bool = false) -> Int? {
        guard !multiBuffer.excerpts.isEmpty else { return nil }

        for loc in excerptLocations {
            guard loc.excerptIndex >= 0 && loc.excerptIndex < multiBuffer.excerpts.count else { continue }
            let excerpt = multiBuffer.excerpts[loc.excerptIndex]
            guard excerpt.filePath == filePath else { continue }

            if isHeader && loc.hasHeader {
                return loc.displayRange.lowerBound
            }
            if lineNumber == nil && loc.hasHeader {
                return loc.displayRange.lowerBound
            }
        }

        if let targetLine = lineNumber, let codeR = codeRow(forFilePath: filePath, lineNumber: targetLine) {
            return displayLineIndex(forMultiBufferRow: codeR)
        }

        for loc in excerptLocations {
            guard loc.excerptIndex >= 0 && loc.excerptIndex < multiBuffer.excerpts.count else { continue }
            if multiBuffer.excerpts[loc.excerptIndex].filePath == filePath {
                return loc.displayRange.lowerBound
            }
        }

        return nil
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
