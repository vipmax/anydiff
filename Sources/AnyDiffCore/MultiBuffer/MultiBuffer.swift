import Foundation
import Combine

/// Continuous virtual document composing multiple file diff excerpts into a single editable canvas
public final class MultiBuffer: ObservableObject, @unchecked Sendable {
    public private(set) var buffers: [BufferId: Buffer] = [:]
    public private(set) var excerpts: [Excerpt] = []
    public let undoManager: MultiBufferUndoManager

    /// Monotonically increasing version counter to invalidate layout caches
    public private(set) var version: UInt64 = 0

    public init(undoManager: MultiBufferUndoManager = MultiBufferUndoManager()) {
        self.undoManager = undoManager
    }

    // MARK: - Buffer & Excerpt Management

    public func addBuffer(_ buffer: Buffer) {
        buffers[buffer.id] = buffer
        version &+= 1
    }

    public func buffer(for id: BufferId) -> Buffer? {
        buffers[id]
    }

    public func addExcerpt(_ excerpt: Excerpt) {
        excerpts.append(excerpt)
        version &+= 1
    }

    public func setExcerpts(_ newExcerpts: [Excerpt]) {
        self.excerpts = newExcerpts
        version &+= 1
    }

    public func updateExcerptBufferRange(at index: ExcerptIndex, range: Range<BufferRow>) {
        guard index >= 0 && index < excerpts.count else { return }
        excerpts[index].bufferRange = range
        version &+= 1
    }

    public func clear() {
        buffers.removeAll()
        excerpts.removeAll()
        undoManager.clear()
        version &+= 1
    }

    // MARK: - Coordinate Translation & Rows

    /// Total continuous logical rows across all active excerpts
    public var lineCount: Int {
        excerpts.reduce(0) { $0 + $1.lineCount }
    }

    /// Resolves a MultiBufferRow to its corresponding Excerpt and row within the underlying Buffer
    public func location(for mbRow: MultiBufferRow) -> ExcerptLocation? {
        guard mbRow >= 0 else { return nil }
        var currentMBRow = 0

        for (idx, excerpt) in excerpts.enumerated() {
            let count = excerpt.lineCount
            if mbRow >= currentMBRow && mbRow < (currentMBRow + count) {
                let offsetInExcerpt = mbRow - currentMBRow
                let bufferRow = excerpt.bufferRange.lowerBound + offsetInExcerpt
                return ExcerptLocation(
                    excerptIndex: idx,
                    bufferId: excerpt.bufferId,
                    filePath: excerpt.filePath,
                    bufferRow: bufferRow,
                    bufferColumn: 0
                )
            }
            currentMBRow += count
        }

        return nil
    }

    /// Resolves a MultiBufferPoint to an ExcerptLocation with column precision
    public func location(for point: MultiBufferPoint) -> ExcerptLocation? {
        guard var loc = location(for: point.row) else { return nil }
        loc.bufferColumn = point.column
        return loc
    }

    /// Converts an Excerpt and BufferRow to the continuous MultiBufferRow
    public func multiBufferRow(excerptIndex: ExcerptIndex, bufferRow: BufferRow) -> MultiBufferRow? {
        guard excerptIndex >= 0 && excerptIndex < excerpts.count else { return nil }
        var currentMBRow = 0

        for i in 0..<excerptIndex {
            currentMBRow += excerpts[i].lineCount
        }

        let excerpt = excerpts[excerptIndex]
        guard excerpt.bufferRange.contains(bufferRow) else { return nil }

        let offsetInExcerpt = bufferRow - excerpt.bufferRange.lowerBound
        return currentMBRow + offsetInExcerpt
    }

    /// Retrieves text of a single line at the given MultiBufferRow
    public func line(at mbRow: MultiBufferRow) -> String {
        guard let loc = location(for: mbRow),
              let buf = buffers[loc.bufferId],
              let text = buf.line(at: loc.bufferRow) else {
            return ""
        }
        return text
    }

    public func lineLength(at mbRow: MultiBufferRow) -> Int {
        line(at: mbRow).count
    }

    // MARK: - Live Text Editing

    /// Replaces text in the MultiBuffer, executing the edit in the corresponding underlying Buffer
    @discardableResult
    public func replace(range: Range<MultiBufferPoint>, with newText: String, recordUndo: Bool = true) -> Range<MultiBufferPoint> {
        guard let startLoc = location(for: range.lowerBound),
              let endLoc = location(for: range.upperBound),
              startLoc.bufferId == endLoc.bufferId,
              let buf = buffers[startLoc.bufferId] else {
            return range
        }

        let pt1 = BufferPoint(row: startLoc.bufferRow, column: startLoc.bufferColumn)
        let pt2 = BufferPoint(row: endLoc.bufferRow, column: endLoc.bufferColumn)
        let oldStartPt = min(pt1, pt2)
        let oldEndPt = max(pt1, pt2)

        // Capture exact old text for undo
        let oldExactText = (oldStartPt < oldEndPt) ? buf.text(in: oldStartPt..<oldEndPt) : ""

        // Perform edit on the buffer
        let newBufRange = buf.replace(start: oldStartPt, end: oldEndPt, with: newText)

        // Update excerpt range if the line count changed
        let lineDelta = (newBufRange.upperBound.row - oldEndPt.row)
        if lineDelta != 0 {
            let excerptIdx = startLoc.excerptIndex
            var excerpt = excerpts[excerptIdx]
            let newUpper = max(excerpt.bufferRange.lowerBound, excerpt.bufferRange.upperBound + lineDelta)
            excerpt.bufferRange = excerpt.bufferRange.lowerBound..<newUpper
            excerpts[excerptIdx] = excerpt

            // Shift all subsequent excerpts pointing to the same buffer
            for i in (excerptIdx + 1)..<excerpts.count {
                if excerpts[i].bufferId == startLoc.bufferId {
                    let oldRange = excerpts[i].bufferRange
                    let newLower = max(newUpper, oldRange.lowerBound + lineDelta)
                    let newUpperSub = max(newLower, oldRange.upperBound + lineDelta)
                    excerpts[i].bufferRange = newLower..<newUpperSub
                }
            }
        }

        if recordUndo {
            let editRangeStart = min(oldStartPt, newBufRange.upperBound)
            let editRangeEnd = max(oldStartPt, newBufRange.upperBound)
            let edit = TextEdit(
                bufferId: startLoc.bufferId,
                range: editRangeStart..<editRangeEnd,
                oldText: oldExactText,
                newText: newText
            )
            let transaction = EditTransaction(
                edits: [edit],
                selectionBefore: range,
                selectionAfter: nil
            )
            undoManager.push(transaction: transaction)
        }

        // Schedule 200ms debounced auto-save to disk
        scheduleDebouncedSave(delayMs: 200)

        version &+= 1
        onEdit?()

        let newEndMBRow = multiBufferRow(excerptIndex: startLoc.excerptIndex, bufferRow: newBufRange.upperBound.row) ?? range.lowerBound.row
        let newEndPoint = MultiBufferPoint(row: newEndMBRow, column: newBufRange.upperBound.column)
        let startPt = min(range.lowerBound, newEndPoint)
        let endPt = max(range.lowerBound, newEndPoint)
        return startPt..<endPt
    }

    /// Inserts text at a point
    @discardableResult
    public func insert(text: String, at point: MultiBufferPoint) -> Range<MultiBufferPoint> {
        replace(range: point..<point, with: text)
    }

    /// Deletes text in a range
    @discardableResult
    public func delete(range: Range<MultiBufferPoint>) -> MultiBufferPoint {
        let res = replace(range: range, with: "")
        return res.lowerBound
    }

    // MARK: - Saving & Dirty State

    public var baseDirectory: String?
    public var onEdit: (() -> Void)?
    private var saveDebounceWorkItem: DispatchWorkItem?

    public var isDirty: Bool {
        buffers.values.contains { $0.isDirty }
    }

    /// Debounces saving all dirty buffers to disk with a 200ms delay to avoid CPU/LSP thrashing
    public func scheduleDebouncedSave(delayMs: Int = 200) {
        saveDebounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            do {
                _ = try self?.saveAllDirtyBuffers()
            } catch {
                // Debounced background saves intentionally do not interrupt editing.
            }
        }
        saveDebounceWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    /// Immediately writes all modified buffers to disk (e.g. on Cmd+S)
    @discardableResult
    public func flushImmediateSave() -> [String] {
        saveDebounceWorkItem?.cancel()
        saveDebounceWorkItem = nil
        return (try? saveAllDirtyBuffers()) ?? []
    }

    @discardableResult
    public func saveAllDirtyBuffers() throws -> [String] {
        var savedFiles: [String] = []
        for buffer in buffers.values where buffer.isDirty {
            try buffer.saveToFile(baseDirectory: baseDirectory)
            savedFiles.append(buffer.filePath)
        }
        return savedFiles
    }

    // MARK: - Context Expansion

    public enum ExpandExcerptDirection {
        case up
        case down
        case upAndDown
    }

    @discardableResult
    public func expandExcerpt(at index: ExcerptIndex, up: Int = 0, down: Int = 0) -> (linesAddedUp: Int, linesAddedDown: Int) {
        guard index >= 0 && index < excerpts.count else { return (0, 0) }
        var excerpt = excerpts[index]
        guard let buf = buffers[excerpt.bufferId] else { return (0, 0) }

        var addedUp = 0
        var addedDown = 0

        if up > 0 {
            let oldLower = excerpt.bufferRange.lowerBound
            let newLower = max(0, oldLower - up)
            addedUp = oldLower - newLower
            excerpt.bufferRange = newLower..<excerpt.bufferRange.upperBound
        }
        if down > 0 {
            let oldUpper = excerpt.bufferRange.upperBound
            let newUpper = min(buf.lineCount, oldUpper + down)
            addedDown = newUpper - oldUpper
            excerpt.bufferRange = excerpt.bufferRange.lowerBound..<newUpper
        }

        let diskPath = buf.fullDiskPath ?? baseDirectory.map { ($0 as NSString).appendingPathComponent(buf.filePath) }
        if (up > addedUp || down > addedDown), let fullPath = diskPath, let fullText = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            let allLines = fullText.components(separatedBy: "\n")
            let neededUp = up - addedUp
            if neededUp > 0 && buf.startLineNumber > 1 {
                let actualUp = min(neededUp, buf.startLineNumber - 1)
                let sliceStart = buf.startLineNumber - 1 - actualUp
                let sliceEnd = buf.startLineNumber - 1
                if sliceStart >= 0 && sliceEnd <= allLines.count && sliceStart < sliceEnd {
                    let prepended = Array(allLines[sliceStart..<sliceEnd])
                    buf.prependContextLines(prepended)
                    addedUp += prepended.count
                    excerpt.bufferRange = 0..<excerpt.bufferRange.upperBound + prepended.count
                }
            }

            let neededDown = down - addedDown
            let currentEndLine = buf.startLineNumber + buf.lineCount - 1
            if neededDown > 0 && currentEndLine < allLines.count {
                let actualDown = min(neededDown, allLines.count - currentEndLine)
                let sliceStart = currentEndLine
                let sliceEnd = currentEndLine + actualDown
                if sliceStart >= 0 && sliceEnd <= allLines.count && sliceStart < sliceEnd {
                    let appended = Array(allLines[sliceStart..<sliceEnd])
                    buf.appendContextLines(appended)
                    addedDown += appended.count
                    excerpt.bufferRange = excerpt.bufferRange.lowerBound..<buf.lineCount
                }
            }
        }

        excerpts[index] = excerpt
        mergeAdjacentExcerpts()
        version &+= 1
        return (addedUp, addedDown)
    }

    @discardableResult
    public func expandExcerptAll(at index: ExcerptIndex) -> (linesAddedUp: Int, linesAddedDown: Int) {
        guard index >= 0 && index < excerpts.count else { return (0, 0) }
        let excerpt = excerpts[index]
        guard let buf = buffers[excerpt.bufferId] else { return (0, 0) }

        let diskPath = buf.fullDiskPath ?? baseDirectory.map { ($0 as NSString).appendingPathComponent(buf.filePath) }
        if buf.isFullFile || diskPath == nil {
            return expandExcerpt(at: index, up: excerpt.bufferRange.lowerBound, down: buf.lineCount - excerpt.bufferRange.upperBound)
        } else if let fullPath = diskPath, let fullText = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            let allLines = fullText.components(separatedBy: "\n")
            let neededUp = max(0, buf.startLineNumber - 1) + excerpt.bufferRange.lowerBound
            let neededDown = max(0, allLines.count - (buf.startLineNumber + buf.lineCount - 1)) + (buf.lineCount - excerpt.bufferRange.upperBound)
            return expandExcerpt(at: index, up: neededUp, down: neededDown)
        } else {
            return expandExcerpt(at: index, up: excerpt.bufferRange.lowerBound, down: buf.lineCount - excerpt.bufferRange.upperBound)
        }
    }

    /// Merges contiguous or overlapping excerpts
    public func mergeAdjacentExcerpts() {
        guard excerpts.count > 1 else { return }
        var merged: [Excerpt] = []
        for excerpt in excerpts {
            if let last = merged.last, last.filePath == excerpt.filePath && last.bufferId == excerpt.bufferId {
                let gap = excerpt.bufferRange.lowerBound - last.bufferRange.upperBound
                if gap <= 2 {
                    var updatedLast = last
                    let combinedUpper = max(last.bufferRange.upperBound, excerpt.bufferRange.upperBound)
                    updatedLast.bufferRange = last.bufferRange.lowerBound..<combinedUpper
                    if last.hunk != nil || excerpt.hunk != nil {
                        updatedLast.hunk = nil
                    }
                    merged[merged.count - 1] = updatedLast
                    continue
                }
            }
            merged.append(excerpt)
        }
        self.excerpts = merged
    }

    @discardableResult
    public func expandExcerptAt(point: MultiBufferPoint, lines: Int = 5, direction: ExpandExcerptDirection = .upAndDown) -> (linesAddedUp: Int, linesAddedDown: Int) {
        guard let loc = location(for: point) else { return (0, 0) }
        switch direction {
        case .up:
            return expandExcerpt(at: loc.excerptIndex, up: lines, down: 0)
        case .down:
            return expandExcerpt(at: loc.excerptIndex, up: 0, down: lines)
        case .upAndDown:
            return expandExcerpt(at: loc.excerptIndex, up: lines, down: lines)
        }
    }

    public func toggleCollapse(at index: ExcerptIndex) {
        guard index >= 0 && index < excerpts.count else { return }
        let targetFilePath = excerpts[index].filePath
        let targetBufferId = excerpts[index].bufferId
        let newState = !excerpts[index].isCollapsed

        for i in 0..<excerpts.count {
            if excerpts[i].bufferId == targetBufferId || excerpts[i].filePath == targetFilePath {
                excerpts[i].isCollapsed = newState
            }
        }
        version &+= 1
    }

    public func toggleCollapse(filePath: String) {
        guard let firstIdx = excerpts.firstIndex(where: { $0.filePath == filePath }) else { return }
        toggleCollapse(at: firstIdx)
    }

    public func collapseAll() {
        for i in 0..<excerpts.count {
            excerpts[i].isCollapsed = true
        }
        version &+= 1
    }

    public func expandAll() {
        for i in 0..<excerpts.count {
            excerpts[i].isCollapsed = false
        }
        version &+= 1
    }
}
