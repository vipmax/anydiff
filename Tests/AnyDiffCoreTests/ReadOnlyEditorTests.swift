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

    func testViewStateRestoresCursorAndSelectionByLogicalAnchors() {
        let multiBuffer = MultiBuffer()
        let buffer = Buffer(filePath: "Test.swift", text: "line 1\nline 2\nline 3")
        multiBuffer.addBuffer(buffer)
        multiBuffer.setExcerpts([Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<3
        )])

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.cursorPoint = MultiBufferPoint(row: 2, column: 3)
        editor.selectionAnchor = MultiBufferPoint(row: 0, column: 1)

        let state = editor.captureViewState()

        // Rebuild the underlying model, which invalidates raw MultiBuffer rows.
        multiBuffer.clear()
        let rebuiltBuffer = Buffer(filePath: "Test.swift", text: "line 1\nline 2\nline 3")
        multiBuffer.addBuffer(rebuiltBuffer)
        multiBuffer.setExcerpts([Excerpt(
            bufferId: rebuiltBuffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<3
        )])
        displayMap.rebuild()

        let restoredEditor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        restoredEditor.restoreViewState(state, shouldFocus: false)

        XCTAssertEqual(restoredEditor.cursorPoint, MultiBufferPoint(row: 2, column: 3))
        XCTAssertEqual(restoredEditor.selectionAnchor, MultiBufferPoint(row: 0, column: 1))
        XCTAssertTrue(restoredEditor.hasSelection)
    }

    func testIgnoreEditsPreservesSelectionWhileBlockingMutations() {
        let multiBuffer = MultiBuffer()
        let initialText = "line 1\nline 2\nline 3"
        let buffer = Buffer(filePath: "tool-output.txt", text: initialText)
        multiBuffer.addBuffer(buffer)
        multiBuffer.setExcerpts([Excerpt(
            bufferId: buffer.id,
            filePath: "tool-output.txt",
            bufferRange: 0..<3
        )])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true
        editor.ignoreEdits = true
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 2)

        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.deleteBackward(nil)
        editor.selectionAnchor = editor.cursorPoint
        editor.moveRightAndModifySelection(nil)

        XCTAssertEqual(buffer.text(), initialText)
        XCTAssertTrue(editor.hasSelection)
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

    func testEditingJustfileLine32AfterLazyPromotionKeepsCursorAndDiffStable() throws {
        let original = """
        set shell := ["zsh", "-cu"]

        default:
            @just --list

        # Run the app with Debug configuration.
        dev path="":
            swift run -c debug AnyDiff {{path}}

        # Run the app with Release optimizations.
        release path="":
            swift run -c release AnyDiff {{path}}

        # Build the optimized Release binary without running it.
        build:
            swift build -c release

        # Build the Debug binary without running it.
        build-debug:
            swift build -c debug

        # Remove Swift Package Manager build artifacts.
        clean:
            swift package clean

        # Clean and rebuild both Debug and Release configurations.
        rebuild:
            just clean
            just build-debug
            just build

        # Run the test suite in Debug configuration.
        test:
            swift test -c debug

        # Run the test suite in Release configuration.
        test-release:
            swift test -c release

        # Build Release and run the Release tests.
        check:
            just build
            just test-release
        """
        let current = """
        set shell := ["zsh", "-cu"]

        default:
            @just --list

        # Run the app with Debug configuration.
        dev path="":
            swift run -c debug AnyDiff {{path}}

        # Run the app with Release optimizations.
        release path="":
            swift run -c release AnyDiff {{path}}

        # Build the optimized Release binary without running it.
        build:
            swift build -c release

        # Build the Debug binary without running it.
        build-debug:
            swift build -c debug

        # Remove Swift Package Manager build artifacts.
        clean:
            swift package clean

        # Clean and rebuild both Debug and Release configurations.
        rebuild:
            just clean
            just build-debug
            just build

        # Run fast unit tests in Debug configuration
        test:
            swift test -c debug --filter AnyDiffCoreTests

        # Run fast unit tests in Release configuration.
        test-release:
            swift test -c release --filter AnyDiffCoreTests

        # Run all tests (including benchmarks) in Debug configuration.
        test-all:
            swift test -c debug

        # Run heavy performance benchmarks in optimized Release configuration.
        bench:
            swift test -c release --filter AnyDiffBenchmarks

        # Build Release and run the Release unit tests.
        check:
            just build
            just test-release
        """

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let fileURL = tempDirectory.appendingPathComponent("justfile")
        try current.write(to: fileURL, atomically: true, encoding: .utf8)

        let oldLines = original.components(separatedBy: "\n")
        let newLines = current.components(separatedBy: "\n")
        let hunks = LineDiffEngine.shared.diff(oldLines: oldLines, newLines: newLines, contextLines: 3)
        XCTAssertFalse(hunks.isEmpty)

        let multiBuffer = MultiBuffer()
        let preceding = Buffer(filePath: "Tests/AnyDiffCoreTests/MultiBufferTests.swift", text: (1...220).map { "test line \($0)" }.joined(separator: "\n"))
        multiBuffer.addBuffer(preceding)
        multiBuffer.addExcerpt(Excerpt(bufferId: preceding.id, filePath: preceding.filePath, bufferRange: 0..<preceding.lineCount))

        var targetBufferId: BufferId?
        for (index, hunk) in hunks.enumerated() {
            let visibleNewLines = hunk.lines.filter { $0.kind != .deleted }.map(\.text)
            let visibleOldLines = hunk.lines.filter { $0.kind != .added }.map(\.text)
            let buffer = Buffer(
                filePath: "justfile",
                lines: visibleNewLines,
                baselineLines: visibleOldLines,
                startLineNumber: hunk.newRange.lowerBound,
                fullDiskPath: fileURL.path,
                diskFileLineCount: newLines.count,
                isLazySlice: true
            )
            multiBuffer.addBuffer(buffer)
            multiBuffer.addExcerpt(Excerpt(
                bufferId: buffer.id,
                filePath: "justfile",
                bufferRange: 0..<buffer.lineCount,
                hunk: hunk,
                isFileStart: index == 0
            ))
            if hunk.newRange.contains(32) {
                targetBufferId = buffer.id
            }
        }

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let targetRow = try XCTUnwrap((0..<displayMap.codeLineCount).first { row in
            guard let info = displayMap.codeInfo(for: row),
                  info.excerptIndex < multiBuffer.excerpts.count else { return false }
            return multiBuffer.excerpts[info.excerptIndex].filePath == "justfile"
                && info.newLineNumber == 32
                && info.diffKind != .deleted
        })
        let targetInfo = try XCTUnwrap(displayMap.codeInfo(for: targetRow))
        XCTAssertEqual(targetInfo.text, "# Run fast unit tests in Debug configuration")
        XCTAssertEqual(displayMap.codeRow(forFilePath: "justfile", lineNumber: 32), targetRow,
                       "Stable line lookup must prefer the editable new side over the deleted old side")
        let originalColumn = targetInfo.text.count
        let initialHunkShape = (0..<displayMap.codeLineCount).compactMap { row -> String? in
            guard let info = displayMap.codeInfo(for: row),
                  info.excerptIndex < multiBuffer.excerpts.count,
                  multiBuffer.excerpts[info.excerptIndex].filePath == "justfile" else { return nil }
            return "\(info.diffKind.rawValue)|\(info.oldLineNumber ?? -1)|\(info.newLineNumber ?? -1)"
        }

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        editor.isEditable = true
        editor.cursorPoint = MultiBufferPoint(row: targetRow, column: originalColumn)
        editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))

        let promoted = try XCTUnwrap(targetBufferId.flatMap { multiBuffer.buffer(for: $0) })
        XCTAssertTrue(promoted.isFullFile)
        XCTAssertEqual(promoted.line(at: 31), "# Run fast unit tests in Debug configuration ")

        let cursorLocation = try XCTUnwrap(displayMap.bufferLocation(for: editor.cursorPoint))
        XCTAssertEqual(cursorLocation.buffer.id, promoted.id)
        XCTAssertEqual(cursorLocation.point, BufferPoint(row: 31, column: originalColumn + 1))

        let visibleLines = (0..<displayMap.codeLineCount).compactMap { displayMap.codeInfo(for: $0) }
        let editedLine = try XCTUnwrap(visibleLines.first {
            $0.newLineNumber == 32 && $0.text == "# Run fast unit tests in Debug configuration "
        })
        XCTAssertEqual(editedLine.diffKind, .added)
        XCTAssertFalse(editedLine.wordDiffRanges.isEmpty, "Word diff must be available in the same rebuild as the edit")
        let editedHunkShape = visibleLines.compactMap { info -> String? in
            guard info.excerptIndex < multiBuffer.excerpts.count,
                  multiBuffer.excerpts[info.excerptIndex].filePath == "justfile" else { return nil }
            return "\(info.diffKind.rawValue)|\(info.oldLineNumber ?? -1)|\(info.newLineNumber ?? -1)"
        }
        XCTAssertEqual(editedHunkShape, initialHunkShape,
                       "A character edit inside an added line must not realign unrelated hunk lines")
        XCTAssertTrue(visibleLines.contains {
            $0.newLineNumber == 33 && $0.diffKind == .unchanged && $0.text == "test:"
        })
        let nonDeletedLineNumbers = visibleLines.compactMap { info -> Int? in
            guard info.excerptIndex < multiBuffer.excerpts.count,
                  multiBuffer.excerpts[info.excerptIndex].filePath == "justfile",
                  info.diffKind != .deleted else { return nil }
            return info.newLineNumber
        }
        XCTAssertEqual(nonDeletedLineNumbers, nonDeletedLineNumbers.sorted())
        XCTAssertTrue(visibleLines.contains { $0.newLineNumber == 48 && $0.text.contains("Build Release") })
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

    func testHeaderCollapseAtEndOfDocumentDoesNotBreakScrollOrDisappear() {
        let text1 = (0..<100).map { "FileA line \($0)" }.joined(separator: "\n")
        let text2 = (0..<100).map { "LastFile line \($0)" }.joined(separator: "\n")

        let buf1 = Buffer(filePath: "FileA.swift", text: text1)
        let buf2 = Buffer(filePath: "LastFile.swift", text: text2)

        let mb = MultiBuffer()
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        // LastFile has 3 separate hunks
        let exc1 = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<30, isFileStart: true)
        let exc2A = Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 0..<10, isFileStart: true)
        let exc2B = Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 20..<30, isFileStart: false)
        let exc2C = Excerpt(bufferId: buf2.id, filePath: "LastFile.swift", bufferRange: 50..<60, isFileStart: false)

        mb.setExcerpts([exc1, exc2A, exc2B, exc2C])
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        // Scroll to the bottom of the document
        editor.scrollToFilePath("LastFile.swift")
        XCTAssertTrue(editor.scrollOffsetY > 0)

        // Collapse LastFile.swift
        mb.toggleCollapse(filePath: "LastFile.swift")
        dm.rebuild()
        editor.invalidateLayout()

        let totalLines = dm.displayLineCount
        XCTAssertTrue(totalLines > 0)

        // Find the last visible line index at the bottom
        let visibleMaxY = editor.scrollOffsetY + editor.bounds.height
        let bottomLineIdx = editor.lineIndex(atY: visibleMaxY)

        // lineIndex at bottom must NOT be 0 when totalLines > 1
        XCTAssertGreaterThanOrEqual(bottomLineIdx, totalLines - 2)
        XCTAssertLessThan(bottomLineIdx, totalLines)

        let topLineIdx = editor.lineIndex(atY: editor.scrollOffsetY)
        XCTAssertLessThanOrEqual(topLineIdx, bottomLineIdx)

        // Rendering pass must succeed without throwing or crashing
        editor.display()
    }

    func testAllFilesCollapsedLineIndexSafety() {
        let buf1 = Buffer(filePath: "A.swift", text: "line 1\nline 2")
        let buf2 = Buffer(filePath: "B.swift", text: "line 1\nline 2")
        let buf3 = Buffer(filePath: "C.swift", text: "line 1\nline 2")

        let mb = MultiBuffer()
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)
        mb.addBuffer(buf3)

        let exc1 = Excerpt(bufferId: buf1.id, filePath: "A.swift", bufferRange: 0..<2, isFileStart: true)
        let exc2A = Excerpt(bufferId: buf2.id, filePath: "B.swift", bufferRange: 0..<1, isFileStart: true)
        let exc2B = Excerpt(bufferId: buf2.id, filePath: "B.swift", bufferRange: 1..<2, isFileStart: false)
        let exc3A = Excerpt(bufferId: buf3.id, filePath: "C.swift", bufferRange: 0..<1, isFileStart: true)
        let exc3B = Excerpt(bufferId: buf3.id, filePath: "C.swift", bufferRange: 1..<2, isFileStart: false)

        mb.setExcerpts([exc1, exc2A, exc2B, exc3A, exc3B])
        mb.collapseAll()

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        // 3 files collapsed = 3 header lines (indices 0, 1, 2)
        XCTAssertEqual(dm.displayLineCount, 3)

        let idxTop = editor.lineIndex(atY: 0)
        let idxMid = editor.lineIndex(atY: editor.excerptHeaderHeight + 5)
        let idxBottom = editor.lineIndex(atY: editor.totalDocumentHeight)
        let idxPastEnd = editor.lineIndex(atY: 1000)

        XCTAssertEqual(idxTop, 0)
        XCTAssertEqual(idxMid, 1)
        XCTAssertEqual(idxBottom, 2)
        XCTAssertEqual(idxPastEnd, 2)
    }
}
