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

    func testToggleDiffLayoutModePreservesCursorAndScrollAnchor() {
        let multiBuffer = MultiBuffer()
        let newText = "line 1\nnew line 2\nline 3\nline 4\nline 5"
        let buffer = Buffer(filePath: "Test.swift", text: newText)
        multiBuffer.addBuffer(buffer)

        let hunk = DiffHunk(
            oldRange: 1..<5,
            newRange: 1..<5,
            header: "@@ -1,4 +1,4 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "line 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .deleted, text: "deleted line 2", oldLineNumber: 2, newLineNumber: nil),
                DiffLine(kind: .added, text: "new line 2", oldLineNumber: nil, newLineNumber: 2),
                DiffLine(kind: .unchanged, text: "line 3", oldLineNumber: 3, newLineNumber: 3),
                DiffLine(kind: .unchanged, text: "line 4", oldLineNumber: 4, newLineNumber: 4),
                DiffLine(kind: .unchanged, text: "line 5", oldLineNumber: 5, newLineNumber: 5)
            ]
        )
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<5,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        )
        multiBuffer.setExcerpts([excerpt])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .unified
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        // 1. Cursor on unchanged line 4 (row 4 in unified mode: line 1, del 2, add 2, line 3, line 4)
        editor.cursorPoint = MultiBufferPoint(row: 4, column: 2)
        let unifiedState = editor.captureViewState()

        // Switch to split mode
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()
        editor.restoreViewState(unifiedState, shouldFocus: false)

        // In split mode: row 0: line 1, row 1: del 2 | add 2, row 2: line 3, row 3: line 4
        XCTAssertEqual(editor.cursorPoint.row, 3, "In split mode, line 4 should be at row 3")
        XCTAssertEqual(editor.splitActiveColumn, .right, "Unchanged line should be in right column")

        // Switch back to unified mode
        let splitState = editor.captureViewState()
        displayMap.layoutMode = .unified
        displayMap.rebuild()
        editor.restoreViewState(splitState, shouldFocus: false)

        XCTAssertEqual(editor.cursorPoint.row, 4, "In unified mode, line 4 should be back at row 4")

        // 2. Cursor on deleted line 2 (row 1 in unified mode)
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 3)
        let delUnifiedState = editor.captureViewState()

        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()
        editor.restoreViewState(delUnifiedState, shouldFocus: false)

        XCTAssertEqual(editor.cursorPoint.row, 1, "In split mode, deleted line 2 should be at row 1")
        XCTAssertEqual(editor.splitActiveColumn, .left, "Deleted line should activate left column in split mode")

        // Switch back to unified from left column
        let delSplitState = editor.captureViewState()
        displayMap.layoutMode = .unified
        displayMap.rebuild()
        editor.restoreViewState(delSplitState, shouldFocus: false)

        XCTAssertEqual(editor.cursorPoint.row, 1, "Deleted line should restore to row 1 in unified mode")
    }

    func testGutterWidthAndCodeAlignmentConsistentAcrossLayoutModes() {
        let multiBuffer = MultiBuffer()
        let newText = "alpha\nbeta\ngamma"
        let buffer = Buffer(filePath: "test.swift", text: newText)
        multiBuffer.addBuffer(buffer)

        let hunk = DiffHunk(
            oldRange: 1..<4,
            newRange: 1..<4,
            header: "@@ -1,3 +1,3 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "alpha", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .unchanged, text: "beta", oldLineNumber: 2, newLineNumber: 2),
                DiffLine(kind: .unchanged, text: "gamma", oldLineNumber: 3, newLineNumber: 3)
            ]
        )
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "test.swift",
            bufferRange: 0..<3,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        )
        multiBuffer.setExcerpts([excerpt])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .unified
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        editor.invalidateLayout()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = editor

        // 1. Unified mode: click right at first character of code (gutterWidth + 13)
        let row0Y = editor.yOffset(forDisplayLineIndex: 1)
        let clickX = editor.gutterWidth + 13
        let unifiedEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: editor.convert(CGPoint(x: clickX, y: row0Y + 5), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        editor.mouseDown(with: unifiedEvent)
        XCTAssertEqual(editor.cursorPoint.column, 0, "First code character should be at column 0 in unified mode")

        // 2. Switch to Split mode: gutter width and code start must be identical
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()
        editor.invalidateLayout()

        let splitRow0Y = editor.yOffset(forDisplayLineIndex: 1)
        let splitEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: editor.convert(CGPoint(x: clickX, y: splitRow0Y + 5), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        editor.mouseDown(with: splitEvent)
        XCTAssertEqual(editor.splitActiveColumn, .left, "Click should land on left column")
        XCTAssertEqual(editor.cursorPoint.column, 0, "First code character should be at column 0 in split mode at the exact same X coordinate")
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

    func testCursorJumpOnTypingInExpandedExcerpt() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("anydiff_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a 50-line file on disk
        let diskLines = (1...50).map { "line \($0) content" }
        let fileURL = tempDir.appendingPathComponent("SampleFile.swift")
        try diskLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        // Diff modifies lines 9..12
        let diffText = """
        diff --git a/SampleFile.swift b/SampleFile.swift
        --- a/SampleFile.swift
        +++ b/SampleFile.swift
        @@ -9,4 +9,4 @@
         line 9 content
        -line 10 content
        -line 11 content
        +line 10 modified
        +line 10.5 addition
         line 12 content
        """
        let diffData = Data(diffText.utf8)
        let parsed = GitDiffParser.shared.parseZeroCopy(data: diffData)
        let file = try XCTUnwrap(parsed.first)
        let hunk = try XCTUnwrap(file.hunks.first)

        let mb = MultiBuffer()
        mb.baseDirectory = tempDir.path
        let buf = Buffer(
            filePath: file.displayPath,
            storage: .makeDiffFlat(data: diffData, spans: hunk.lineSpans, side: .new),
            startLineNumber: hunk.newRange.lowerBound,
            fullDiskPath: fileURL.path,
            diskFileLineCount: diskLines.count,
            isLazySlice: true
        )
        mb.addBuffer(buf)
        let ex = Excerpt(
            bufferId: buf.id,
            filePath: file.displayPath,
            bufferRange: 0..<buf.lineCount,
            hunk: hunk
        )
        mb.addExcerpt(ex)

        // Expand excerpt down by 15 lines so line 20 is included
        mb.expandExcerpt(at: 0, up: 0, down: 15)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        dm.rebuild()

        let expandedBuf = try XCTUnwrap(mb.buffer(for: mb.excerpts[0].bufferId))
        XCTAssertTrue(expandedBuf.isFullFile)

        // Target line 20 (row 19 in 0-based buffer)
        let targetRow = 19
        let visualPtBefore = try XCTUnwrap(dm.visualPoint(for: expandedBuf.id, bufferPoint: BufferPoint(row: targetRow, column: 0)))
        let codeInfoBefore = try XCTUnwrap(dm.codeInfo(for: visualPtBefore.row))
        XCTAssertEqual(codeInfoBefore.newLineNumber, 20)

        // Type "123" into buffer at row 19
        _ = expandedBuf.replace(start: BufferPoint(row: targetRow, column: 4), end: BufferPoint(row: targetRow, column: 4), with: "123")

        let targetExcerptIdx = codeInfoBefore.excerptIndex
        let deltas = dm.rebuildExcerpt(at: targetExcerptIdx)
        XCTAssertNotNil(deltas)

        let visualPtAfter = try XCTUnwrap(dm.visualPoint(for: expandedBuf.id, bufferPoint: BufferPoint(row: targetRow, column: 7)))
        let codeInfoAfter = try XCTUnwrap(dm.codeInfo(for: visualPtAfter.row))
        XCTAssertEqual(codeInfoAfter.newLineNumber, 20, "Cursor must stay on line 20 after typing in expanded excerpt")
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

    func testTypingAndNavigationDoNotCreatePhantomSelections() {
        let multiBuffer = MultiBuffer()
        let initialText = "12343"
        let buffer = Buffer(filePath: "text.txt", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "text.txt",
            bufferRange: 0..<1
        )
        multiBuffer.setExcerpts([excerpt])

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 5)
        editor.selectionAnchor = nil

        var capturedStates: [EditorViewState] = []
        final class TestCoordinator: NSObject, CustomMultiBufferEditorDelegate {
            var onCursor: (() -> Void)?
            func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint) {
                onCursor?()
            }
            func editorDidRequestAddComment(filePath: String, lineNumber: Int) {}
            func editorDidScroll() {}
        }
        let coordinator = TestCoordinator()
        coordinator.onCursor = {
            capturedStates.append(editor.captureViewState())
        }
        editor.delegate = coordinator

        // 1. Type character '4'
        editor.insertText("4", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(editor.hasSelection, "Editor must not have selection immediately after typing")
        XCTAssertEqual(buffer.text(), "123434")

        for (index, state) in capturedStates.enumerated() {
            XCTAssertNil(state.selectionAnchor, "Captured state #\(index) during cursor notification must not contain a phantom selection anchor")
        }

        // 2. Simulate diff reload / debounce save restoring the saved view state
        if let lastState = capturedStates.last {
            editor.restoreViewState(lastState, shouldFocus: false)
        }
        XCTAssertFalse(editor.hasSelection, "Restoring view state after typing must not create a selection")

        // 3. Type character '5' - must append, NOT overwrite previous character
        editor.insertText("5", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(buffer.text(), "1234345", "Subsequent typing must append instead of overwriting previous character")
        XCTAssertFalse(editor.hasSelection)

        // 4. Arrow key navigation without Shift must not create selection or phantom anchors
        capturedStates.removeAll()
        editor.moveLeft(nil)
        XCTAssertFalse(editor.hasSelection)
        for (index, state) in capturedStates.enumerated() {
            XCTAssertNil(state.selectionAnchor, "State #\(index) captured during moveLeft must not have phantom selection")
        }
        if let lastState = capturedStates.last {
            editor.restoreViewState(lastState, shouldFocus: false)
        }
        XCTAssertFalse(editor.hasSelection)
    }

    func testExplicitShiftSelectionIsProperlyCapturedAndRestored() {
        let multiBuffer = MultiBuffer()
        let initialText = "hello world"
        let buffer = Buffer(filePath: "test.txt", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "test.txt",
            bufferRange: 0..<1
        )
        multiBuffer.setExcerpts([excerpt])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 0)

        // Expand selection by 5 characters (selecting "hello")
        for _ in 0..<5 {
            editor.moveRightAndModifySelection(nil)
        }

        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, MultiBufferPoint(row: 0, column: 0))
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: 0, column: 5))

        let captured = editor.captureViewState()
        XCTAssertNotNil(captured.selectionAnchor)
        XCTAssertEqual(captured.selectionAnchor?.column, 0)
        XCTAssertEqual(captured.cursorAnchor?.column, 5)

        // Restore view state
        editor.restoreViewState(captured, shouldFocus: false)
        XCTAssertTrue(editor.hasSelection)
        XCTAssertEqual(editor.selectionAnchor, MultiBufferPoint(row: 0, column: 0))
        XCTAssertEqual(editor.cursorPoint, MultiBufferPoint(row: 0, column: 5))
    }

    func testFastSourceLocationAndScrollAnchorAcrossMultipleFiles() {
        let multiBuffer = MultiBuffer()
        let buf1 = Buffer(filePath: "FileA.swift", text: "aaa\nbbb\nccc")
        let buf2 = Buffer(filePath: "FileB.swift", text: "111\n222\n333")
        multiBuffer.addBuffer(buf1)
        multiBuffer.addBuffer(buf2)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<3),
            Excerpt(bufferId: buf2.id, filePath: "FileB.swift", bufferRange: 0..<3)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        // Test FileA locations
        let loc0 = dm.fastSourceLocation(forCodeRow: 0)
        XCTAssertEqual(loc0?.filePath, "FileA.swift")
        XCTAssertEqual(loc0?.lineNumber, 1)

        let loc2 = dm.fastSourceLocation(forCodeRow: 2)
        XCTAssertEqual(loc2?.filePath, "FileA.swift")
        XCTAssertEqual(loc2?.lineNumber, 3)

        // Test FileB locations
        let loc3 = dm.fastSourceLocation(forCodeRow: 3)
        XCTAssertEqual(loc3?.filePath, "FileB.swift")
        XCTAssertEqual(loc3?.lineNumber, 1)

        let loc5 = dm.fastSourceLocation(forCodeRow: 5)
        XCTAssertEqual(loc5?.filePath, "FileB.swift")
        XCTAssertEqual(loc5?.lineNumber, 3)

        // Test scroll anchors (headers and code lines)
        let headerAnchor = dm.fastScrollAnchor(forDisplayLineIndex: 0)
        XCTAssertEqual(headerAnchor?.filePath, "FileA.swift")
        XCTAssertTrue(headerAnchor?.isHeader == true)

        let codeAnchor = dm.fastScrollAnchor(forDisplayLineIndex: 1)
        XCTAssertEqual(codeAnchor?.filePath, "FileA.swift")
        XCTAssertEqual(codeAnchor?.lineNumber, 1)
        XCTAssertFalse(codeAnchor?.isHeader == true)
    }

    func testDeleteBackwardWithCursorBeyondShortenedLineDoesNotCrash() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.text)
        let initialText = "hello test"
        let buffer = Buffer(filePath: "Test.swift", text: initialText)
        multiBuffer.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<1
        )
        multiBuffer.setExcerpts([excerpt])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true

        // Place cursor at the end: "hello test|" (col 10)
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 10)

        // Simulate external edit that truncated the line to "hello"
        _ = buffer.replace(start: BufferPoint(row: 0, column: 5), end: BufferPoint(row: 0, column: 10), with: "")
        // In the editor, cursor was still at column 10 before backspace
        // This used to crash with Fatal error: Range requires lowerBound <= upperBound
        editor.deleteBackward(nil)

        // Should successfully delete the last character 'o' without crashing
        XCTAssertEqual(buffer.text(), "hell")

        // Also test deleteForward when cursor is past line length
        editor.cursorPoint = MultiBufferPoint(row: 0, column: 20)
        editor.deleteForward(nil)
        // Should not crash
        XCTAssertEqual(buffer.text(), "hell")
    }

    func testSplitModeLeftColumnSelectionAndCopying() {
        let multiBuffer = MultiBuffer()
        let newText = "line 1\nnew line\nline 3"
        let buffer = Buffer(filePath: "Test.swift", text: newText)
        multiBuffer.addBuffer(buffer)

        let hunk = DiffHunk(
            oldRange: 1..<4,
            newRange: 1..<4,
            header: "@@ -1,3 +1,3 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "line 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .deleted, text: "old line", oldLineNumber: 2, newLineNumber: nil),
                DiffLine(kind: .added, text: "new line", oldLineNumber: nil, newLineNumber: 2),
                DiffLine(kind: .unchanged, text: "line 3", oldLineNumber: 3, newLineNumber: 3)
            ]
        )
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Test.swift",
            bufferRange: 0..<3,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        )
        multiBuffer.setExcerpts([excerpt])

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        editor.splitRatio = 0.5
        editor.invalidateLayout()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = editor

        XCTAssertEqual(editor.splitActiveColumn, .right)

        // In split mode, line 0 is header, line 1 is line 1, line 2 is old line / new line
        // Click in left column code rect
        let row2Y = editor.yOffset(forDisplayLineIndex: 2)
        let viewPoint = CGPoint(x: 150, y: row2Y + 5)
        let windowPoint = editor.convert(viewPoint, to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!

        editor.mouseDown(with: event)
        XCTAssertEqual(editor.splitActiveColumn, .left)

        // Verify editing in left column is blocked
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(buffer.text(), newText, "Buffer must not change when typing in left column of split view")

        // Select "old" in "old line" (row 1 in code rows)
        editor.selectionAnchor = MultiBufferPoint(row: 1, column: 0)
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 3)

        editor.copy(nil)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, "old", "Copy in left split column should extract text from old/deleted line")

        // Click in right column code rect
        let rightViewPoint = CGPoint(x: 550, y: row2Y + 5)
        let rightWindowPoint = editor.convert(rightViewPoint, to: nil)
        let rightEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: rightWindowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        editor.mouseDown(with: rightEvent)
        XCTAssertEqual(editor.splitActiveColumn, .right)

        // Verify copy in right column extracts from new line
        editor.selectionAnchor = MultiBufferPoint(row: 1, column: 0)
        editor.cursorPoint = MultiBufferPoint(row: 1, column: 3)
        editor.copy(nil)
        let pastedRight = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pastedRight, "new", "Copy in right split column should extract text from new/added line")
    }

    func testInsertNewlineInSplitModePreservesCursorPosition() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let hunk = DiffHunk(
            oldRange: 120..<130,
            newRange: 150..<165,
            header: "@@ -120,10 +150,15 @@",
            lines: [
                DiffLine(kind: .deleted, text: "del 1", oldLineNumber: 122, newLineNumber: nil),
                DiffLine(kind: .deleted, text: "del 2", oldLineNumber: 123, newLineNumber: nil),
                DiffLine(kind: .added, text: "add 1", oldLineNumber: nil, newLineNumber: 155),
                DiffLine(kind: .added, text: "add 2", oldLineNumber: nil, newLineNumber: 156),
                DiffLine(kind: .added, text: "add 3", oldLineNumber: nil, newLineNumber: 157),
                DiffLine(kind: .added, text: "add 4", oldLineNumber: nil, newLineNumber: 158),
                DiffLine(kind: .added, text: "add 5", oldLineNumber: nil, newLineNumber: 159),
                DiffLine(kind: .added, text: "add 6", oldLineNumber: nil, newLineNumber: 160),
                DiffLine(kind: .added, text: "add 7", oldLineNumber: nil, newLineNumber: 161),
                DiffLine(kind: .unchanged, text: "    }", oldLineNumber: 124, newLineNumber: 162),
                DiffLine(kind: .unchanged, text: "", oldLineNumber: 125, newLineNumber: 163),
            ]
        )

        let initialText = "add 1\nadd 2\nadd 3\nadd 4\nadd 5\nadd 6\nadd 7\n    }\n"
        let buffer = Buffer(filePath: "DisplayLine.swift", text: initialText)
        buffer.isFullFile = true
        buffer.startLineNumber = 155
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "DisplayLine.swift",
            fileStatus: .modified,
            bufferRange: 0..<9,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true

        // Place cursor on line 163 (row 8)
        editor.cursorPoint = MultiBufferPoint(row: 8, column: 0)

        // Press Enter
        editor.insertNewline(nil)

        // After Enter, cursor should be on the newly inserted line (row 9, column 0)
        XCTAssertEqual(editor.cursorPoint.row, 9, "Cursor should move to row 9 after inserting newline")
        XCTAssertEqual(editor.cursorPoint.column, 0)

        // Capture view state
        let state = editor.captureViewState()
        XCTAssertEqual(state.cursorAnchor?.lineNumber, 164, "Cursor anchor must capture new line number 164, not 162")

        // Restore view state
        editor.restoreViewState(state, shouldFocus: false)
        XCTAssertEqual(editor.cursorPoint.row, 9, "Cursor should remain on row 9 after restoring view state")
    }

    func testTypingAndDeletingCharactersMaintainsFastStableHunkPresentation() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let initialText = "line 1\nline 2\nline 3\n"
        let buffer = Buffer(filePath: "File.swift", text: initialText)
        buffer.isFullFile = true
        buffer.startLineNumber = 1
        multiBuffer.addBuffer(buffer)

        let hunk = DiffHunk(
            oldRange: 1..<3,
            newRange: 1..<4,
            header: "@@ -1,2 +1,3 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "line 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .added, text: "line 2", oldLineNumber: nil, newLineNumber: 2),
                DiffLine(kind: .unchanged, text: "line 3", oldLineNumber: 2, newLineNumber: 3),
            ]
        )

        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "File.swift",
            fileStatus: .modified,
            bufferRange: 0..<3,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true

        // Position cursor at row 1 (the added line "line 2"), end of line (col 6)
        // Note: header is at display row 0, so code row 1 is display code row 1
        guard let visualPt = displayMap.visualPoint(for: buffer.id, bufferPoint: BufferPoint(row: 1, column: 6)) else {
            XCTFail("Could not get visual point")
            return
        }
        editor.cursorPoint = visualPt

        // 1. Type "999"
        editor.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version, "Typing into added line must keep stableHunkBufferVersion up to date")
        XCTAssertEqual(buffer.line(at: 1), "line 29")

        editor.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version)
        XCTAssertEqual(buffer.line(at: 1), "line 299")

        // 2. Backspace
        editor.deleteBackward(nil)
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version, "deleteBackward must keep stableHunkBufferVersion up to date for fast deletion")
        XCTAssertEqual(buffer.line(at: 1), "line 29")

        editor.deleteBackward(nil)
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version, "Subsequent deleteBackward must remain on fast path")
        XCTAssertEqual(buffer.line(at: 1), "line 2")
    }

    func testTypeAndImmediatelyDeleteCharacterOnLargeFile() {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fileURL = repoRoot.appendingPathComponent("Sources/AnyDiffUI/Editor/CustomMultiBufferEditorView.swift")
        guard let currentText = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let buffer = Buffer(filePath: fileURL.path, text: currentText)
        buffer.isFullFile = true
        buffer.startLineNumber = 1
        multiBuffer.addBuffer(buffer)

        let lines = currentText.components(separatedBy: "\n")
        let testRow = 2691 // Line 2692 (0-indexed 2691)
        let hunkLines = (2680..<2705).map { r in
            DiffLine(kind: .unchanged, text: lines[r], oldLineNumber: r + 1, newLineNumber: r + 1)
        }
        let hunk = DiffHunk(
            oldRange: 2681..<2706,
            newRange: 2681..<2706,
            header: "@@ -2681,25 +2681,25 @@",
            lines: hunkLines
        )
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: fileURL.path,
            fileStatus: .modified,
            bufferRange: 2680..<2705,
            hunk: hunk,
            stableHunkBufferVersion: buffer.version
        ))

        // Also add a sibling excerpt to ensure editing excerpt 0 does not invalidate sibling excerpt 1
        let siblingLines = (100..<120).map { r in
            DiffLine(kind: .unchanged, text: lines[r], oldLineNumber: r + 1, newLineNumber: r + 1)
        }
        let siblingHunk = DiffHunk(
            oldRange: 101..<121,
            newRange: 101..<121,
            header: "@@ -101,20 +101,20 @@",
            lines: siblingLines
        )
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: fileURL.path,
            fileStatus: .modified,
            bufferRange: 100..<120,
            hunk: siblingHunk,
            stableHunkBufferVersion: buffer.version
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: .unifiedDark)
        editor.isEditable = true

        guard let visualPt = displayMap.visualPoint(for: buffer.id, bufferPoint: BufferPoint(row: testRow, column: 4)) else {
            XCTFail("Could not get visual point")
            return
        }
        editor.cursorPoint = visualPt

        // Measure typing 1 char on unchanged line (now executes in-place in microseconds!)
        let t0 = CFAbsoluteTimeGetCurrent()
        editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        let tInsert = CFAbsoluteTimeGetCurrent() - t0

        // After insert on unchanged line:
        // Excerpt 0 must have split the line into .deleted (original) and .added ("X" inserted) in-place
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version, "In-place split on unchanged line must keep stable version")
        let hunk0AfterInsert = multiBuffer.excerpts[0].hunk!
        XCTAssertTrue(hunk0AfterInsert.lines.contains { $0.kind == .deleted }, "Hunk must have deleted line for original")
        XCTAssertTrue(hunk0AfterInsert.lines.contains { $0.kind == .added }, "Hunk must have added line for edited")

        // Sibling excerpt 1 must remain on fast path (stable and uninvalidated)
        XCTAssertTrue(displayMap.usesOriginalHunk(excerpt: multiBuffer.excerpts[1], buffer: buffer), "Sibling excerpt must remain valid on fast path")

        // Measure deleting that 1 char (merges back to unchanged in-place!)
        let t1 = CFAbsoluteTimeGetCurrent()
        editor.deleteBackward(nil)
        let tDelete = CFAbsoluteTimeGetCurrent() - t1

        // After deleteBackward: line must merge back to .unchanged in-place
        XCTAssertEqual(multiBuffer.excerpts[0].stableHunkBufferVersion, buffer.version, "In-place merge on delete must keep stable version")
        let hunk0AfterDelete = multiBuffer.excerpts[0].hunk!
        XCTAssertFalse(hunk0AfterDelete.lines.contains { $0.kind == .deleted }, "Merged line must no longer have deleted line")
        XCTAssertFalse(hunk0AfterDelete.lines.contains { $0.kind == .added }, "Merged line must no longer have added line")
        XCTAssertEqual(hunk0AfterDelete.lines.count, 25, "Hunk must be exactly 25 unchanged lines again")

        // Both must be blazing fast (under 16ms budget)
        XCTAssertLessThan(tInsert, 0.02, "Insert on unchanged line took \(tInsert)s")
        XCTAssertLessThan(tDelete, 0.02, "Immediate delete took \(tDelete)s")
    }

    func testScrollAnchorPreservationAcrossPrecedingFileModifications() {
        let multiBuffer = MultiBuffer()
        let bufA = Buffer(filePath: "FileA.swift", text: "A1\nA2\nA3\nA4\nA5")
        let bLines = (1...50).map { "B\($0)" }.joined(separator: "\n")
        let bufB = Buffer(filePath: "FileB.swift", text: bLines)
        multiBuffer.addBuffer(bufA)
        multiBuffer.addBuffer(bufB)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: bufA.id, filePath: "FileA.swift", bufferRange: 0..<5),
            Excerpt(bufferId: bufB.id, filePath: "FileB.swift", bufferRange: 0..<50)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        editor.invalidateLayout()

        // Find display line for FileB line 5 and scroll to it
        guard let bLine5Idx = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: 5) else {
            XCTFail("FileB line 5 display line not found")
            return
        }
        let bLine5Y = editor.yOffset(forDisplayLineIndex: bLine5Idx)
        editor.scrollOffsetY = bLine5Y

        let savedState = editor.captureViewState()
        XCTAssertEqual(savedState.scrollAnchor?.filePath, "FileB.swift")
        XCTAssertEqual(savedState.scrollAnchor?.lineNumber, 5)

        // Now modify FileA by adding 30 lines (simulating external edit from watcher)
        let newLinesA = (1...35).map { "A\($0)" }.joined(separator: "\n")
        let bufANew = Buffer(filePath: "FileA.swift", text: newLinesA)
        multiBuffer.replaceFile(
            filePath: "FileA.swift",
            buffers: [bufANew],
            excerpts: [Excerpt(bufferId: bufANew.id, filePath: "FileA.swift", bufferRange: 0..<35)]
        )
        dm.rebuild()
        dm.markContentLoaded()

        // Restore view state
        editor.restoreViewState(savedState, shouldFocus: false)

        // The top of the viewport should still pin exactly to FileB line 5
        guard let bLine5IdxAfter = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: 5) else {
            XCTFail("FileB line 5 display line not found after rebuild")
            return
        }
        let bLine5YAfter = editor.yOffset(forDisplayLineIndex: bLine5IdxAfter)
        XCTAssertEqual(editor.scrollOffsetY, bLine5YAfter, "Viewport must stay pinned to FileB line 5 despite FileA expanding by 30 lines")
    }

    func testScrollAnchorPreservationOnFoldGap() {
        let multiBuffer = MultiBuffer()
        // Hunk that starts at line 50 with 30 code lines, creating a top fold gap
        let codeLines = (50...80).map { "code \($0)" }
        let buf = Buffer(filePath: "FileA.swift", lines: codeLines, startLineNumber: 50, isLazySlice: true)
        buf.diskFileLineCount = 100
        multiBuffer.addBuffer(buf)
        let exc = Excerpt(bufferId: buf.id, filePath: "FileA.swift", bufferRange: 0..<codeLines.count, isFileStart: true)
        multiBuffer.setExcerpts([exc])

        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 100)
        editor.invalidateLayout()

        // Display line 0: Header
        // Display line 1: Top fold gap (hidden lines 1..49)
        // Display line 2: Code line 50
        let gapAnchor = dm.fastScrollAnchor(forDisplayLineIndex: 1)
        XCTAssertNotNil(gapAnchor)
        XCTAssertEqual(gapAnchor?.filePath, "FileA.swift")
        XCTAssertEqual(gapAnchor?.lineNumber, 50, "Top fold gap should anchor to the first code line (50) instead of returning nil")
        XCTAssertFalse(gapAnchor?.isHeader == true)

        // Scroll to fold gap and capture state
        editor.scrollOffsetY = editor.yOffset(forDisplayLineIndex: 1)
        let state = editor.captureViewState()
        XCTAssertEqual(state.scrollAnchor?.lineNumber, 50)

        // Rebuild and restore
        dm.rebuild()
        editor.restoreViewState(state, shouldFocus: false)

        // Should not jump to header (line 0, Y = 0)
        let headerY = editor.yOffset(forDisplayLineIndex: 0)
        XCTAssertGreaterThan(editor.scrollOffsetY, headerY, "Restoring fold gap anchor must not jump to header at Y = 0")
    }

    func testScrollAnchorPreservationOnDeletedLine() {
        let multiBuffer = MultiBuffer()
        var hunkLines: [DiffLine] = []
        for i in 1...20 {
            hunkLines.append(DiffLine(kind: .unchanged, text: "u\(i)", oldLineNumber: i, newLineNumber: i))
        }
        hunkLines.append(DiffLine(kind: .deleted, text: "d21", oldLineNumber: 21, newLineNumber: nil))
        hunkLines.append(DiffLine(kind: .added, text: "a21", oldLineNumber: nil, newLineNumber: 21))
        for i in 22...40 {
            hunkLines.append(DiffLine(kind: .unchanged, text: "u\(i)", oldLineNumber: i, newLineNumber: i))
        }

        let hunk = DiffHunk(
            oldRange: 1..<41,
            newRange: 1..<41,
            header: "@@ -1,40 +1,40 @@",
            lines: hunkLines
        )
        let bufferLines = hunkLines.compactMap { line -> String? in
            guard line.kind != .deleted else { return nil }
            return line.text
        }
        let buf = Buffer(filePath: "FileA.swift", text: bufferLines.joined(separator: "\n"))
        multiBuffer.addBuffer(buf)
        multiBuffer.setExcerpts([Excerpt(bufferId: buf.id, filePath: "FileA.swift", bufferRange: 0..<bufferLines.count, hunk: hunk)])

        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 100)
        editor.invalidateLayout()

        // Line 0: Header
        // Lines 1..20: u1..u20
        // Line 21: d21 (deleted, oldLineNumber 21)
        let delDisplayIdx = 21
        let delAnchor = dm.fastScrollAnchor(forDisplayLineIndex: delDisplayIdx)
        XCTAssertNotNil(delAnchor)
        XCTAssertEqual(delAnchor?.lineNumber, 21)
        XCTAssertTrue(delAnchor?.isOldSide == true, "Deleted line fastScrollAnchor must report isOldSide: true")

        editor.scrollOffsetY = editor.yOffset(forDisplayLineIndex: delDisplayIdx)
        let state = editor.captureViewState()
        XCTAssertTrue(state.scrollAnchor?.isOldSide == true)

        dm.rebuild()
        editor.restoreViewState(state, shouldFocus: false)
        XCTAssertEqual(editor.scrollOffsetY, editor.yOffset(forDisplayLineIndex: delDisplayIdx))
    }

    func testViewportStabilityWhenFileRemovedFromDiff() {
        let multiBuffer = MultiBuffer()
        let bufA = Buffer(filePath: "FileA.swift", text: "A1\nA2\nA3")
        let bufB = Buffer(filePath: "FileB.swift", text: "B1\nB2\nB3\nB4\nB5")
        multiBuffer.addBuffer(bufA)
        multiBuffer.addBuffer(bufB)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: bufA.id, filePath: "FileA.swift", bufferRange: 0..<3),
            Excerpt(bufferId: bufB.id, filePath: "FileB.swift", bufferRange: 0..<5)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 100)
        editor.invalidateLayout()

        // Scroll to FileB
        guard let bLine1Idx = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: 1) else {
            XCTFail("FileB line 1 not found")
            return
        }
        let bLine1Y = editor.yOffset(forDisplayLineIndex: bLine1Idx)
        editor.scrollOffsetY = bLine1Y
        let state = editor.captureViewState()

        // Now FileB is committed and removed completely from diff
        multiBuffer.removeFile(filePath: "FileB.swift")
        dm.rebuild()
        dm.markContentLoaded()

        // Restore view state: should clamp scrollOffsetY within valid bounds, not jump to 0
        editor.restoreViewState(state, shouldFocus: false)
        let maxScrollY = max(0, editor.totalDocumentHeight - editor.bounds.height)
        XCTAssertEqual(editor.scrollOffsetY, min(bLine1Y, maxScrollY))
    }

    func testScrollNotResetOnAgentRerender() {
        let multiBuffer = MultiBuffer()
        let bufA = Buffer(filePath: "FileA.swift", text: (1...50).map { "A\($0)" }.joined(separator: "\n"))
        let bufB = Buffer(filePath: "FileB.swift", text: (1...50).map { "B\($0)" }.joined(separator: "\n"))
        multiBuffer.addBuffer(bufA)
        multiBuffer.addBuffer(bufB)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: bufA.id, filePath: "FileA.swift", bufferRange: 0..<50),
            Excerpt(bufferId: bufB.id, filePath: "FileB.swift", bufferRange: 0..<50)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let host = EditorHostView(
            displayMap: dm,
            theme: .unifiedDark,
            selectedFilePath: "FileA.swift",
            onCursorChange: { _, _ in },
            onAddCommentRequest: { _, _ in }
        )
        let coordinator = host.makeCoordinator()
        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        editor.delegate = coordinator
        coordinator.editorView = editor
        let displayMapID = ObjectIdentifier(dm)
        coordinator.activeDisplayMapID = displayMapID
        coordinator.lastLoadRevisions[displayMapID] = dm.loadRevision
        coordinator.lastLayoutModes[displayMapID] = dm.effectiveLayoutMode
        coordinator.lastSelectedFilePaths[displayMapID] = "FileA.swift"

        // Simulate user scrolling down into FileB
        guard let bLine10Idx = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: 10) else {
            XCTFail("FileB line 10 display line not found")
            return
        }
        let bLine10Y = editor.yOffset(forDisplayLineIndex: bLine10Idx)
        editor.scrollOffsetY = bLine10Y
        coordinator.editorDidScroll()

        XCTAssertEqual(editor.scrollOffsetY, bLine10Y)

        // 1. Simulating sending a message in the agent:
        // SwiftUI re-evaluates MainWindowView body, calling updateView.
        // The user is typing/focused in chat, so editor is NOT first responder.
        // selectedFilePath is still "FileA.swift" because user only scrolled without changing selection.
        let msgSentHost = EditorHostView(
            displayMap: dm,
            theme: .unifiedDark,
            selectedFilePath: "FileA.swift",
            onCursorChange: { _, _ in },
            onAddCommentRequest: { _, _ in }
        )
        msgSentHost.updateView(editor, coordinator: coordinator)

        // Drain runloop for any pending async tasks
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Scroll MUST remain at FileB line 10, NOT reset to FileA (0)
        XCTAssertEqual(editor.scrollOffsetY, bLine10Y, "Sending a prompt in agent chat must not reset editor scroll position")

        // 2. Simulating a toolcall being added in the agent:
        // Another SwiftUI re-render occurs while streaming.
        let toolCallHost = EditorHostView(
            displayMap: dm,
            theme: .unifiedDark,
            selectedFilePath: "FileA.swift",
            onCursorChange: { _, _ in },
            onAddCommentRequest: { _, _ in }
        )
        toolCallHost.updateView(editor, coordinator: coordinator)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(editor.scrollOffsetY, bLine10Y, "Adding a toolcall in agent chat must not reset editor scroll position")

        // 3. Simulating explicit sidebar click on FileB:
        // When selectedFilePath changes from FileA to FileB, it SHOULD scroll to FileB
        let sidebarClickHost = EditorHostView(
            displayMap: dm,
            theme: .unifiedDark,
            selectedFilePath: "FileB.swift",
            onCursorChange: { _, _ in },
            onAddCommentRequest: { _, _ in }
        )
        sidebarClickHost.updateView(editor, coordinator: coordinator)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let bHeaderIdx = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: nil, isHeader: true) else {
            XCTFail("FileB header display line not found")
            return
        }
        let bHeaderY = editor.yOffset(forDisplayLineIndex: bHeaderIdx)
        XCTAssertEqual(editor.scrollOffsetY, bHeaderY, "Explicit file selection in sidebar must scroll to the selected file")
    }

    func testTopContentInsetClearanceAndScrolling() {
        let multiBuffer = MultiBuffer()
        let buf = Buffer(filePath: "FileA.swift", text: (1...50).map { "line \($0)" }.joined(separator: "\n"))
        multiBuffer.addBuffer(buf)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: buf.id, filePath: "FileA.swift", bufferRange: 0..<50)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .unifiedDark)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        editor.topContentInset = 52

        // First item (file header) must start at topContentInset
        let headerY = editor.yOffset(forDisplayLineIndex: 0)
        XCTAssertEqual(headerY, 52, "First item in editor should start after topContentInset")

        // Total document height must include topContentInset
        XCTAssertGreaterThan(editor.totalDocumentHeight, 52)

        // lineIndex at y <= 52 should map to index 0
        XCTAssertEqual(editor.lineIndex(atY: 0), 0)
        XCTAssertEqual(editor.lineIndex(atY: 52), 0)

        // scrollToFilePath should position first file at scrollOffsetY = 0 (top of viewport)
        editor.scrollToFilePath("FileA.swift")
        XCTAssertEqual(editor.scrollOffsetY, 0)
    }

    func testFloatingGlassPillExcerptHeaderGeometryAndHitTesting() {
        let multiBuffer = MultiBuffer()
        let buf = Buffer(filePath: "README.md", text: "# Hello World\nLine 2\n")
        multiBuffer.addBuffer(buf)
        multiBuffer.setExcerpts([
            Excerpt(bufferId: buf.id, filePath: "README.md", bufferRange: 0..<2)
        ])
        let dm = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        dm.rebuild()

        let editor = CustomMultiBufferEditorView(displayMap: dm, theme: .vesper)
        editor.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        editor.topContentInset = 52

        let headerRect = CGRect(x: 0, y: 52, width: 800, height: editor.excerptHeaderHeight)
        let pill = editor.pillRect(for: headerRect)

        // Floating pill must be horizontally and vertically inset
        XCTAssertEqual(pill.minX, 12)
        XCTAssertEqual(pill.maxX, 800 - 12)
        XCTAssertEqual(pill.width, 800 - 24)
        XCTAssertEqual(pill.minY, 52 + 3)
        XCTAssertEqual(pill.height, editor.excerptHeaderHeight - 6)
        XCTAssertTrue(headerRect.contains(pill))

        // Close button and Markdown preview button must reside inside the pill
        let closeRect = editor.closeButtonRect(in: headerRect)
        XCTAssertTrue(pill.contains(closeRect))
        XCTAssertEqual(closeRect.width, 18)
        XCTAssertEqual(closeRect.height, 18)

        let previewRect = editor.previewButtonRect(in: headerRect)
        XCTAssertTrue(pill.contains(previewRect))
        XCTAssertEqual(previewRect.width, 18)
        XCTAssertEqual(previewRect.height, 18)

        // Close button on leading side, preview on trailing side
        XCTAssertLessThan(closeRect.maxX, previewRect.minX)
        XCTAssertGreaterThan(previewRect.minX, pill.maxX - 30)
    }
}
