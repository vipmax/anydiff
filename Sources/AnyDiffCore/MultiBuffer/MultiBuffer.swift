import Foundation
import Combine

/// Continuous virtual document composing multiple file diff excerpts into a single editable canvas
public final class MultiBuffer: ObservableObject, @unchecked Sendable {
    public private(set) var buffers: [BufferId: Buffer] = [:]
    public private(set) var excerpts: [Excerpt] = []
    public let undoManager: MultiBufferUndoManager

    /// Describes whether this multibuffer contains plain text or diff content.
    /// The mode is document-wide because one editor instance renders one
    /// logical document at a time.
    public private(set) var contentMode: ContentMode = .diff

    /// Monotonically increasing version counter to invalidate layout caches
    public private(set) var version: UInt64 = 0

    public init(undoManager: MultiBufferUndoManager = MultiBufferUndoManager()) {
        self.undoManager = undoManager
    }

    public func setContentMode(_ mode: ContentMode) {
        guard contentMode != mode else { return }
        contentMode = mode
        version &+= 1
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

    /// Replaces the excerpts and buffers belonging to one file while retaining
    /// the ordering and identities of every other file. Watch mode uses this
    /// to apply a filesystem refresh without rebuilding the whole document.
    public func replaceFile(filePath: String, buffers newBuffers: [Buffer], excerpts newExcerpts: [Excerpt]) {
        let oldExcerptIndices = excerpts.indices.filter { excerpts[$0].filePath == filePath }
        let insertionIndex = oldExcerptIndices.first ?? excerpts.firstIndex(where: { $0.filePath > filePath }) ?? excerpts.count
        let oldBufferIDs = Set(oldExcerptIndices.map { excerpts[$0].bufferId })

        excerpts.removeAll { $0.filePath == filePath }
        for id in oldBufferIDs {
            buffers.removeValue(forKey: id)
        }

        for buffer in newBuffers {
            buffers[buffer.id] = buffer
        }

        let clampedIndex = min(insertionIndex, excerpts.count)
        excerpts.insert(contentsOf: newExcerpts, at: clampedIndex)
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
        contentMode = .diff
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
        guard let initialStartLoc = location(for: range.lowerBound),
              let initialBuf = buffers[initialStartLoc.bufferId] else {
            return range
        }

        if initialBuf.isLazySlice {
            promoteBufferToFullFile(for: initialStartLoc.bufferId)
        }

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

            // Shift startLineNumber of all other buffers for the same file that follow this buffer
            for otherBuf in buffers.values where otherBuf.filePath == buf.filePath && otherBuf.id != buf.id {
                if otherBuf.startLineNumber >= buf.startLineNumber {
                    otherBuf.startLineNumber += lineDelta
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

        // Immediately record edit activity on this file
        recordSelfEdit(for: buf.filePath)

        // Schedule 200ms debounced auto-save to disk
        scheduleDebouncedSave(delayMs: 200)

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
    public static let autoSaveDebounceMs: Int = 200
    private var saveDebounceWorkItem: DispatchWorkItem?
    private let saveLock = NSLock()
    private var lastSavedTimestamps: [String: Date] = [:]

    public var isDirty: Bool {
        buffers.values.contains { $0.isDirty }
    }

    /// Checks if a specific file path (or directory containing it) has any dirty/unsaved buffers in memory.
    public func isFileDirty(filePath: String) -> Bool {
        let normalized = (filePath as NSString).standardizingPath
        let lastComp = (filePath as NSString).lastPathComponent
        return buffers.values.contains { buf in
            guard buf.isDirty else { return false }
            if buf.filePath == filePath || (buf.filePath as NSString).standardizingPath == normalized {
                return true
            }
            if let full = buf.fullDiskPath, (full as NSString).standardizingPath == normalized {
                return true
            }
            if (buf.filePath as NSString).lastPathComponent == lastComp {
                return true
            }
            let bufNorm = (buf.fullDiskPath.map { ($0 as NSString).standardizingPath } ?? (buf.filePath as NSString).standardizingPath)
            if bufNorm.hasPrefix(normalized) {
                return true
            }
            return false
        }
    }

    /// Records edit activity immediately upon keystroke.
    public func recordSelfEdit(for filePath: String) {
        version &+= 1
        recordSelfSave(for: filePath)
        onEdit?()
    }

    /// Records that a file was saved by AnyDiff directly.
    public func recordSelfSave(for filePath: String) {
        saveLock.lock()
        defer { saveLock.unlock() }
        let now = Date()
        lastSavedTimestamps[filePath] = now
        let normalized = (filePath as NSString).standardizingPath
        lastSavedTimestamps[normalized] = now
        if let base = baseDirectory {
            let full = (base as NSString).appendingPathComponent(filePath)
            lastSavedTimestamps[(full as NSString).standardizingPath] = now
            lastSavedTimestamps[URL(fileURLWithPath: full).resolvingSymlinksInPath().path] = now
        }
        if (filePath as NSString).isAbsolutePath {
            lastSavedTimestamps[URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path] = now
        }
    }

    /// Checks if a file (or directory containing saved files) was recently edited or saved by AnyDiff itself (default: 1.2s).
    public func isSelfSavedRecently(filePath: String, threshold: TimeInterval = 1.2) -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        let now = Date()
        let normalized = (filePath as NSString).standardizingPath
        let lastComp = (filePath as NSString).lastPathComponent

        // Clean up entries older than 30s
        let staleThreshold = now.addingTimeInterval(-30)
        lastSavedTimestamps = lastSavedTimestamps.filter { $0.value > staleThreshold }

        if let date = lastSavedTimestamps[filePath], now.timeIntervalSince(date) <= threshold {
            return true
        }
        if let date = lastSavedTimestamps[normalized], now.timeIntervalSince(date) <= threshold {
            return true
        }
        for (savedPath, date) in lastSavedTimestamps {
            if now.timeIntervalSince(date) <= threshold {
                let savedLast = (savedPath as NSString).lastPathComponent
                if savedLast == lastComp {
                    return true
                }
                // Handle atomic save temporary files (e.g. main.swift.sb-XXXXX or .main.swift.tmp)
                if lastComp.hasPrefix(savedLast) || lastComp.contains(savedLast) || savedLast.contains(lastComp) {
                    return true
                }
                if savedPath.hasPrefix(normalized) {
                    return true
                }
            }
        }
        return false
    }

    /// Exact canonical-path variant for filesystem watchers. Unlike the
    /// legacy fuzzy query above, this never matches another directory merely
    /// because its basename is equal.
    public func isSelfSavedRecentlyExact(filePath: String, threshold: TimeInterval = 1.2) -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        let now = Date()
        let candidate = canonicalSavedPath(filePath)
        let candidateURL = URL(fileURLWithPath: candidate)
        let candidateParent = candidateURL.deletingLastPathComponent().path
        let candidateName = candidateURL.lastPathComponent

        for (savedPath, date) in lastSavedTimestamps where now.timeIntervalSince(date) <= threshold {
            let saved = canonicalSavedPath(savedPath)
            if saved == candidate {
                return true
            }
            // Atomic saves can briefly surface a sibling temp path. Limit this
            // allowance to the exact same directory and filename prefix.
            let savedURL = URL(fileURLWithPath: saved)
            guard savedURL.deletingLastPathComponent().path == candidateParent else { continue }
            let savedName = savedURL.lastPathComponent
            if candidateName.hasPrefix(savedName) || candidateName.contains(savedName) || savedName.contains(candidateName) {
                return true
            }
            let rawSavedBase = (savedName as NSString).deletingPathExtension
            let rawCandidateBase = (candidateName as NSString).deletingPathExtension
            if !rawSavedBase.isEmpty && (candidateName.contains(rawSavedBase) || rawCandidateBase.contains(rawSavedBase)) {
                return true
            }
        }
        return false
    }

    private func canonicalSavedPath(_ path: String) -> String {
        let expanded: String
        if (path as NSString).isAbsolutePath {
            expanded = path
        } else if let base = baseDirectory, !base.isEmpty {
            expanded = (base as NSString).appendingPathComponent(path)
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Debounces saving all dirty buffers to disk with a 200ms delay to avoid CPU/LSP thrashing
    public func scheduleDebouncedSave(delayMs: Int = 200) {
        for buf in buffers.values where buf.isDirty {
            recordSelfSave(for: buf.filePath)
        }
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
        var savedFiles = Set<String>()
        let dirtyBuffers = buffers.values.filter(\.isDirty)
        let grouped = Dictionary(grouping: dirtyBuffers, by: \.filePath)

        for (filePath, fileBuffers) in grouped {
            // Sort in reverse order (bottom to top) so that line additions/deletions in earlier hunks do not affect later hunk offsets
            let sortedBuffers = fileBuffers.sorted { $0.startLineNumber > $1.startLineNumber }
            for buffer in sortedBuffers {
                try buffer.saveToFile(baseDirectory: baseDirectory)
            }
            recordSelfSave(for: filePath)
            savedFiles.insert(filePath)
        }
        return Array(savedFiles)
    }

    // MARK: - Lazy Buffer Promotion & Context Expansion

    /// Promotes a lazy hunk slice buffer to a full-file buffer on first edit or expand
    @discardableResult
    public func promoteBufferToFullFile(for bufferId: BufferId) -> Buffer? {
        guard let targetBuf = buffers[bufferId] else { return nil }
        guard targetBuf.isLazySlice else { return targetBuf }

        let diskPath = targetBuf.fullDiskPath ?? baseDirectory.map { ($0 as NSString).appendingPathComponent(targetBuf.filePath) }
        guard let fullPath = diskPath, let diskText = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            targetBuf.isLazySlice = false
            return targetBuf
        }

        let diskLines = diskText.components(separatedBy: "\n")

        // Find all excerpts belonging to this file to compute baseline and adjust bufferRanges
        let fileExcerpts = excerpts.enumerated().filter { $0.element.filePath == targetBuf.filePath }

        // Compute baseline by un-applying all hunks of this file to diskLines
        var baseline = diskLines
        var sortedHunks: [(hunk: DiffHunk, storage: BufferStorage)] = []
        for (_, ex) in fileExcerpts {
            if let hunk = ex.hunk, let sourceBuffer = buffers[ex.bufferId] {
                sortedHunks.append((hunk: hunk, storage: sourceBuffer.storage))
            }
        }
        sortedHunks.sort { $0.hunk.newRange.lowerBound > $1.hunk.newRange.lowerBound }

        for (hunk, sourceStorage) in sortedHunks {
            let startRow = max(0, min(baseline.count, hunk.newRange.lowerBound - 1))
            let newCount: Int
            let oldHunkLines: [String]

            if !hunk.lineSpans.isEmpty {
                newCount = hunk.lineSpans.reduce(into: 0) { count, span in
                    if span.kind != .deleted { count += 1 }
                }
                oldHunkLines = hunk.lineSpans.compactMap { span in
                    guard span.kind != .added else { return nil }
                    return sourceStorage.text(for: span) ?? ""
                }
            } else {
                newCount = hunk.lines.reduce(into: 0) { count, line in
                    if line.kind != .deleted { count += 1 }
                }
                oldHunkLines = hunk.lines.compactMap { line in
                    line.kind != .added ? line.text : nil
                }
            }

            let endRow = max(startRow, min(baseline.count, startRow + newCount))
            baseline.replaceSubrange(startRow..<endRow, with: oldHunkLines)
        }

        // A LineSpan is only meaningful with the raw storage that created it.
        // Promotion replaces that storage with mutable full-file lines, so keep
        // a compact materialized copy of each displayed hunk before removing the
        // sibling slice buffers. This also lets character edits preserve git's
        // original line alignment.
        for (idx, ex) in fileExcerpts {
            guard var hunk = ex.hunk,
                  !hunk.lineSpans.isEmpty,
                  let sourceBuffer = buffers[ex.bufferId] else { continue }
            hunk.lines = hunk.lineSpans.map { span in
                DiffLine(
                    kind: span.kind,
                    text: sourceBuffer.storage.text(for: span) ?? "",
                    oldLineNumber: span.oldLineNumber > 0 ? Int(span.oldLineNumber) : nil,
                    newLineNumber: span.newLineNumber > 0 ? Int(span.newLineNumber) : nil
                )
            }
            LineDiffEngine.shared.refreshWordDiffs(in: &hunk.lines)
            hunk.lineSpans.removeAll(keepingCapacity: false)
            excerpts[idx].hunk = hunk
        }

        let oldTargetStartLine = targetBuf.startLineNumber

        // Re-point all excerpts for this file to targetBuf with full-file ranges
        for (idx, ex) in fileExcerpts {
            var updated = ex
            let startLine: Int
            if let h = ex.hunk {
                startLine = h.newRange.lowerBound
            } else if ex.bufferId == targetBuf.id {
                startLine = oldTargetStartLine
            } else if let b = buffers[ex.bufferId] {
                startLine = b.startLineNumber
            } else {
                startLine = 1
            }

            let count = ex.bufferRange.count
            let lower = max(0, min(diskLines.count, startLine - 1))
            let upper = max(lower, min(diskLines.count, lower + count))
            updated.bufferId = targetBuf.id
            updated.bufferRange = lower..<upper
            excerpts[idx] = updated

            if ex.bufferId != targetBuf.id {
                buffers.removeValue(forKey: ex.bufferId)
            }
        }

        // Promote the target buffer to full file
        targetBuf.promoteToFullFile(diskLines: diskLines, baselineDiskLines: baseline)

        return targetBuf
    }

    /// Refreshes the editable side of the original git hunk after a character
    /// edit. Returns false when the hunk shape is no longer valid (for example,
    /// after inserting a newline), in which case DisplayMap must run a new line
    /// diff instead.
    @discardableResult
    public func refreshStableHunkPresentation(for bufferId: BufferId) -> Bool {
        guard let buffer = buffers[bufferId], buffer.isFullFile else { return false }
        let indices = excerpts.indices.filter { excerpts[$0].bufferId == bufferId }
        guard !indices.isEmpty else { return false }

        var refreshed: [(index: Int, hunk: DiffHunk)] = []
        refreshed.reserveCapacity(indices.count)

        for index in indices {
            let excerpt = excerpts[index]
            guard var hunk = excerpt.hunk, hunk.lineSpans.isEmpty else { return false }
            let editableCount = hunk.lines.reduce(into: 0) { count, line in
                if line.kind != .deleted { count += 1 }
            }
            guard editableCount == excerpt.bufferRange.count,
                  excerpt.bufferRange.lowerBound >= 0,
                  excerpt.bufferRange.upperBound <= buffer.lineCount else { return false }

            var bufferRow = excerpt.bufferRange.lowerBound
            for lineIndex in hunk.lines.indices where hunk.lines[lineIndex].kind != .deleted {
                let currentText = buffer.line(at: bufferRow) ?? ""
                // Editing context creates a new change and therefore requires a
                // fresh line diff. Existing added lines may safely retain shape.
                if hunk.lines[lineIndex].kind == .unchanged,
                   hunk.lines[lineIndex].text != currentText {
                    return false
                }
                hunk.lines[lineIndex].text = currentText
                hunk.lines[lineIndex].newLineNumber = bufferRow + 1
                bufferRow += 1
            }
            LineDiffEngine.shared.refreshWordDiffs(in: &hunk.lines)
            refreshed.append((index, hunk))
        }

        for item in refreshed {
            excerpts[item.index].hunk = item.hunk
            excerpts[item.index].stableHunkBufferVersion = buffer.version
        }
        version &+= 1
        return true
    }

    public enum ExpandExcerptDirection {
        case up
        case down
        case upAndDown
    }

    @discardableResult
    public func expandExcerpt(at index: ExcerptIndex, up: Int = 0, down: Int = 0) -> (linesAddedUp: Int, linesAddedDown: Int) {
        guard index >= 0 && index < excerpts.count else { return (0, 0) }
        let currentExcerpt = excerpts[index]
        guard let initialBuf = buffers[currentExcerpt.bufferId] else { return (0, 0) }

        let buf: Buffer
        if initialBuf.isLazySlice {
            buf = promoteBufferToFullFile(for: currentExcerpt.bufferId) ?? initialBuf
        } else {
            buf = initialBuf
        }

        var excerpt = excerpts[index]
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

        excerpts[index] = excerpt
        mergeAdjacentExcerpts()
        version &+= 1
        return (addedUp, addedDown)
    }

    @discardableResult
    public func expandExcerptAll(at index: ExcerptIndex) -> (linesAddedUp: Int, linesAddedDown: Int) {
        guard index >= 0 && index < excerpts.count else { return (0, 0) }
        let currentExcerpt = excerpts[index]
        guard let initialBuf = buffers[currentExcerpt.bufferId] else { return (0, 0) }

        let buf: Buffer
        if initialBuf.isLazySlice {
            buf = promoteBufferToFullFile(for: currentExcerpt.bufferId) ?? initialBuf
        } else {
            buf = initialBuf
        }

        let excerpt = excerpts[index]
        return expandExcerpt(at: index, up: excerpt.bufferRange.lowerBound, down: buf.lineCount - excerpt.bufferRange.upperBound)
    }

    /// Merges contiguous or overlapping excerpts
    public func mergeAdjacentExcerpts() {
        guard excerpts.count > 1 else { return }
        var merged: [Excerpt] = []
        for excerpt in excerpts {
            if let last = merged.last, last.filePath == excerpt.filePath {
                if last.bufferId == excerpt.bufferId {
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
                } else if let buf1 = buffers[last.bufferId], let buf2 = buffers[excerpt.bufferId] {
                    let endLine1 = buf1.startLineNumber + buf1.lineCount - 1
                    let startLine2 = buf2.startLineNumber
                    let gap = startLine2 - endLine1 - 1

                    if gap <= 2 {
                        let diskPath = buf1.fullDiskPath ?? baseDirectory.map { ($0 as NSString).appendingPathComponent(buf1.filePath) }
                        let diskLines = diskPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.components(separatedBy: "\n")

                        if gap > 0, let allLines = diskLines {
                            let sliceStart = endLine1
                            let sliceEnd = endLine1 + gap
                            if sliceStart >= 0 && sliceEnd <= allLines.count && sliceStart < sliceEnd {
                                let bridge = Array(allLines[sliceStart..<sliceEnd])
                                buf1.appendContextLines(bridge)
                            }
                        }

                        let newEndLine1 = buf1.startLineNumber + buf1.lineCount - 1
                        let overlap = max(0, (newEndLine1 + 1) - startLine2)
                        buf1.mergeFrom(buffer: buf2, overlap: overlap)

                        var updatedLast = last
                        updatedLast.bufferRange = 0..<buf1.lineCount
                        updatedLast.hunk = nil
                        buffers.removeValue(forKey: buf2.id)
                        merged[merged.count - 1] = updatedLast
                        continue
                    }
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
