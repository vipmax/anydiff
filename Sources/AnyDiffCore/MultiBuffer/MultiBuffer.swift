import Foundation

/// One or more Buffers and Excerpts composed into a unified virtual document
public final class MultiBuffer: ObservableObject, @unchecked Sendable {
    public private(set) var buffers: [BufferId: Buffer] = [:]
    public private(set) var excerpts: [Excerpt] = []
    public let undoManager: MultiBufferUndoManager

    /// Incremented on each content or excerpt change to trigger layout updates
    @Published public private(set) var version: Int = 0

    public init(undoManager: MultiBufferUndoManager = MultiBufferUndoManager()) {
        self.undoManager = undoManager
    }

    // MARK: - Buffer & Excerpt Management

    public func addBuffer(_ buffer: Buffer) {
        buffers[buffer.id] = buffer
    }

    public func buffer(for id: BufferId) -> Buffer? {
        buffers[id]
    }

    public func setExcerpts(_ newExcerpts: [Excerpt]) {
        self.excerpts = newExcerpts
        version &+= 1
    }

    public func addExcerpt(_ excerpt: Excerpt) {
        self.excerpts.append(excerpt)
        version &+= 1
    }

    public func updateExcerptBufferRange(at index: Int, range: Range<BufferRow>) {
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
            let newUpper = max(excerpt.bufferRange.lowerBound + 1, excerpt.bufferRange.upperBound + lineDelta)
            excerpt.bufferRange = excerpt.bufferRange.lowerBound..<newUpper
            excerpts[excerptIdx] = excerpt
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

        // Save directly to file on disk on every edit
        if let base = baseDirectory {
            try? buf.saveToFile(baseDirectory: base)
        }

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

    public var isDirty: Bool {
        buffers.values.contains { $0.isDirty }
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

    public func expandExcerpt(at index: ExcerptIndex, up: Int = 0, down: Int = 0) {
        guard index >= 0 && index < excerpts.count else { return }
        var excerpt = excerpts[index]
        guard let buf = buffers[excerpt.bufferId] else { return }

        if up > 0 {
            excerpt.expandUp(by: up)
        }
        if down > 0 {
            excerpt.expandDown(by: down, bufferTotalRows: buf.lineCount)
        }
        excerpts[index] = excerpt
        version &+= 1
    }

    public func expandExcerptAll(at index: ExcerptIndex) {
        guard index >= 0 && index < excerpts.count else { return }
        var excerpt = excerpts[index]
        guard let buf = buffers[excerpt.bufferId] else { return }
        excerpt.expandAll(bufferTotalRows: buf.lineCount)
        excerpts[index] = excerpt
        version &+= 1
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
