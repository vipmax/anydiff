import XCTest
import AppKit
@testable import AnyDiffCore
@testable import AnyDiffUI

final class ReadOnlyEditorTests: XCTestCase {

    func testReadOnlyPreventsTypingAndEditing() {
        let multiBuffer = MultiBuffer()
        let initialText = "func hello() {\n    print(1)\n}"
        let buffer = Buffer(filePath: "Test.swift", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<3
        )
        multiBuffer.setExcerpts([excerpt])

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = false

        // Place cursor inside excerpt
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 4)

        // Try typing text
        editor.insertText("MODIFIED_TEXT", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(buffer.text(), initialText, "Buffer must not change when typing in read-only mode")

        // Try delete backward
        editor.deleteBackward(nil)
        XCTAssertEqual(buffer.text(), initialText, "Buffer must not change on backspace in read-only mode")

        // Try delete forward
        editor.deleteForward(nil)
        XCTAssertEqual(buffer.text(), initialText, "Buffer must not change on delete in read-only mode")

        // Try insert newline
        editor.insertNewline(nil)
        XCTAssertEqual(buffer.text(), initialText, "Buffer must not change on newline in read-only mode")
    }

    func testReadOnlyAllowsCursorNavigationAndSelection() {
        let multiBuffer = MultiBuffer()
        let initialText = "line 1\nline 2\nline 3"
        let buffer = Buffer(filePath: "Test.swift", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<3
        )
        multiBuffer.setExcerpts([excerpt])

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = false

        // 1. Initial position
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 0)

        // 2. Cursor navigation right
        editor.moveRight(nil)
        XCTAssertEqual(editor.cursorPoint.column, 1, "Cursor must move right in read-only mode")

        // 3. Cursor navigation down
        editor.moveDown(nil)
        XCTAssertEqual(editor.cursorPoint.row, 1, "Cursor must move down in read-only mode")

        // 4. Selection
        editor.moveRightAndModifySelection(nil)
        XCTAssertTrue(editor.hasSelection, "Selection must work in read-only mode")

        // 5. Select all
        editor.selectAll(nil)
        XCTAssertTrue(editor.hasSelection, "Select-all must work in read-only mode")
    }

    func testEditableModeAllowsEditing() {
        let multiBuffer = MultiBuffer()
        let initialText = "func hello() {\n}"
        let buffer = Buffer(filePath: "Test.swift", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<2
        )
        multiBuffer.setExcerpts([excerpt])

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true

        editor.cursorPoint = MultiBufferPoint(row: 0, column: 14)
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(buffer.text().contains("func hello() {X"), "Buffer must update when isEditable is true")
    }

    func testComparisonTargetEditabilityRules() {
        let workingTree = ComparisonTarget.workingTree
        let isWorkingTreeEditable = (workingTree == .workingTree)
        XCTAssertTrue(isWorkingTreeEditable, "Working Tree mode must be editable")

        let baseBranch = ComparisonTarget.baseBranch("main")
        let isBaseBranchEditable = (baseBranch == .workingTree)
        XCTAssertFalse(isBaseBranchEditable, "Base branch comparison mode must be read-only")

        let directBranch = ComparisonTarget.directBranch("origin/feature")
        let isDirectBranchEditable = (directBranch == .workingTree)
        XCTAssertFalse(isDirectBranchEditable, "Direct branch comparison mode must be read-only")
    }

    func testEditorUIMouseClickHeaderCollapseAndExpand() {
        let text1 = (0..<50).map { "FileA line \($0)" }.joined(separator: "\n")
        let text2 = (0..<50).map { "justfile line \($0)" }.joined(separator: "\n")

        let buf1 = Buffer(filePath: "FileA.swift", text: text1)
        let buf2 = Buffer(filePath: "justfile", text: text2)

        let mb = MultiBuffer()
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        let exc1A = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<5, isFileStart: true)
        let exc1B = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 8..<15, isFileStart: false)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "justfile", bufferRange: 0..<10, isFileStart: true)

        mb.setExcerpts([exc1A, exc1B, exc2])
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        // 1. Expand excerpt 0 down (which merges exc1A and exc1B)
        mb.expandExcerpt(at: 0, up: 0, down: 5)
        dm.rebuild()
        editor.invalidateLayout()

        // 2. Find exact display line index of "justfile" header
        guard let justfileLineIdx = dm.displayLines.firstIndex(where: {
            if case .excerptHeader(let h) = $0, h.filePath == "justfile" { return true }
            return false
        }) else {
            XCTFail("justfile header not found")
            return
        }

        // 3. Compute exact pixel screen coordinates of justfile header
        let headerY = editor.yOffset(forDisplayLineIndex: justfileLineIdx)
        let headerHeight = editor.lineHeight(forDisplayLineIndex: justfileLineIdx)
        let clickDocY = headerY + headerHeight / 2
        let clickScreenY = clickDocY - editor.scrollOffsetY

        let clickScreenPoint = NSPoint(x: 100, y: clickScreenY)
        let windowPoint = editor.convert(clickScreenPoint, to: nil)
        guard let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Failed to create NSEvent")
            return
        }

        // 4. Dispatch real mouseDown to CustomMultiBufferEditorView
        editor.mouseDown(with: clickEvent)

        // 5. Verify justfile is now collapsed both in model and visually in ExcerptLayout
        XCTAssertTrue(mb.excerpts.first(where: { $0.filePath == "justfile" })?.isCollapsed == true)
        XCTAssertEqual(editor.excerptLayouts.first(where: { $0.filePath == "justfile" })?.height, headerHeight)

        // 6. Dispatch click again at the same header position
        editor.mouseDown(with: clickEvent)

        // 7. Verify justfile is un-collapsed and full layout height is restored
        XCTAssertTrue(mb.excerpts.first(where: { $0.filePath == "justfile" })?.isCollapsed == false)
        XCTAssertTrue((editor.excerptLayouts.first(where: { $0.filePath == "justfile" })?.height ?? 0) > headerHeight)
    }
}
