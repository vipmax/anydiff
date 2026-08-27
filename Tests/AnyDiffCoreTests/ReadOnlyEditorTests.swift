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
}
