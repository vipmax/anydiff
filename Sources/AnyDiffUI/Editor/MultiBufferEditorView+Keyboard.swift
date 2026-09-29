import Foundation
import AppKit
import AnyDiffCore

extension MultiBufferEditorView {
    // MARK: - Word Boundary Utilities


    func isWordChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    /// Finds exact word range for double-click selection without grabbing adjacent spaces or punctuation
    func wordRange(in text: String, at index: Int) -> (start: Int, end: Int) {
        let chars = Array(text)
        guard !chars.isEmpty else { return (0, 0) }

        var targetIndex = min(index, chars.count - 1)
        if targetIndex < 0 { targetIndex = 0 }

        // If clicked at end of line / right after word char on space, adjust to the word char
        if targetIndex > 0 && index == chars.count && isWordChar(chars[targetIndex - 1]) {
            targetIndex = targetIndex - 1
        } else if targetIndex > 0 && chars[targetIndex].isWhitespace && isWordChar(chars[targetIndex - 1]) {
            targetIndex = targetIndex - 1
        }

        let char = chars[targetIndex]

        if isWordChar(char) {
            var start = targetIndex
            while start > 0 && isWordChar(chars[start - 1]) {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && isWordChar(chars[end]) {
                end += 1
            }
            return (start, end)
        } else if char.isWhitespace {
            var start = targetIndex
            while start > 0 && chars[start - 1].isWhitespace {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && chars[end].isWhitespace {
                end += 1
            }
            return (start, end)
        } else {
            // Punctuation / symbol
            var start = targetIndex
            while start > 0 && !isWordChar(chars[start - 1]) && !chars[start - 1].isWhitespace {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && !isWordChar(chars[end]) && !chars[end].isWhitespace {
                end += 1
            }
            return (start, end)
        }
    }

    func findPreviousWordBoundary(in text: String, from index: Int) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty && index > 0 else { return 0 }
        var i = min(index, chars.count)
        while i > 0 && !isWordChar(chars[i - 1]) {
            i -= 1
        }
        while i > 0 && isWordChar(chars[i - 1]) {
            i -= 1
        }
        return max(0, i)
    }

    func findNextWordBoundary(in text: String, from index: Int) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty && index < chars.count else { return text.count }
        var i = max(0, index)
        while i < chars.count && !isWordChar(chars[i]) {
            i += 1
        }
        while i < chars.count && isWordChar(chars[i]) {
            i += 1
        }
        return min(chars.count, i)
    }

    // MARK: - Keyboard & Text Input (Cocoa Standard Key Binding Responding)

    public override func keyDown(with event: NSEvent) {
        guard let displayMap = displayMap else { return }

        // Shift + Enter (Expand Excerpt around current cursor location)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            let cursorRow = cursorPoint.row
            let currentScreenY = (yOffset(for: cursorRow) ?? 0) - scrollOffsetY

            var anchor: ScrollAnchor? = nil
            if let cInfo = displayMap.codeInfo(for: cursorRow),
               cInfo.excerptIndex >= 0 && cInfo.excerptIndex < displayMap.multiBuffer.excerpts.count {
                let exc = displayMap.multiBuffer.excerpts[cInfo.excerptIndex]
                let lineNum = cInfo.newLineNumber ?? cInfo.oldLineNumber ?? ((displayMap.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + cInfo.bufferRow)
                anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
            }

            preserveCursorAndSelection {
                displayMap.multiBuffer.expandExcerptAt(point: cursorPoint, lines: 5, direction: .upAndDown)
            }

            preserveScreenPosition(ofAnchor: anchor, originalScreenY: currentScreenY)
            return
        }

        // F7 (JetBrains standard) or Cmd+F8: Go to Next/Prev Hunk
        if event.keyCode == 98 { // F7
            if event.modifierFlags.contains(.shift) {
                goToPreviousHunk()
            } else {
                goToNextHunk()
            }
            return
        }
        if event.keyCode == 100 && event.modifierFlags.contains(.command) { // Cmd+F8
            if event.modifierFlags.contains(.shift) {
                goToPreviousHunk()
            } else {
                goToNextHunk()
            }
            return
        }
        // Cmd+Option+Down / Up or Ctrl+Down / Up
        if event.keyCode == 125 && (event.modifierFlags.contains([.command, .option]) || (event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command))) {
            goToNextHunk()
            return
        }
        if event.keyCode == 126 && (event.modifierFlags.contains([.command, .option]) || (event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command))) {
            goToPreviousHunk()
            return
        }

        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        if responds(to: selector) {
            perform(selector, with: nil)
        } else {
            super.doCommand(by: selector)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 100 && event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                goToPreviousHunk()
            } else {
                goToNextHunk()
            }
            return true
        }
        if event.keyCode == 98 && !event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                goToPreviousHunk()
            } else {
                goToNextHunk()
            }
            return true
        }
        if event.modifierFlags.contains(.command) {
            let isUndoKey = event.charactersIgnoringModifiers?.lowercased() == "z"
            let hasDisallowedModifier = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control)
            if isUndoKey && !hasDisallowedModifier {
                if event.modifierFlags.contains(.shift) {
                    redo(nil)
                } else {
                    undo(nil)
                }
                return true
            }
            if event.charactersIgnoringModifiers == "s" {
                if editingEnabled {
                    _ = displayMap?.multiBuffer.flushImmediateSave()
                }
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "w" {
                if let filePath = currentFocusedFilePath() {
                    delegate?.editorDidRequestCloseFile(filePath: filePath)
                    return true
                }
            }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(cut(_:)):
            return editingEnabled && hasSelection
        case #selector(paste(_:)):
            return editingEnabled
        case #selector(selectAll(_:)):
            return (displayMap?.codeLineCount ?? 0) > 0
        case #selector(undo(_:)):
            return editingEnabled && (displayMap?.multiBuffer.undoManager.canUndo ?? false)
        case #selector(redo(_:)):
            return editingEnabled && (displayMap?.multiBuffer.undoManager.canRedo ?? false)
        case #selector(goToNextHunk(_:)), #selector(goToPreviousHunk(_:)):
            guard let dm = displayMap else { return false }
            return !dm.multiBuffer.excerpts.isEmpty
        default:
            return true
        }
    }

    // MARK: - Standard Key Binding Selectors (NSStandardKeyBindingResponding)

    @objc public override func moveLeft(_ sender: Any?) {
        moveCursorLeft(expandSelection: false)
    }

    @objc public override func moveRight(_ sender: Any?) {
        moveCursorRight(expandSelection: false)
    }

    @objc public override func moveUp(_ sender: Any?) {
        moveCursorUp(expandSelection: false)
    }

    @objc public override func moveDown(_ sender: Any?) {
        moveCursorDown(expandSelection: false)
    }

    @objc public override func moveLeftAndModifySelection(_ sender: Any?) {
        moveCursorLeft(expandSelection: true)
    }

    @objc public override func moveRightAndModifySelection(_ sender: Any?) {
        moveCursorRight(expandSelection: true)
    }

    @objc public override func moveUpAndModifySelection(_ sender: Any?) {
        moveCursorUp(expandSelection: true)
    }

    @objc public override func moveDownAndModifySelection(_ sender: Any?) {
        moveCursorDown(expandSelection: true)
    }

    @objc public override func moveWordLeft(_ sender: Any?) {
        moveCursorWordLeft(expandSelection: false)
    }

    @objc public override func moveWordRight(_ sender: Any?) {
        moveCursorWordRight(expandSelection: false)
    }

    @objc public override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveCursorWordLeft(expandSelection: true)
    }

    @objc public override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveCursorWordRight(expandSelection: true)
    }

    @objc public override func moveToBeginningOfLine(_ sender: Any?) {
        moveCursorToLineStart(expandSelection: false)
    }

    @objc public override func moveToEndOfLine(_ sender: Any?) {
        moveCursorToLineEnd(expandSelection: false)
    }

    @objc public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveCursorToLineStart(expandSelection: true)
    }

    @objc public override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveCursorToLineEnd(expandSelection: true)
    }

    @objc public override func moveToBeginningOfDocument(_ sender: Any?) {
        moveCursorToDocumentStart(expandSelection: false)
    }

    @objc public override func moveToEndOfDocument(_ sender: Any?) {
        moveCursorToDocumentEnd(expandSelection: false)
    }

    @objc public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursorToDocumentStart(expandSelection: true)
    }

    @objc public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursorToDocumentEnd(expandSelection: true)
    }

    @objc public override func pageUp(_ sender: Any?) {
        pageUpMovement(expandSelection: false)
    }

    @objc public override func pageDown(_ sender: Any?) {
        pageDownMovement(expandSelection: false)
    }

    @objc public override func pageUpAndModifySelection(_ sender: Any?) {
        pageUpMovement(expandSelection: true)
    }

    @objc public override func pageDownAndModifySelection(_ sender: Any?) {
        pageDownMovement(expandSelection: true)
    }

    @objc public override func deleteWordBackward(_ sender: Any?) {
        guard editingEnabled, displayMap != nil else { return }
        if hasSelection {
            deleteBackward(sender)
            return
        }
        let oldCursor = cursorPoint
        moveCursorWordLeft(expandSelection: false)
        let newCursor = cursorPoint
        cursorPoint = oldCursor
        let range = min(newCursor, oldCursor)..<max(newCursor, oldCursor)
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    @objc public override func deleteWordForward(_ sender: Any?) {
        guard editingEnabled, displayMap != nil else { return }
        if hasSelection {
            deleteForward(sender)
            return
        }
        let oldCursor = cursorPoint
        moveCursorWordRight(expandSelection: false)
        let newCursor = cursorPoint
        cursorPoint = oldCursor
        let range = min(oldCursor, newCursor)..<max(oldCursor, newCursor)
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    @objc public override func deleteToBeginningOfLine(_ sender: Any?) {
        guard editingEnabled else { return }
        let oldCursor = cursorPoint
        let range = MultiBufferPoint(row: oldCursor.row, column: 0)..<oldCursor
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    func moveCursorLeft(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        if targetCol > 0 {
            targetCol -= 1
        } else if let prevRow = dm.previousCodeRow(before: targetRow) {
            targetRow = prevRow
            targetCol = activeLineLength(at: prevRow)
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorRight(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        let currentLen = activeLineLength(at: targetRow)
        if targetCol < currentLen {
            targetCol += 1
        } else if let nextRow = dm.nextCodeRow(after: targetRow) {
            targetRow = nextRow
            targetCol = 0
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorUp(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        if let prevRow = dm.previousCodeRow(before: targetRow) {
            targetRow = prevRow
            targetCol = min(targetCol, activeLineLength(at: prevRow))
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorDown(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        if let nextRow = dm.nextCodeRow(after: targetRow) {
            targetRow = nextRow
            targetCol = min(targetCol, activeLineLength(at: nextRow))
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorWordLeft(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        if targetCol > 0 {
            let line = activeLineText(at: targetRow) ?? ""
            targetCol = findPreviousWordBoundary(in: line, from: targetCol)
        } else if let prevRow = dm.previousCodeRow(before: targetRow) {
            targetRow = prevRow
            targetCol = activeLineLength(at: prevRow)
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorWordRight(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        var targetRow = cursorPoint.row
        var targetCol = cursorPoint.column
        let line = activeLineText(at: targetRow) ?? ""
        if targetCol < line.count {
            targetCol = findNextWordBoundary(in: line, from: targetCol)
        } else if let nextRow = dm.nextCodeRow(after: targetRow) {
            targetRow = nextRow
            targetCol = 0
        }
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorToLineStart(expandSelection: Bool) {
        let newPoint = MultiBufferPoint(row: cursorPoint.row, column: 0)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorToLineEnd(expandSelection: Bool) {
        let newPoint = MultiBufferPoint(row: cursorPoint.row, column: activeLineLength(at: cursorPoint.row))
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorToDocumentStart(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let newPoint = MultiBufferPoint(row: dm.minCodeRow, column: 0)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func moveCursorToDocumentEnd(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let lastRow = dm.maxCodeRow
        let newPoint = MultiBufferPoint(row: lastRow, column: activeLineLength(at: lastRow))
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func pageUpMovement(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let linesPerPage = max(1, Int(bounds.height / lineHeight) - 2)
        var targetRow = cursorPoint.row
        for _ in 0..<linesPerPage {
            if let prev = dm.previousCodeRow(before: targetRow) {
                targetRow = prev
            } else {
                break
            }
        }
        let targetCol = min(cursorPoint.column, activeLineLength(at: targetRow))
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }

    func pageDownMovement(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let linesPerPage = max(1, Int(bounds.height / lineHeight) - 2)
        var targetRow = cursorPoint.row
        for _ in 0..<linesPerPage {
            if let next = dm.nextCodeRow(after: targetRow) {
                targetRow = next
            } else {
                break
            }
        }
        let targetCol = min(cursorPoint.column, activeLineLength(at: targetRow))
        let newPoint = MultiBufferPoint(row: targetRow, column: targetCol)
        if expandSelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint
            }
        } else {
            selectionAnchor = nil
        }
        cursorPoint = newPoint
    }
}
