import XCTest
import AppKit
@testable import AnyDiffCore
@testable import AnyDiffUI

final class CustomMultiBufferEditorUITests: XCTestCase {

    func testEditorUIRendersCodeIntoBitmap() throws {
        let fixture = makeEditor(text: "func greet() {\n    return \"hi\"\n}")
        let image = try render(fixture.editor)

        XCTAssertGreaterThanOrEqual(image.pixelsWide, 400)
        XCTAssertGreaterThanOrEqual(image.pixelsHigh, 240)
        let background = try XCTUnwrap(image.colorAt(x: 2, y: 2))
        XCTAssertGreaterThan(
            nonBackgroundPixelCount(in: image, rect: wholeImageRect(image), background: background),
            0,
            "The editor must draw code pixels, not only its background"
        )
    }

    func testEditorUISelectionIsRenderedAndNormalClickClearsIt() throws {
        let fixture = makeEditor(text: "a    b")
        let editor = fixture.editor

        let unselectedImage = try render(editor)
        editor.selectionAnchor = MultiBufferPoint(row: 0, column: 0)
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 6)
        editor.needsDisplay = true

        XCTAssertTrue(editor.hasSelection)
        let selectedImage = try render(editor)
        XCTAssertGreaterThan(
            differingPixelCount(between: unselectedImage, and: selectedImage, in: wholeImageRect(selectedImage)),
            0,
            "A selection must change rendered pixels"
        )

        editor.moveRight(nil)
        XCTAssertFalse(editor.hasSelection, "A normal cursor move must clear the selection")
    }

    func testEditorUIThemeChangeRepaintsBackground() throws {
        let fixture = makeEditor(text: "let value = 1", theme: .unifiedDark)
        let darkImage = try render(fixture.editor)
        fixture.editor.theme = .macOSLight
        let lightImage = try render(fixture.editor)

        XCTAssertGreaterThan(
            differingPixelCount(between: darkImage, and: lightImage, in: wholeImageRect(lightImage)),
            0,
            "Changing the theme must repaint the view"
        )
    }

    func testEditorUIMouseClickAndShiftClickUpdateSelection() throws {
        let fixture = makeEditor(text: "hello world")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow
        let lineY = try XCTUnwrap(editor.yOffset(for: row)) - editor.scrollOffsetY + editor.lineHeight / 2

        editor.mouseDown(with: try makeMouseEvent(
            for: editor,
            window: fixture.window,
            point: NSPoint(x: editor.gutterWidth + 13, y: lineY)
        ))
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: row, column: 0))
        XCTAssertFalse(editor.hasSelection)

        editor.mouseDown(with: try makeMouseEvent(
            for: editor,
            window: fixture.window,
            point: NSPoint(x: editor.gutterWidth + 160, y: lineY),
            modifierFlags: [.shift]
        ))
        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, MultiBufferPoint(row: row, column: 0))
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: row, column: 11))
    }

    func testEditorUIExpandButtonThenEditExpandedLine() throws {
        let lines = (0..<500).map { "line \($0)" }
        let filePath = "/tmp/AnyDiffUI-Expand-" + UUID().uuidString + ".swift"
        let buffer = Buffer(filePath: filePath, text: lines.joined(separator: "\n"))
        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buffer)
        multiBuffer.setExcerpts([Excerpt(
            bufferId: buffer.id,
            filePath: filePath,
            bufferRange: 383..<393,
            isFileStart: true
        )])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        editor.isEditable = true
        editor.invalidateLayout()

        let liveMode = ProcessInfo.processInfo.environment["ANYDIFF_UI_LIVE"] == "1"
        if liveMode {
            window.title = "AnyDiff UI test — expand and edit"
            window.level = .floating
            window.hidesOnDeactivate = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pumpMainRunLoop(for: 2.0)
        }

        let initialInfo = try XCTUnwrap(displayMap.codeInfo(for: displayMap.minCodeRow))
        XCTAssertEqual(initialInfo.newLineNumber, 384)
        XCTAssertEqual(initialInfo.expandInfo?.direction, .up)

        let beforeImage = try render(editor)
        let lineY = try XCTUnwrap(editor.yOffset(for: initialInfo.multiBufferRow)) - editor.scrollOffsetY + editor.lineHeight / 2
        editor.mouseDown(with: try makeMouseEvent(
            for: editor,
            window: window,
            point: NSPoint(x: 12, y: lineY)
        ))

        if liveMode {
            pumpMainRunLoop(for: 2.0)
        }

        XCTAssertEqual(multiBuffer.excerpts[0].bufferRange, 378..<393)
        let expandedInfo = try XCTUnwrap(displayMap.codeInfo(for: displayMap.minCodeRow))
        XCTAssertEqual(expandedInfo.text, "line 378")
        XCTAssertEqual(expandedInfo.newLineNumber, 379)

        editor.cursorPoint = MultiBufferPoint(row: expandedInfo.multiBufferRow, column: expandedInfo.text.count)
        editor.insertText(" // edited", replacementRange: NSRange(location: NSNotFound, length: 0))

        if liveMode {
            pumpMainRunLoop(for: 3.0)
        }

        XCTAssertEqual(buffer.line(at: 378), "line 378 // edited")
        let editedInfo = try XCTUnwrap((0..<displayMap.codeLineCount)
            .compactMap { displayMap.codeInfo(for: $0) }
            .first { $0.text == "line 378 // edited" })
        XCTAssertEqual(editedInfo.diffKind, .added)
        XCTAssertEqual(editor.cursorPoint.row, editedInfo.multiBufferRow)

        let afterImage = try render(editor)
        XCTAssertGreaterThan(
            differingPixelCount(between: beforeImage, and: afterImage, in: wholeImageRect(afterImage)),
            0,
            "Expanding and editing a line must update the rendered editor"
        )
    }

    func testEditorUIEditingChangesModelAndRenderedOutput() throws {
        let fixture = makeEditor(text: "let value = 1")
        let editor = fixture.editor
        let beforeImage = try render(editor)
        let row = fixture.displayMap.minCodeRow
        editor.cursorPoint = MultiBufferPoint(row: row, column: 13)

        editor.insertText(" // note", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "let value = 1 // note")

        let afterImage = try render(editor)
        XCTAssertGreaterThan(
            differingPixelCount(between: beforeImage, and: afterImage, in: wholeImageRect(afterImage)),
            0,
            "Editing the buffer must invalidate the rendered output"
        )
    }

    func testEditorUICommandZAndShiftZUndoRedoEdits() throws {
        let fixture = makeEditor(text: "let value = 1")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow
        let originalCursor = MultiBufferPoint(row: row, column: 13)
        editor.cursorPoint = originalCursor
        editor.insertText(" // edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "let value = 1 // edited")
        let editedCursor = editor.cursorPoint
        XCTAssertFalse(editor.hasSelection)

        let undoEvent = try makeKeyEvent(for: fixture.window, characters: "z", modifierFlags: [.command])
        XCTAssertTrue(editor.performKeyEquivalent(with: undoEvent))
        XCTAssertEqual(fixture.buffer.text(), "let value = 1")
        XCTAssertEqual(editor.cursorPoint, originalCursor)
        XCTAssertFalse(editor.hasSelection)
        XCTAssertTrue(fixture.displayMap.multiBuffer.undoManager.canRedo)

        let redoEvent = try makeKeyEvent(for: fixture.window, characters: "Z", modifierFlags: [.command, .shift])
        XCTAssertTrue(editor.performKeyEquivalent(with: redoEvent))
        XCTAssertEqual(fixture.buffer.text(), "let value = 1 // edited")
        XCTAssertEqual(editor.cursorPoint, editedCursor)
        XCTAssertFalse(editor.hasSelection)
        XCTAssertTrue(fixture.displayMap.multiBuffer.undoManager.canUndo)
    }

    func testEditorUIUndoRedoRestoresSelectionState() throws {
        let fixture = makeEditor(text: "let value = 1")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow
        let originalAnchor = MultiBufferPoint(row: row, column: 13)
        let originalCursor = MultiBufferPoint(row: row, column: 5)
        editor.selectionAnchor = originalAnchor
        editor.cursorPoint = originalCursor
        let selectedBeforeEditImage = try render(editor)

        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "let vX")
        let editedCursor = editor.cursorPoint
        XCTAssertFalse(editor.hasSelection)
        let editedImage = try render(editor)
        XCTAssertGreaterThan(
            differingPixelCount(
                between: selectedBeforeEditImage,
                and: editedImage,
                in: wholeImageRect(editedImage)
            ),
            0,
            "Replacing a selection must change the rendered editor"
        )

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "let value = 1")
        XCTAssertEqual(editor.selectionAnchor, originalAnchor)
        XCTAssertEqual(editor.cursorPoint, originalCursor)
        XCTAssertTrue(editor.hasSelection)
        let undoneImage = try render(editor)
        XCTAssertEqual(
            differingPixelCount(
                between: selectedBeforeEditImage,
                and: undoneImage,
                in: wholeImageRect(undoneImage)
            ),
            0,
            "Undo must restore the rendered text and selection"
        )

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "let vX")
        XCTAssertNil(editor.selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, editedCursor)
        XCTAssertFalse(editor.hasSelection)
        let redoneImage = try render(editor)
        XCTAssertEqual(
            differingPixelCount(
                between: editedImage,
                and: redoneImage,
                in: wholeImageRect(redoneImage)
            ),
            0,
            "Redo must restore the rendered edited state"
        )
    }

    func testEditorUIUndoRedoRestoresCursorAcrossNewlineInsertionAndDeletion() {
        let insertion = makeEditor(text: "ab\ncd")
        let insertionEditor = insertion.editor
        let insertionStart = MultiBufferPoint(row: insertion.displayMap.minCodeRow, column: 2)
        insertionEditor.cursorPoint = insertionStart

        insertionEditor.insertNewline(nil)
        XCTAssertEqual(insertion.buffer.text(), "ab\n\ncd")
        XCTAssertEqual(insertionEditor.cursorPoint, MultiBufferPoint(row: insertion.displayMap.minCodeRow + 1, column: 0))

        insertionEditor.undo(nil)
        XCTAssertEqual(insertion.buffer.text(), "ab\ncd")
        XCTAssertEqual(insertionEditor.cursorPoint, insertionStart)

        insertionEditor.redo(nil)
        XCTAssertEqual(insertion.buffer.text(), "ab\n\ncd")
        XCTAssertEqual(insertionEditor.cursorPoint, MultiBufferPoint(row: insertion.displayMap.minCodeRow + 1, column: 0))

        let deletion = makeEditor(text: "ab\ncd")
        let deletionEditor = deletion.editor
        let deletionStart = MultiBufferPoint(row: deletion.displayMap.minCodeRow + 1, column: 0)
        deletionEditor.cursorPoint = deletionStart

        deletionEditor.deleteBackward(nil)
        XCTAssertEqual(deletion.buffer.text(), "abcd")
        let deletionCursorAfterEdit = deletionEditor.cursorPoint

        deletionEditor.undo(nil)
        XCTAssertEqual(deletion.buffer.text(), "ab\ncd")
        XCTAssertEqual(deletionEditor.cursorPoint, deletionStart)

        deletionEditor.redo(nil)
        XCTAssertEqual(deletion.buffer.text(), "abcd")
        XCTAssertEqual(deletionEditor.cursorPoint, deletionCursorAfterEdit)
    }

    func testEditorUIUndoRedoRestoresSelectionAfterBackspaceDeletion() {
        let fixture = makeEditor(text: "one\ntwo\nthree")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow + 1
        let selectionAnchor = MultiBufferPoint(row: row, column: 0)
        let selectionCursor = MultiBufferPoint(row: row, column: 3)
        editor.selectionAnchor = selectionAnchor
        editor.cursorPoint = selectionCursor

        editor.deleteBackward(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\n\nthree")
        XCTAssertFalse(editor.hasSelection)
        let cursorAfterEdit = editor.cursorPoint

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\ntwo\nthree")
        XCTAssertEqual(editor.selectionAnchor, selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, selectionCursor)
        XCTAssertTrue(editor.hasSelection)

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\n\nthree")
        XCTAssertFalse(editor.hasSelection)
        XCTAssertEqual(editor.cursorPoint, cursorAfterEdit)
    }

    func testEditorUIUndoRedoRestoresSelectionAfterDeleteKey() {
        let fixture = makeEditor(text: "one\ntwo\nthree")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow + 1
        let selectionAnchor = MultiBufferPoint(row: row, column: 0)
        let selectionCursor = MultiBufferPoint(row: row, column: 3)
        editor.selectionAnchor = selectionAnchor
        editor.cursorPoint = selectionCursor

        editor.deleteForward(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\n\nthree")
        XCTAssertFalse(editor.hasSelection)
        let cursorAfterEdit = editor.cursorPoint

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\ntwo\nthree")
        XCTAssertEqual(editor.selectionAnchor, selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, selectionCursor)
        XCTAssertTrue(editor.hasSelection)

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\n\nthree")
        XCTAssertFalse(editor.hasSelection)
        XCTAssertEqual(editor.cursorPoint, cursorAfterEdit)
    }

    func testEditorUITypingCoalescesIntoOneUndoOperation() {
        let fixture = makeEditor(text: "x")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow
        editor.cursorPoint = MultiBufferPoint(row: row, column: 1)

        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "xab")
        let editedCursor = editor.cursorPoint

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "x")
        XCTAssertFalse(fixture.displayMap.multiBuffer.undoManager.canUndo)
        XCTAssertTrue(fixture.displayMap.multiBuffer.undoManager.canRedo)
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: row, column: 1))

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "xab")
        XCTAssertEqual(editor.cursorPoint, editedCursor)
    }

    func testEditorUINewEditAfterUndoClearsRedoBranch() {
        let fixture = makeEditor(text: "x")
        let editor = fixture.editor
        let row = fixture.displayMap.minCodeRow
        editor.cursorPoint = MultiBufferPoint(row: row, column: 1)

        editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "xa")

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "x")
        XCTAssertTrue(fixture.displayMap.multiBuffer.undoManager.canRedo)

        editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "xb")
        XCTAssertFalse(fixture.displayMap.multiBuffer.undoManager.canRedo)

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "x")
        XCTAssertTrue(fixture.displayMap.multiBuffer.undoManager.canRedo)

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "xb")
    }

    func testEditorUIUndoRedoUsesSharedHistoryWithoutMixingFiles() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.text)
        let fileA = Buffer(filePath: "FileA.swift", text: "A")
        let fileB = Buffer(filePath: "FileB.swift", text: "B")
        multiBuffer.addBuffer(fileA)
        multiBuffer.addBuffer(fileB)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: fileA.id, filePath: fileA.filePath, bufferRange: 0..<1, isFileStart: true),
            Excerpt(bufferId: fileB.id, filePath: fileB.filePath, bufferRange: 0..<1, isFileStart: true)
        ])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        editor.isEditable = true
        editor.invalidateLayout()

        editor.cursorPoint = MultiBufferPoint(row: 0, column: 1)
        editor.insertText("1", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fileA.text(), "A1")
        XCTAssertEqual(fileB.text(), "B")

        editor.cursorPoint = MultiBufferPoint(row: 1, column: 1)
        editor.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fileA.text(), "A1")
        XCTAssertEqual(fileB.text(), "B2")

        editor.undo(nil)
        XCTAssertEqual(fileA.text(), "A1")
        XCTAssertEqual(fileB.text(), "B")

        editor.undo(nil)
        XCTAssertEqual(fileA.text(), "A")
        XCTAssertEqual(fileB.text(), "B")

        editor.redo(nil)
        XCTAssertEqual(fileA.text(), "A1")
        XCTAssertEqual(fileB.text(), "B")

        editor.redo(nil)
        XCTAssertEqual(fileA.text(), "A1")
        XCTAssertEqual(fileB.text(), "B2")
    }

    func testEditorUIDeleteAtFileBoundariesAndEmptyLineRestoresWithUndoRedo() {
        let start = makeEditor(text: "abc")
        start.editor.cursorPoint = MultiBufferPoint(row: 0, column: 0)
        start.editor.deleteForward(nil)
        XCTAssertEqual(start.buffer.text(), "bc")
        let startCursorAfterEdit = start.editor.cursorPoint

        start.editor.undo(nil)
        XCTAssertEqual(start.buffer.text(), "abc")
        XCTAssertEqual(start.editor.cursorPoint, MultiBufferPoint(row: 0, column: 0))
        start.editor.redo(nil)
        XCTAssertEqual(start.buffer.text(), "bc")
        XCTAssertEqual(start.editor.cursorPoint, startCursorAfterEdit)

        let end = makeEditor(text: "abc")
        end.editor.cursorPoint = MultiBufferPoint(row: 0, column: 3)
        end.editor.deleteBackward(nil)
        XCTAssertEqual(end.buffer.text(), "ab")
        let endCursorAfterEdit = end.editor.cursorPoint

        end.editor.undo(nil)
        XCTAssertEqual(end.buffer.text(), "abc")
        XCTAssertEqual(end.editor.cursorPoint, MultiBufferPoint(row: 0, column: 3))
        end.editor.redo(nil)
        XCTAssertEqual(end.buffer.text(), "ab")
        XCTAssertEqual(end.editor.cursorPoint, endCursorAfterEdit)

        let emptyLine = makeEditor(text: "a\n\nb")
        emptyLine.editor.cursorPoint = MultiBufferPoint(row: 1, column: 0)
        emptyLine.editor.deleteForward(nil)
        XCTAssertEqual(emptyLine.buffer.text(), "a\nb")
        let emptyLineCursorAfterEdit = emptyLine.editor.cursorPoint

        emptyLine.editor.undo(nil)
        XCTAssertEqual(emptyLine.buffer.text(), "a\n\nb")
        XCTAssertEqual(emptyLine.editor.cursorPoint, MultiBufferPoint(row: 1, column: 0))
        emptyLine.editor.redo(nil)
        XCTAssertEqual(emptyLine.buffer.text(), "a\nb")
        XCTAssertEqual(emptyLine.editor.cursorPoint, emptyLineCursorAfterEdit)
    }

    func testEditorUIMultiLineSelectionIncludingNewlinesRestoresWithUndoRedo() {
        let fixture = makeEditor(text: "one\ntwo\nthree")
        let editor = fixture.editor
        let selectionAnchor = MultiBufferPoint(row: 0, column: 1)
        let selectionCursor = MultiBufferPoint(row: 2, column: 2)
        editor.selectionAnchor = selectionAnchor
        editor.cursorPoint = selectionCursor

        editor.deleteBackward(nil)
        XCTAssertEqual(fixture.buffer.text(), "oree")
        XCTAssertFalse(editor.hasSelection)
        let cursorAfterEdit = editor.cursorPoint

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\ntwo\nthree")
        XCTAssertEqual(editor.selectionAnchor, selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, selectionCursor)
        XCTAssertTrue(editor.hasSelection)

        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), "oree")
        XCTAssertFalse(editor.hasSelection)
        XCTAssertEqual(editor.cursorPoint, cursorAfterEdit)
    }

    func testEditorUIMultiLinePasteReplacesSelectionWithUndoRedo() {
        let fixture = makeEditor(text: "func alpha() {\n    let a = 1\n    let b = 2\n    return a + b\n}")
        let editor = fixture.editor
        editor.isEditable = true

        // Select lines 1 and 2 completely: "    let a = 1\n    let b = 2\n"
        let selectionAnchor = MultiBufferPoint(row: 1, column: 0)
        let selectionCursor = MultiBufferPoint(row: 3, column: 0)
        editor.selectionAnchor = selectionAnchor
        editor.cursorPoint = selectionCursor
        XCTAssertTrue(editor.hasSelection)

        let pastedText = "    let x = 10\n    let y = 20\n    let z = 30\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pastedText, forType: .string)

        editor.paste(nil)

        let expectedText = "func alpha() {\n    let x = 10\n    let y = 20\n    let z = 30\n    return a + b\n}"
        XCTAssertEqual(fixture.buffer.text(), expectedText)
        XCTAssertFalse(editor.hasSelection)

        // Undo must restore the original text and exact selection range
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "func alpha() {\n    let a = 1\n    let b = 2\n    return a + b\n}")
        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, selectionCursor)

        // Redo re-applies the multi-line paste
        editor.redo(nil)
        XCTAssertEqual(fixture.buffer.text(), expectedText)
        XCTAssertFalse(editor.hasSelection)
    }

    func testEditorUIMultiLineCutCopiesToPasteboardAndDeletesSelection() {
        let originalText = "func test() {\n    print(1)\n    print(2)\n    print(3)\n}"
        let fixture = makeEditor(text: originalText)
        let editor = fixture.editor
        editor.isEditable = true

        // Select rows 1 and 2 ("print(1)\n    print(2)\n    ")
        let selectionAnchor = MultiBufferPoint(row: 1, column: 4)
        let selectionCursor = MultiBufferPoint(row: 3, column: 4)
        editor.selectionAnchor = selectionAnchor
        editor.cursorPoint = selectionCursor

        editor.cut(nil)

        let cutContent = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(cutContent, "print(1)\n    print(2)\n    ")
        XCTAssertEqual(fixture.buffer.text(), "func test() {\n    print(3)\n}")
        XCTAssertFalse(editor.hasSelection)

        // Undo restores both the cut text and the original selection
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), originalText)
        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, selectionAnchor)
        XCTAssertEqual(editor.cursorPoint, selectionCursor)
    }

    func testEditorUIMultiLinePasteAtCursorExpandsBufferAndShiftsSubsequentFiles() {
        let multiBuffer = MultiBuffer()
        let buf1 = Buffer(filePath: "/tmp/FileA.swift", text: "line A1\nline A2\nline A3")
        let buf2 = Buffer(filePath: "/tmp/FileB.swift", text: "line B1\nline B2")
        multiBuffer.addBuffer(buf1)
        multiBuffer.addBuffer(buf2)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: buf1.id, filePath: "/tmp/FileA.swift", bufferRange: 0..<3, isFileStart: true),
            Excerpt(bufferId: buf2.id, filePath: "/tmp/FileB.swift", bufferRange: 0..<2, isFileStart: true)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.isEditable = true
        editor.invalidateLayout()

        // Place cursor in File A, line 2, end of line
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 7)

        let insertedText = "\nline A2.1\nline A2.2"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(insertedText, forType: .string)
        editor.paste(nil)

        // Verify File A grew by 2 lines
        XCTAssertEqual(buf1.text(), "line A1\nline A2\nline A2.1\nline A2.2\nline A3")
        XCTAssertEqual(buf1.lineCount, 5)

        // Verify File B remained intact
        XCTAssertEqual(buf2.text(), "line B1\nline B2")
        XCTAssertEqual(buf2.lineCount, 2)

        // Check that visual coordinates for File B shifted down by 2 code rows
        let fileBStartLoc = dm.visualPoint(for: buf2.id, bufferPoint: BufferPoint(row: 0, column: 0))
        XCTAssertEqual(fileBStartLoc?.row, 5, "File B code row must shift from row 3 to row 5 after 2 lines added to File A")

        // Undo must shrink File A and shift File B back
        editor.undo(nil)
        XCTAssertEqual(buf1.text(), "line A1\nline A2\nline A3")
        let fileBStartLocAfterUndo = dm.visualPoint(for: buf2.id, bufferPoint: BufferPoint(row: 0, column: 0))
        XCTAssertEqual(fileBStartLocAfterUndo?.row, 3, "File B code row must shift back to row 3 after undo")
    }

    func testEditorUIMultiLineSelectionReplacementWithSingleCharacter() {
        let fixture = makeEditor(text: "line 1\nline 2\nline 3\nline 4")
        let editor = fixture.editor
        editor.isEditable = true

        // Select from middle of line 1 to middle of line 3
        editor.selectionAnchor = MultiBufferPoint(row: 0, column: 4)
        editor.cursorPoint = MultiBufferPoint(row: 2, column: 4)

        // Type single character 'Z'
        editor.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(fixture.buffer.text(), "lineZ 3\nline 4")
        XCTAssertEqual(fixture.buffer.lineCount, 2)
        XCTAssertFalse(editor.hasSelection)

        // Undo restores the 4-line text and selection
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "line 1\nline 2\nline 3\nline 4")
        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, MultiBufferPoint(row: 0, column: 4))
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: 2, column: 4))
    }

    func testEditorUICopyPasteRoundTripPreservesIndentation() {
        let indentedCode = "    let x = 1\n\tlet y = 2\n        let z = 3"
        let fixture = makeEditor(text: indentedCode)
        let editor = fixture.editor
        editor.isEditable = true

        editor.selectAll(nil)
        editor.copy(nil)

        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied, indentedCode)

        // Move cursor to end and insert a newline, then paste
        editor.selectionAnchor = nil
        editor.cursorPoint = MultiBufferPoint(row: 2, column: 17)
        editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.paste(nil)

        XCTAssertEqual(fixture.buffer.text(), indentedCode + "\n" + indentedCode)

        // Undo reverses the paste and newline
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), indentedCode + "\n")
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), indentedCode)
    }

    func testEditorUIExternalChangeIsUndoneBeforeLocalEdit() {
        let fixture = makeEditor(text: "one\ntwo\nthree")
        let editor = fixture.editor
        fixture.buffer.isFullFile = true
        editor.cursorPoint = MultiBufferPoint(row: fixture.displayMap.minCodeRow, column: 3)
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.buffer.text(), "oneX\ntwo\nthree")

        XCTAssertTrue(fixture.displayMap.multiBuffer.applyExternalTextUpdate(
            filePath: fixture.buffer.filePath,
            newText: "oneXY\ntwo\nthreeZ"
        ))
        fixture.displayMap.rebuild()
        editor.invalidateLayout()
        XCTAssertEqual(fixture.buffer.text(), "oneXY\ntwo\nthreeZ")

        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "oneX\ntwo\nthree")
        editor.undo(nil)
        XCTAssertEqual(fixture.buffer.text(), "one\ntwo\nthree")
    }

    func testEditorUIMouseClickHeaderCollapseAndExpand() {
        let text1 = (0..<50).map { "FileA line \($0)" }.joined(separator: "\n")
        let text2 = (0..<50).map { "justfile line \($0)" }.joined(separator: "\n")

        let buf1 = Buffer(filePath: "FileA.swift", text: text1)
        let buf2 = Buffer(filePath: "justfile", text: text2)
        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buf1)
        multiBuffer.addBuffer(buf2)

        let excerpt1A = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<5, isFileStart: true)
        let excerpt1B = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 8..<15, isFileStart: false)
        let excerpt2 = Excerpt(bufferId: buf2.id, filePath: "justfile", bufferRange: 0..<10, isFileStart: true)
        multiBuffer.setExcerpts([excerpt1A, excerpt1B, excerpt2])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        multiBuffer.expandExcerpt(at: 0, up: 0, down: 5)
        displayMap.rebuild()
        editor.invalidateLayout()

        guard let headerIndex = displayMap.displayLines.firstIndex(where: {
            if case .excerptHeader(let header) = $0, header.filePath == "justfile" { return true }
            return false
        }) else {
            XCTFail("justfile header not found")
            return
        }

        let headerY = editor.yOffset(forDisplayLineIndex: headerIndex)
        let headerHeight = editor.lineHeight(forDisplayLineIndex: headerIndex)
        let point = NSPoint(x: 100, y: headerY + headerHeight / 2 - editor.scrollOffsetY)
        let windowPoint = editor.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            XCTFail("Failed to create NSEvent")
            return
        }

        editor.mouseDown(with: event)
        XCTAssertTrue(multiBuffer.excerpts.first(where: { $0.filePath == "justfile" })?.isCollapsed == true)
        XCTAssertEqual(editor.excerptLayouts.first(where: { $0.filePath == "justfile" })?.height, headerHeight)

        editor.mouseDown(with: event)
        XCTAssertTrue(multiBuffer.excerpts.first(where: { $0.filePath == "justfile" })?.isCollapsed == false)
        XCTAssertTrue((editor.excerptLayouts.first(where: { $0.filePath == "justfile" })?.height ?? 0) > headerHeight)
    }

    func testHeaderCollapseAtEndOfDocumentDoesNotBreakScrollOrDisappear() {
        let text1 = (0..<100).map { "FileA line \($0)" }.joined(separator: "\n")
        let text2 = (0..<100).map { "LastFile line \($0)" }.joined(separator: "\n")
        let buf1 = Buffer(filePath: "FileA.swift", text: text1)
        let buf2 = Buffer(filePath: "LastFile.swift", text: text2)
        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buf1)
        multiBuffer.addBuffer(buf2)

        let excerpts = [
            Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<30, isFileStart: true),
            Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 0..<10, isFileStart: true),
            Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 20..<30, isFileStart: false),
            Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 50..<60, isFileStart: false)
        ]
        multiBuffer.setExcerpts(excerpts)

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        editor.scrollToFilePath("LastFile.swift")
        XCTAssertTrue(editor.scrollOffsetY > 0)

        multiBuffer.toggleCollapse(filePath: "LastFile.swift")
        displayMap.rebuild()
        editor.invalidateLayout()

        let totalLines = displayMap.displayLineCount
        XCTAssertGreaterThan(totalLines, 0)
        let bottomLineIndex = editor.lineIndex(atY: editor.scrollOffsetY + editor.bounds.height)
        XCTAssertGreaterThanOrEqual(bottomLineIndex, totalLines - 2)
        XCTAssertLessThan(bottomLineIndex, totalLines)
        XCTAssertLessThanOrEqual(editor.lineIndex(atY: editor.scrollOffsetY), bottomLineIndex)

        editor.display()
    }

    func testAllFilesCollapsedLineIndexSafety() {
        let buffers = [
            Buffer(filePath: "A.swift", text: "line 1\nline 2"),
            Buffer(filePath: "B.swift", text: "line 1\nline 2"),
            Buffer(filePath: "C.swift", text: "line 1\nline 2")
        ]
        let multiBuffer = MultiBuffer()
        buffers.forEach { multiBuffer.addBuffer($0) }

        multiBuffer.setExcerpts([
            Excerpt(bufferId: buffers[0].id, filePath: "A.swift", bufferRange: 0..<2, isFileStart: true),
            Excerpt(bufferId: buffers[1].id, filePath: "B.swift", bufferRange: 0..<1, isFileStart: true),
            Excerpt(bufferId: buffers[1].id, filePath: "B.swift", bufferRange: 1..<2, isFileStart: false),
            Excerpt(bufferId: buffers[2].id, filePath: "C.swift", bufferRange: 0..<1, isFileStart: true),
            Excerpt(bufferId: buffers[2].id, filePath: "C.swift", bufferRange: 1..<2, isFileStart: false)
        ])
        multiBuffer.collapseAll()

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        XCTAssertEqual(displayMap.displayLineCount, 3)
        XCTAssertEqual(editor.lineIndex(atY: 0), 0)
        XCTAssertEqual(editor.lineIndex(atY: editor.excerptHeaderHeight + 5), 1)
        XCTAssertEqual(editor.lineIndex(atY: editor.totalDocumentHeight), 2)
        XCTAssertEqual(editor.lineIndex(atY: 1000), 2)
    }

    private final class EditorFixture {
        let buffer: Buffer
        let displayMap: DisplayMap
        let editor: CustomMultiBufferEditorView
        let window: NSWindow

        init(buffer: Buffer, displayMap: DisplayMap, editor: CustomMultiBufferEditorView, window: NSWindow) {
            self.buffer = buffer
            self.displayMap = displayMap
            self.editor = editor
            self.window = window
        }

    }

    private func makeEditor(
        text: String,
        filePath: String = "Test.swift",
        theme: Theme = .unifiedDark
    ) -> EditorFixture {
        let actualFilePath = filePath == "Test.swift"
            ? "/tmp/AnyDiffUI-" + UUID().uuidString + ".swift"
            : filePath
        let multiBuffer = MultiBuffer()
        let buffer = Buffer(filePath: actualFilePath, text: text)
        multiBuffer.addBuffer(buffer)
        multiBuffer.setExcerpts([Excerpt(
            bufferId: buffer.id,
            filePath: actualFilePath,
            bufferRange: 0..<buffer.lineCount,
            isFileStart: true
        )])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: theme)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        editor.invalidateLayout()
        return EditorFixture(buffer: buffer, displayMap: displayMap, editor: editor, window: window)
    }

    private func render(_ editor: CustomMultiBufferEditorView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: image)
        return image
    }

    private func pumpMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testLineRenderCacheInvalidationOnTyping() throws {
        let fixture = makeEditor(text: "line 0\nline 1\nline 2")
        let editor = fixture.editor
        _ = try render(editor)

        XCTAssertNotNil(editor.lineCache.get(lineIndex: 1), "Cache should be populated after render")

        // Type 'x' at start of line 1
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 0)
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertNil(
            editor.lineCache.get(lineIndex: 1),
            "Cache must be cleared immediately after typing"
        )

        editor.needsDisplay = true
        let imageAfter = try render(editor)
        XCTAssertNotNil(editor.lineCache.get(lineIndex: 1), "Cache repopulates on render")
        XCTAssertNotNil(imageAfter)
    }

    func testThemeChangeClearsSyntaxHighlighterAndLineRenderCache() throws {
        let fixture = makeEditor(text: "func helloWorld() -> String { return \"test\" }")
        let editor = fixture.editor
        _ = try render(editor)

        // Switch to GitHub Dark or Light theme
        editor.theme = .githubDark
        // Verify cache was cleared and will re-populate with new theme colors
        XCTAssertNil(editor.lineCache.get(lineIndex: 0))
        let imageAfterTheme = try render(editor)
        XCTAssertNotNil(imageAfterTheme)
    }

    func testFontSizeChangeClearsSyntaxHighlighterAndLineRenderCache() throws {
        let fixture = makeEditor(text: "func helloWorld() -> String { return \"test\" }")
        let editor = fixture.editor
        _ = try render(editor)

        // Change font size (zoom)
        editor.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        XCTAssertNil(editor.lineCache.get(lineIndex: 0))
        let imageAfterZoom = try render(editor)
        XCTAssertNotNil(imageAfterZoom)
    }

    func testMultiEditorLineRenderCacheIsolation() throws {
        let fixture1 = makeEditor(text: "editor 1 content")
        let fixture2 = makeEditor(text: "editor 2 content")
        let editor1 = fixture1.editor
        let editor2 = fixture2.editor

        _ = try render(editor1)
        _ = try render(editor2)

        let ctLine1 = editor1.lineCache.get(lineIndex: 1)
        let ctLine2 = editor2.lineCache.get(lineIndex: 1)

        XCTAssertNotNil(ctLine1)
        XCTAssertNotNil(ctLine2)
        XCTAssertFalse(ctLine1 === ctLine2, "Each editor instance must maintain its own independent direct line cache")

        // Mutating editor 1 should NOT invalidate editor 2 cache
        editor1.insertText("change", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(editor1.lineCache.get(lineIndex: 1))
        XCTAssertNotNil(editor2.lineCache.get(lineIndex: 1), "Editor 2 cache must remain intact when Editor 1 is edited")
    }

    private func makeMouseEvent(
        for editor: CustomMultiBufferEditorView,
        window: NSWindow,
        point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let windowPoint = editor.convert(point, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func makeKeyEvent(
        for window: NSWindow,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        ))
    }

    private func nonBackgroundPixelCount(in image: NSBitmapImageRep, rect: NSRect, background: NSColor) -> Int {
        let background = background.usingColorSpace(.deviceRGB)
        return pixels(in: image, rect: rect).reduce(into: 0) { count, point in
            guard let color = image.colorAt(x: point.x, y: point.y)?.usingColorSpace(.deviceRGB),
                  let background else { return }
            if !colorsAreEqual(color, background) {
                count += 1
            }
        }
    }

    private func wholeImageRect(_ image: NSBitmapImageRep) -> NSRect {
        NSRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
    }

    private func differingPixelCount(between lhs: NSBitmapImageRep, and rhs: NSBitmapImageRep, in rect: NSRect) -> Int {
        pixels(in: lhs, rect: rect).reduce(into: 0) { count, point in
            guard let lhsColor = lhs.colorAt(x: point.x, y: point.y)?.usingColorSpace(.deviceRGB),
                  let rhsColor = rhs.colorAt(x: point.x, y: point.y)?.usingColorSpace(.deviceRGB) else { return }
            if !colorsAreEqual(lhsColor, rhsColor) {
                count += 1
            }
        }
    }

    private func pixels(in image: NSBitmapImageRep, rect: NSRect) -> [(x: Int, y: Int)] {
        let minX = max(0, Int(rect.minX))
        let maxX = min(image.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(image.pixelsHigh, Int(rect.maxY))
        let sampleStride = 4
        return stride(from: minY, to: maxY, by: sampleStride).flatMap { y in
            stride(from: minX, to: maxX, by: sampleStride).map { x in (x: x, y: y) }
        }
    }

    private func colorsAreEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.02 &&
        abs(lhs.greenComponent - rhs.greenComponent) < 0.02 &&
        abs(lhs.blueComponent - rhs.blueComponent) < 0.02
    }
}
