import Foundation
import AppKit
import AnyDiffCore

extension MultiBufferEditorView {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange, coalesceTyping: true)
    }

    func insertText(_ string: Any, replacementRange: NSRange, coalesceTyping: Bool) {
        guard editingEnabled, let displayMap = displayMap else {
            return
        }
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        let mb = displayMap.multiBuffer

        var rangeToReplace = normalizedSelectionRange() ?? (cursorPoint..<cursorPoint)
        let affectedRows = rangeToReplace.lowerBound.row..<(rangeToReplace.upperBound.row + 1)
        if displayMap.isDeleted(rowRange: affectedRows) {
            return
        }

        var promotedLazyBuffer = false
        if let initialLoc = displayMap.bufferLocation(for: rangeToReplace.lowerBound), initialLoc.buffer.isLazySlice {
            let bufId = initialLoc.buffer.id
            let fullFileRowOffset = max(0, initialLoc.buffer.startLineNumber - 1)
            let startBufferPoint = BufferPoint(
                row: fullFileRowOffset + initialLoc.point.row,
                column: initialLoc.point.column
            )
            guard let initialEndLoc = displayMap.bufferLocation(for: rangeToReplace.upperBound),
                  initialEndLoc.buffer.id == bufId else {
                return
            }
            let endBufferPoint = BufferPoint(
                row: fullFileRowOffset + initialEndLoc.point.row,
                column: initialEndLoc.point.column
            )
            mb.promoteBufferToFullFile(for: bufId)
            displayMap.rebuild()
            invalidateLayout()
            guard let newVisualStart = displayMap.visualPoint(for: bufId, bufferPoint: startBufferPoint),
                  let newVisualEnd = displayMap.visualPoint(for: bufId, bufferPoint: endBufferPoint) else {
                return
            }
            rangeToReplace = min(newVisualStart, newVisualEnd)..<max(newVisualStart, newVisualEnd)
            selectionAnchor = rangeToReplace.lowerBound != rangeToReplace.upperBound ? newVisualStart : nil
            cursorPoint = newVisualEnd
            promotedLazyBuffer = true
        }

        guard let startLoc = displayMap.bufferLocation(for: rangeToReplace.lowerBound),
              let endLoc = displayMap.bufferLocation(for: rangeToReplace.upperBound),
              !startLoc.isDeleted && !endLoc.isDeleted else {
            return
        }

        let buf = startLoc.buffer
        let oldStart = min(startLoc.point, endLoc.point)
        let oldEnd = max(startLoc.point, endLoc.point)
        let clampedStart = buf.clamp(point: oldStart)
        let clampedEnd = buf.clamp(point: oldEnd)
        let safeOldStart = min(clampedStart, clampedEnd)
        let safeOldEnd = max(clampedStart, clampedEnd)
        let oldExactText = (safeOldStart < safeOldEnd) ? buf.text(in: safeOldStart..<safeOldEnd) : ""
        let cursorBefore = cursorPoint
        let anchorBefore = selectionAnchor

        let newBufRange = buf.replace(start: safeOldStart, end: safeOldEnd, with: text)
        let lineDelta = (newBufRange.upperBound.row - safeOldEnd.row)
        updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: startLoc.excerptIndex, lineDelta: lineDelta)

        let edit = TextEdit(
            bufferId: buf.id,
            range: newBufRange,
            oldRange: safeOldStart..<safeOldEnd,
            oldText: oldExactText,
            newText: text
        )
        var transaction = EditTransaction(
            edits: [edit],
            selectionBefore: rangeToReplace,
            selectionAfter: nil,
            cursorBefore: cursorBefore,
            anchorBefore: anchorBefore,
            isTyping: coalesceTyping && !text.isEmpty && oldStart == oldEnd && anchorBefore == nil
        )

        mb.recordSelfEdit(for: buf.filePath)
        mb.scheduleDebouncedSave()

        let excerptIdx = startLoc.excerptIndex
        let newCursorPt: MultiBufferPoint
        if promotedLazyBuffer {
            // Promotion changes every excerpt for this file from slice-relative
            // coordinates to full-file coordinates. The incremental layout still
            // describes the old slices, so rebuild it atomically on the first edit.
            displayMap.rebuild()
            invalidateLayout()
            syncLayoutIfNeeded()
            if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
                newCursorPt = newVisualPt
            } else {
                newCursorPt = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
            }
        } else if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
            updateLayoutAfterExcerptRebuild(
                excerptIdx: excerptIdx,
                displayDelta: deltas.displayDelta,
                oldDisplayRange: deltas.oldDisplayRange
            )
            if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
                newCursorPt = newVisualPt
            } else {
                newCursorPt = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
            }
        } else {
            displayMap.rebuild()
            invalidateLayout()
            if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
                newCursorPt = newVisualPt
            } else {
                newCursorPt = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
            }
        }
        selectionAnchor = nil
        cursorPoint = newCursorPt
        transaction.selectionAfter = newCursorPt..<newCursorPt
        transaction.cursorAfter = newCursorPt
        transaction.anchorAfter = nil
        mb.undoManager.push(transaction: transaction)
        ensureCursorVisible()
        resetCursorBlink()
        needsDisplay = true
        notifyContentChange()
    }

    public override func deleteBackward(_ sender: Any?) {
        guard editingEnabled, let displayMap = displayMap else {
            return
        }
        let mb = displayMap.multiBuffer

        if let sel = normalizedSelectionRange() {
            let affectedRows = sel.lowerBound.row..<(sel.upperBound.row + 1)
            if displayMap.isDeleted(rowRange: affectedRows) {
                return
            }
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        if let initialLoc = displayMap.bufferLocation(for: cursorPoint), initialLoc.buffer.isLazySlice {
            let bufId = initialLoc.buffer.id
            let fullFileRowOffset = max(0, initialLoc.buffer.startLineNumber - 1)
            let startBufferPoint = BufferPoint(
                row: fullFileRowOffset + initialLoc.point.row,
                column: initialLoc.point.column
            )
            mb.promoteBufferToFullFile(for: bufId)
            displayMap.rebuild()
            invalidateLayout()
            if let newVisualPt = displayMap.visualPoint(for: bufId, bufferPoint: startBufferPoint) {
                selectionAnchor = nil
                cursorPoint = newVisualPt
            }
        }

        guard let loc = displayMap.bufferLocation(for: cursorPoint), !loc.isDeleted else {
            return
        }

        let buf = loc.buffer
        let cursorBefore = cursorPoint
        let anchorBefore = selectionAnchor

        // Clamp column to buffer's line length to handle external edits that shortened the line
        let maxCol = buf.lineLength(at: loc.point.row)
        let safeCol = max(0, min(maxCol, loc.point.column))
        let bPt = BufferPoint(row: loc.point.row, column: safeCol)

        if bPt.column > 0 {
            let start = BufferPoint(row: bPt.row, column: bPt.column - 1)
            let oldExact = buf.text(in: start..<bPt)
            let newRange = buf.replace(start: start, end: bPt, with: "")
            let lineDelta = (newRange.upperBound.row - bPt.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(
                bufferId: buf.id,
                range: newRange,
                oldRange: start..<bPt,
                oldText: oldExact,
                newText: ""
            )
            var tx = EditTransaction(
                edits: [edit],
                selectionBefore: cursorBefore..<cursorBefore,
                selectionAfter: nil,
                cursorBefore: cursorBefore,
                anchorBefore: anchorBefore
            )

            mb.recordSelfEdit(for: buf.filePath)
            mb.scheduleDebouncedSave()

            let excerptIdx = loc.excerptIndex
            let newCursorPt: MultiBufferPoint
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = MultiBufferPoint(row: cursorPoint.row, column: max(0, cursorPoint.column - 1))
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = MultiBufferPoint(row: cursorPoint.row, column: max(0, cursorPoint.column - 1))
                }
            }
            selectionAnchor = nil
            cursorPoint = newCursorPt
            tx.selectionAfter = newCursorPt..<newCursorPt
            tx.cursorAfter = newCursorPt
            tx.anchorAfter = nil
            mb.undoManager.push(transaction: tx)
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
            notifyContentChange()
        } else if bPt.row > 0 {
            let prevLen = buf.lineLength(at: bPt.row - 1)
            let start = BufferPoint(row: bPt.row - 1, column: prevLen)
            let oldExact = buf.text(in: start..<bPt)
            let newRange = buf.replace(start: start, end: bPt, with: "")
            let lineDelta = (newRange.upperBound.row - bPt.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(
                bufferId: buf.id,
                range: newRange,
                oldRange: start..<bPt,
                oldText: oldExact,
                newText: ""
            )
            var tx = EditTransaction(
                edits: [edit],
                selectionBefore: cursorBefore..<cursorBefore,
                selectionAfter: nil,
                cursorBefore: cursorBefore,
                anchorBefore: anchorBefore
            )

            mb.recordSelfEdit(for: buf.filePath)
            mb.scheduleDebouncedSave()

            let excerptIdx = loc.excerptIndex
            let newCursorPt: MultiBufferPoint
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = MultiBufferPoint(row: max(0, cursorPoint.row - 1), column: prevLen)
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = MultiBufferPoint(row: max(0, cursorPoint.row - 1), column: prevLen)
                }
            }
            selectionAnchor = nil
            cursorPoint = newCursorPt
            tx.selectionAfter = newCursorPt..<newCursorPt
            tx.cursorAfter = newCursorPt
            tx.anchorAfter = nil
            mb.undoManager.push(transaction: tx)
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
            notifyContentChange()
        }
    }

    public override func deleteForward(_ sender: Any?) {
        guard editingEnabled, let displayMap = displayMap else {
            return
        }
        let mb = displayMap.multiBuffer

        if let sel = normalizedSelectionRange() {
            let affectedRows = sel.lowerBound.row..<(sel.upperBound.row + 1)
            if displayMap.isDeleted(rowRange: affectedRows) {
                return
            }
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        if let initialLoc = displayMap.bufferLocation(for: cursorPoint), initialLoc.buffer.isLazySlice {
            let bufId = initialLoc.buffer.id
            let fullFileRowOffset = max(0, initialLoc.buffer.startLineNumber - 1)
            let startBufferPoint = BufferPoint(
                row: fullFileRowOffset + initialLoc.point.row,
                column: initialLoc.point.column
            )
            mb.promoteBufferToFullFile(for: bufId)
            displayMap.rebuild()
            invalidateLayout()
            if let newVisualPt = displayMap.visualPoint(for: bufId, bufferPoint: startBufferPoint) {
                selectionAnchor = nil
                cursorPoint = newVisualPt
            }
        }

        guard let loc = displayMap.bufferLocation(for: cursorPoint), !loc.isDeleted else {
            return
        }

        let buf = loc.buffer
        let lineLen = buf.lineLength(at: loc.point.row)
        let safeCol = max(0, min(lineLen, loc.point.column))
        let bPt = BufferPoint(row: loc.point.row, column: safeCol)
        let cursorBefore = cursorPoint
        let anchorBefore = selectionAnchor

        if bPt.column < lineLen {
            let end = BufferPoint(row: bPt.row, column: bPt.column + 1)
            let oldExact = buf.text(in: bPt..<end)
            let newRange = buf.replace(start: bPt, end: end, with: "")
            let lineDelta = (newRange.upperBound.row - end.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(
                bufferId: buf.id,
                range: newRange,
                oldRange: bPt..<end,
                oldText: oldExact,
                newText: ""
            )
            var tx = EditTransaction(
                edits: [edit],
                selectionBefore: cursorBefore..<cursorBefore,
                selectionAfter: nil,
                cursorBefore: cursorBefore,
                anchorBefore: anchorBefore
            )

            mb.recordSelfEdit(for: buf.filePath)
            mb.scheduleDebouncedSave()

            let excerptIdx = loc.excerptIndex
            let newCursorPt: MultiBufferPoint
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = cursorPoint
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = cursorPoint
                }
            }
            selectionAnchor = nil
            cursorPoint = newCursorPt
            tx.selectionAfter = newCursorPt..<newCursorPt
            tx.cursorAfter = newCursorPt
            tx.anchorAfter = nil
            mb.undoManager.push(transaction: tx)
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
            notifyContentChange()
        } else if bPt.row < buf.lineCount - 1 {
            let end = BufferPoint(row: bPt.row + 1, column: 0)
            let oldExact = buf.text(in: bPt..<end)
            let newRange = buf.replace(start: bPt, end: end, with: "")
            let lineDelta = (newRange.upperBound.row - end.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(
                bufferId: buf.id,
                range: newRange,
                oldRange: bPt..<end,
                oldText: oldExact,
                newText: ""
            )
            var tx = EditTransaction(
                edits: [edit],
                selectionBefore: cursorBefore..<cursorBefore,
                selectionAfter: nil,
                cursorBefore: cursorBefore,
                anchorBefore: anchorBefore
            )

            mb.recordSelfEdit(for: buf.filePath)
            mb.scheduleDebouncedSave()

            let excerptIdx = loc.excerptIndex
            let newCursorPt: MultiBufferPoint
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = cursorPoint
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    newCursorPt = vPt
                } else {
                    newCursorPt = cursorPoint
                }
            }
            selectionAnchor = nil
            cursorPoint = newCursorPt
            tx.selectionAfter = newCursorPt..<newCursorPt
            tx.cursorAfter = newCursorPt
            tx.anchorAfter = nil
            mb.undoManager.push(transaction: tx)
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
            notifyContentChange()
        }
    }

    func updateExcerptsAfterEdit(bufferId: BufferId, excerptIndex: Int, lineDelta: Int) {
        guard lineDelta != 0, let mb = displayMap?.multiBuffer, excerptIndex >= 0 && excerptIndex < mb.excerpts.count else { return }
        var excerpt = mb.excerpts[excerptIndex]
        let newUpper = max(excerpt.bufferRange.lowerBound, excerpt.bufferRange.upperBound + lineDelta)
        excerpt.bufferRange = excerpt.bufferRange.lowerBound..<newUpper
        mb.updateExcerptBufferRange(at: excerptIndex, range: excerpt.bufferRange)

        for i in (excerptIndex + 1)..<mb.excerpts.count {
            if mb.excerpts[i].bufferId == bufferId {
                let oldRange = mb.excerpts[i].bufferRange
                let newLower = max(newUpper, oldRange.lowerBound + lineDelta)
                let newUpperSub = max(newLower, oldRange.upperBound + lineDelta)
                mb.updateExcerptBufferRange(at: i, range: newLower..<newUpperSub)
            }
        }

        if let curB = mb.buffers[bufferId] {
            for otherBuf in mb.buffers.values where otherBuf.filePath == curB.filePath && otherBuf.id != curB.id {
                if otherBuf.startLineNumber >= curB.startLineNumber {
                    otherBuf.startLineNumber += lineDelta
                }
            }
        }
    }

    public override func insertNewline(_ sender: Any?) {
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0), coalesceTyping: false)
    }

    public override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: NSRange(location: NSNotFound, length: 0), coalesceTyping: false)
    }

    // MARK: - Undo & Redo

    @IBAction public func undo(_ sender: Any?) {
        guard editingEnabled, let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popUndo() {
            for edit in transaction.edits.reversed() {
                if let buf = mb.buffer(for: edit.bufferId) {
                    let oldEndRow = edit.range.upperBound.row
                    let newRange = buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.oldText)
                    let lineDelta = newRange.upperBound.row - oldEndRow
                    if lineDelta != 0, let excerptIdx = mb.excerpts.firstIndex(where: { $0.bufferId == edit.bufferId }) {
                        updateExcerptsAfterEdit(bufferId: edit.bufferId, excerptIndex: excerptIdx, lineDelta: lineDelta)
                    }
                }
            }
            mb.scheduleDebouncedSave()
            displayMap.rebuild()
            invalidateLayout()
            restoreSelectionState(
                cursor: transaction.cursorBefore,
                anchor: transaction.anchorBefore,
                fallback: transaction.selectionBefore
            )
            notifyContentChange()
        }
    }

    @IBAction public func redo(_ sender: Any?) {
        guard editingEnabled, let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popRedo() {
            for edit in transaction.edits {
                if let buf = mb.buffer(for: edit.bufferId) {
                    let redoRange = edit.oldRange ?? edit.range
                    let oldEndRow = redoRange.upperBound.row
                    let newRange = buf.replace(start: redoRange.lowerBound, end: redoRange.upperBound, with: edit.newText)
                    let lineDelta = newRange.upperBound.row - oldEndRow
                    if lineDelta != 0, let excerptIdx = mb.excerpts.firstIndex(where: { $0.bufferId == edit.bufferId }) {
                        updateExcerptsAfterEdit(bufferId: edit.bufferId, excerptIndex: excerptIdx, lineDelta: lineDelta)
                    }
                }
            }
            mb.scheduleDebouncedSave()
            displayMap.rebuild()
            invalidateLayout()
            restoreSelectionState(
                cursor: transaction.cursorAfter,
                anchor: transaction.anchorAfter,
                fallback: transaction.selectionAfter
            )
            notifyContentChange()
        }
    }

    func restoreSelectionState(
        cursor: MultiBufferPoint?,
        anchor: MultiBufferPoint?,
        fallback: Range<MultiBufferPoint>?
    ) {
        if let cursor {
            selectionAnchor = anchor
            cursorPoint = cursor
        } else if let fallback {
            selectionAnchor = fallback.lowerBound != fallback.upperBound ? fallback.upperBound : nil
            cursorPoint = fallback.lowerBound
        }
    }

    // MARK: - Selection & Clipboard

    func normalizedSelectionRange() -> Range<MultiBufferPoint>? {
        guard let anchor = selectionAnchor, anchor != cursorPoint else { return nil }
        return min(anchor, cursorPoint)..<max(anchor, cursorPoint)
    }

    func getSplitLeftSelectionText() -> String? {
        guard let dm = displayMap, let sel = normalizedSelectionRange(), !sel.isEmpty else { return nil }
        var copiedLines: [String] = []
        for r in sel.lowerBound.row...sel.upperBound.row {
            guard let line = dm.splitCodeInfo(for: r)?.left.text else { continue }
            let start = (r == sel.lowerBound.row) ? sel.lowerBound.column : 0
            let end = (r == sel.upperBound.row) ? sel.upperBound.column : line.count
            let clampedStart = max(0, min(line.count, start))
            let clampedEnd = max(clampedStart, min(line.count, end))
            let startIndex = line.index(line.startIndex, offsetBy: clampedStart)
            let endIndex = line.index(line.startIndex, offsetBy: clampedEnd)
            copiedLines.append(String(line[startIndex..<endIndex]))
        }
        let result = copiedLines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    public override func selectAll(_ sender: Any?) {
        guard let dm = displayMap, dm.codeLineCount > 0 else { return }
        let firstRow = dm.minCodeRow
        let lastRow = dm.maxCodeRow
        selectionAnchor = MultiBufferPoint(row: firstRow, column: 0)
        cursorPoint = MultiBufferPoint(row: lastRow, column: activeLineLength(at: lastRow))
        needsDisplay = true
        checkAndPublishSelectionQuote()
    }

    @objc @IBAction public func copy(_ sender: Any?) {
        guard let dm = displayMap else { return }
        let text: String?
        if dm.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left {
            text = getSplitLeftSelectionText()
        } else {
            text = dm.getSelectionText()
        }
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc @IBAction public func cut(_ sender: Any?) {
        if displayMap?.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left {
            copy(sender)
            return
        }
        copy(sender)
        deleteBackward(sender)
    }

    @objc @IBAction public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0), coalesceTyping: false)
    }

    // MARK: - NSTextInputClient Stubs

    public func hasMarkedText() -> Bool { false }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange, coalesceTyping: false)
    }
    public func unmarkText() {}
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}
