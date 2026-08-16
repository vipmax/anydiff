import XCTest
@testable import AnyDiffCore

final class MultiBufferTests: XCTestCase {
    func testMultiBufferCoordinateMapping() {
        let buffer1 = Buffer(filePath: "FileA.swift", text: "line 0\nline 1\nline 2\nline 3")
        let buffer2 = Buffer(filePath: "FileB.swift", text: "alpha\nbeta\ngamma")

        let mb = MultiBuffer()
        mb.addBuffer(buffer1)
        mb.addBuffer(buffer2)

        let excerpt1 = Excerpt(
            bufferId: buffer1.id,
            filePath: "FileA.swift",
            bufferRange: 1..<3 // "line 1", "line 2" (2 lines)
        )
        let excerpt2 = Excerpt(
            bufferId: buffer2.id,
            filePath: "FileB.swift",
            bufferRange: 0..<2 // "alpha", "beta" (2 lines)
        )

        mb.setExcerpts([excerpt1, excerpt2])

        XCTAssertEqual(mb.lineCount, 4)

        // MB row 0 -> FileA line 1 (1-based: 2)
        let loc0 = mb.location(for: 0)
        XCTAssertNotNil(loc0)
        XCTAssertEqual(loc0?.filePath, "FileA.swift")
        XCTAssertEqual(loc0?.bufferRow, 1)
        XCTAssertEqual(loc0?.fileLineNumber, 2)
        XCTAssertEqual(mb.line(at: 0), "line 1")

        // MB row 1 -> FileA line 2
        let loc1 = mb.location(for: 1)
        XCTAssertEqual(loc1?.bufferRow, 2)
        XCTAssertEqual(mb.line(at: 1), "line 2")

        // MB row 2 -> FileB line 0
        let loc2 = mb.location(for: 2)
        XCTAssertEqual(loc2?.filePath, "FileB.swift")
        XCTAssertEqual(loc2?.bufferRow, 0)
        XCTAssertEqual(mb.line(at: 2), "alpha")

        // Inverse mapping
        let mbRow = mb.multiBufferRow(excerptIndex: 1, bufferRow: 1)
        XCTAssertEqual(mbRow, 3)
    }

    func testLiveEditingAndUndoRedo() {
        let buffer = Buffer(filePath: "Core.swift", text: "func calculate() -> Int {\n    return 42\n}")
        let mb = MultiBuffer()
        mb.addBuffer(buffer)
        let excerpt = Excerpt(bufferId: buffer.id, filePath: "Core.swift", bufferRange: 0..<3)
        mb.addExcerpt(excerpt)

        // Edit row 1 "    return 42" -> "    return 100"
        let editRange = MultiBufferPoint(row: 1, column: 11)..<MultiBufferPoint(row: 1, column: 13)
        mb.replace(range: editRange, with: "100")

        XCTAssertEqual(mb.line(at: 1), "    return 100")
        XCTAssertTrue(mb.undoManager.canUndo)

        // Undo
        if let tx = mb.undoManager.popUndo() {
            for edit in tx.edits.reversed() {
                if let buf = mb.buffer(for: edit.bufferId) {
                    buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.oldText)
                }
            }
        }
        XCTAssertEqual(mb.line(at: 1), "    return 42")
    }

    func testSyntaxHighlightingClosureVariables() {
        let line = "        buffers.values.contains { $0.isDirty }"
        let spans = SyntaxHighlighter.shared.tokenize(line: line, language: "swift")
        XCTAssertFalse(spans.isEmpty)
    }

    func testDisplayMapDeletedLineDetection() {
        let diffSample = """
        --- a/Test.swift
        +++ b/Test.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
        let parsed = GitDiffParser.shared.parse(diffText: diffSample)
        XCTAssertEqual(parsed.count, 1)

        let mb = MultiBuffer()
        let rm = ReviewManager()
        let file = parsed[0]
        let hunk = file.hunks[0]
        let oldBaseline = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let newFile = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let buffer = Buffer(filePath: file.displayPath, text: newFile, baselineText: oldBaseline)
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: file.displayPath,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        // Row 0 is unchanged, Row 1 is deleted, Row 2 is added
        XCTAssertFalse(dm.isDeleted(multiBufferRow: 0))
        XCTAssertTrue(dm.isDeleted(multiBufferRow: 1))
        XCTAssertFalse(dm.isDeleted(multiBufferRow: 2))
        XCTAssertTrue(dm.isDeleted(rowRange: 0..<2))
    }

    func testLiveNewlineInsertionDiffRecalculation() {
        let diffSample = """
        --- a/Test.swift
        +++ b/Test.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        """
        let parsed = GitDiffParser.shared.parse(diffText: diffSample)
        let mb = MultiBuffer()
        let rm = ReviewManager()
        let file = parsed[0]
        let hunk = file.hunks[0]
        let oldBaseline = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let newFile = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let buffer = Buffer(filePath: file.displayPath, text: newFile, baselineText: oldBaseline)
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: file.displayPath,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        XCTAssertEqual(dm.displayLines.count, 4) // 1 header + 3 code lines

        // Insert newline after line 1 ("let b = 3")
        let endPt = MultiBufferPoint(row: 1, column: 9)
        mb.replace(range: endPt..<endPt, with: "\nlet c = 4")
        dm.rebuild()

        XCTAssertEqual(dm.displayLines.count, 5) // 1 header + 4 code lines
        if case .code(let info) = dm.line(at: 4) {
            // Newly inserted line
            XCTAssertEqual(info.diffKind, .added)
            XCTAssertEqual(info.newLineNumber, 3)
            XCTAssertEqual(info.text, "let c = 4")
        }
    }

    func testMultiBufferDeleteAndLineMerging() {
        let buffer = Buffer(filePath: "Merge.swift", text: "line 1\nline 2\nline 3")
        let mb = MultiBuffer()
        mb.addBuffer(buffer)
        let excerpt = Excerpt(bufferId: buffer.id, filePath: "Merge.swift", bufferRange: 0..<3)
        mb.addExcerpt(excerpt)

        // Delete newline between line 1 and line 2 (from end of line 1 to start of line 2)
        let startPt = MultiBufferPoint(row: 0, column: 6)
        let endPt = MultiBufferPoint(row: 1, column: 0)
        let deleteRange = startPt..<endPt
        mb.delete(range: deleteRange)

        XCTAssertEqual(buffer.lineCount, 2)
        XCTAssertEqual(buffer.line(at: 0), "line 1line 2")
    }

    func testCursorNavigationAndDeletedLinesInDisplayMap() {
        let diffSample = """
        --- a/Calculator.swift
        +++ b/Calculator.swift
        @@ -1,4 +1,4 @@
         let header = "Calc"
        -let oldFormula = 2 * 2 + 10
        +let newFormula = 3 * 3
         let footer = "End"
        """
        let parsed = GitDiffParser.shared.parse(diffText: diffSample)
        let mb = MultiBuffer()
        let rm = ReviewManager()
        let file = parsed[0]
        let hunk = file.hunks[0]
        let oldBaseline = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let newFile = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text).joined(separator: "\n")
        let buffer = Buffer(filePath: file.displayPath, text: newFile, baselineText: oldBaseline)
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: file.displayPath,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        // 1 header + 4 code lines (row 0: unchanged, row 1: deleted, row 2: added, row 3: unchanged)
        XCTAssertEqual(dm.codeLineCount, 4)
        XCTAssertEqual(dm.minCodeRow, 0)
        XCTAssertEqual(dm.maxCodeRow, 3)

        // Check line lengths including deleted line
        let len0 = dm.lineLength(at: 0) // 'let header = "Calc"' (19 chars)
        let len1 = dm.lineLength(at: 1) // 'let oldFormula = 2 * 2 + 10' (27 chars, deleted line)
        let len2 = dm.lineLength(at: 2) // 'let newFormula = 3 * 3' (22 chars, added line)
        let len3 = dm.lineLength(at: 3) // 'let footer = "End"' (18 chars)

        XCTAssertEqual(len0, 19)
        XCTAssertEqual(len1, 27)
        XCTAssertEqual(len2, 22)
        XCTAssertEqual(len3, 18)

        // Deleted line recognition
        XCTAssertFalse(dm.isDeleted(multiBufferRow: 0))
        XCTAssertTrue(dm.isDeleted(multiBufferRow: 1))
        XCTAssertFalse(dm.isDeleted(multiBufferRow: 2))
        XCTAssertFalse(dm.isDeleted(multiBufferRow: 3))

        // Next and Previous row lookups
        XCTAssertEqual(dm.nextCodeRow(after: 0), 1)
        XCTAssertEqual(dm.nextCodeRow(after: 1), 2)
        XCTAssertEqual(dm.nextCodeRow(after: 2), 3)
        XCTAssertNil(dm.nextCodeRow(after: 3))

        XCTAssertNil(dm.previousCodeRow(before: 0))
        XCTAssertEqual(dm.previousCodeRow(before: 1), 0)
        XCTAssertEqual(dm.previousCodeRow(before: 2), 1)
        XCTAssertEqual(dm.previousCodeRow(before: 3), 2)

        // Excerpt location mapping
        let locDeleted = dm.excerptLocation(for: MultiBufferPoint(row: 1, column: 5))
        XCTAssertNotNil(locDeleted)
        XCTAssertEqual(locDeleted?.filePath, file.displayPath)
        XCTAssertEqual(locDeleted?.bufferColumn, 5)

        let locAdded = dm.excerptLocation(for: MultiBufferPoint(row: 2, column: 10))
        XCTAssertNotNil(locAdded)
        XCTAssertEqual(locAdded?.filePath, file.displayPath)
        XCTAssertEqual(locAdded?.bufferColumn, 10)
    }

    func testExpandInfoOnExcerptBoundaries() {
        var lines: [String] = []
        for i in 0..<100 {
            lines.append("line \(i)")
        }
        let fullText = lines.joined(separator: "\n")
        let buffer = Buffer(filePath: "Service.swift", text: fullText)

        let mb = MultiBuffer()
        mb.addBuffer(buffer)

        // Excerpt representing lines 10..20 of a 100-line file
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Service.swift",
            bufferRange: 10..<20
        )
        mb.addExcerpt(excerpt)

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        let codeLines = dm.codeLines
        XCTAssertEqual(codeLines.count, 10)

        // Top line has ExpandUp
        XCTAssertEqual(codeLines.first?.expandInfo?.direction, .up)
        XCTAssertEqual(codeLines.first?.expandInfo?.excerptIndex, 0)

        // Middle lines have no expand button
        for i in 1..<9 {
            XCTAssertNil(codeLines[i].expandInfo)
        }

        // Bottom line has ExpandDown
        XCTAssertEqual(codeLines.last?.expandInfo?.direction, .down)
        XCTAssertEqual(codeLines.last?.expandInfo?.excerptIndex, 0)
    }

    func testExcerptExpansionAndMerging() {
        var lines: [String] = []
        for i in 0..<100 {
            lines.append("line \(i)")
        }
        let fullText = lines.joined(separator: "\n")
        let buffer = Buffer(filePath: "Service.swift", text: fullText)

        let mb = MultiBuffer()
        mb.addBuffer(buffer)

        let excerpt1 = Excerpt(
            bufferId: buffer.id,
            filePath: "Service.swift",
            bufferRange: 10..<20,
            isFileStart: true
        )
        let excerpt2 = Excerpt(
            bufferId: buffer.id,
            filePath: "Service.swift",
            bufferRange: 30..<40,
            isFileStart: false
        )
        mb.setExcerpts([excerpt1, excerpt2])
        XCTAssertEqual(mb.excerpts.count, 2)

        // Expand excerpt 1 down by 3 lines -> 10..<23
        mb.expandExcerpt(at: 0, up: 0, down: 3)
        XCTAssertEqual(mb.excerpts[0].bufferRange, 10..<23)
        XCTAssertEqual(mb.excerpts.count, 2)

        // Expand excerpt 2 up by 5 lines -> 25..<40 (gap is now 2 lines: 23..<25, which triggers auto-merge <= 2)
        mb.expandExcerpt(at: 1, up: 5, down: 0)

        // Automatic merge combines them into 1 contiguous excerpt 10..<40
        XCTAssertEqual(mb.excerpts.count, 1)
        XCTAssertEqual(mb.excerpts[0].bufferRange, 10..<40)
    }

    func testSingleLineExcerptVerticalExpansion() {
        var lines: [String] = []
        for i in 0..<50 {
            lines.append("line \(i)")
        }
        let fullText = lines.joined(separator: "\n")
        let buffer = Buffer(filePath: "Single.swift", text: fullText)

        let mb = MultiBuffer()
        mb.addBuffer(buffer)

        // Single line excerpt in the middle of buffer
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Single.swift",
            bufferRange: 25..<26
        )
        mb.addExcerpt(excerpt)

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        let codeLines = dm.codeLines
        XCTAssertEqual(codeLines.count, 1)
        XCTAssertEqual(codeLines.first?.expandInfo?.direction, .upAndDown)
    }

    func testSaveToFilePreservesFullFileContentsOnEdit() throws {
        // 1. Create a 100-line file on disk
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("Document.swift")
        var originalLines: [String] = []
        for i in 1...100 {
            originalLines.append("let variable\(i) = \(i)")
        }
        let fullDiskContent = originalLines.joined(separator: "\n")
        try fullDiskContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // 2. Setup MultiBuffer with full file buffer and an excerpt at lines 40..<50 (0-based: 39..<49)
        let buffer = Buffer(
            filePath: "Document.swift",
            text: fullDiskContent,
            fullDiskPath: fileURL.path,
            diskFileLineCount: 100
        )
        buffer.isFullFile = true

        let mb = MultiBuffer()
        mb.baseDirectory = tmpDir.path
        mb.addBuffer(buffer)

        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Document.swift",
            bufferRange: 39..<49
        )
        mb.addExcerpt(excerpt)

        // MultiBuffer point for line 42 (0-based row 41, which is offset 2 inside excerpt: row 2 in mb)
        // Edit line 42 ("let variable42 = 42" -> "let variable42 = 999999")
        let editPoint = MultiBufferPoint(row: 2, column: 17)
        mb.replace(range: editPoint..<MultiBufferPoint(row: 2, column: 19), with: "999999")

        // 3. Immediately flush save
        let saved = mb.flushImmediateSave()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first, "Document.swift")

        // 4. Read back file from disk and assert all 100 lines are preserved!
        let savedDiskText = try String(contentsOf: fileURL, encoding: .utf8)
        let savedDiskLines = savedDiskText.components(separatedBy: "\n")
        XCTAssertEqual(savedDiskLines.count, 100, "File on disk must retain all 100 lines, NOT be truncated!")

        // Verify lines before and after are intact
        for i in 0..<41 {
            XCTAssertEqual(savedDiskLines[i], originalLines[i])
        }
        XCTAssertEqual(savedDiskLines[41], "let variable42 = 999999")
        for i in 42..<100 {
            XCTAssertEqual(savedDiskLines[i], originalLines[i])
        }
    }

    func testSaveMultipleHunksToSameFile() throws {
        // 1. Create a 100-line file on disk
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("MultiHunk.swift")
        var originalLines: [String] = []
        for i in 1...100 {
            originalLines.append("func step\(i)() {}")
        }
        try originalLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        // 2. Setup MultiBuffer with 2 excerpts (hunk 1: 10..<20, hunk 2: 60..<70)
        let fullDiskContent = originalLines.joined(separator: "\n")
        let buffer = Buffer(
            filePath: "MultiHunk.swift",
            text: fullDiskContent,
            fullDiskPath: fileURL.path,
            diskFileLineCount: 100
        )
        buffer.isFullFile = true

        let mb = MultiBuffer()
        mb.baseDirectory = tmpDir.path
        mb.addBuffer(buffer)

        let excerpt1 = Excerpt(
            bufferId: buffer.id,
            filePath: "MultiHunk.swift",
            bufferRange: 10..<20,
            isFileStart: true
        )
        let excerpt2 = Excerpt(
            bufferId: buffer.id,
            filePath: "MultiHunk.swift",
            bufferRange: 60..<70,
            isFileStart: false
        )
        mb.setExcerpts([excerpt1, excerpt2])

        // Insert a new line in Excerpt 1 after step15 (MB row 4 -> buffer row 14)
        let insPt = MultiBufferPoint(row: 4, column: 17)
        mb.replace(range: insPt..<insPt, with: "\nfunc extraStep() {}")

        // Excerpt 2 should have automatically shifted its bufferRange from 60..<70 to 61..<71
        XCTAssertEqual(mb.excerpts[0].bufferRange, 10..<21)
        XCTAssertEqual(mb.excerpts[1].bufferRange, 61..<71)

        // Edit Excerpt 2 at MB row 11 (first line of excerpt2, now buffer row 61: step61)
        let editPt = MultiBufferPoint(row: 11, column: 17)
        mb.replace(range: editPt..<editPt, with: " // modified")

        // Save
        mb.flushImmediateSave()

        // 3. Verify file on disk has 101 lines with both edits in the right positions
        let savedText = try String(contentsOf: fileURL, encoding: .utf8)
        let savedLines = savedText.components(separatedBy: "\n")
        XCTAssertEqual(savedLines.count, 101)
        XCTAssertEqual(savedLines[14], "func step15() {}")
        XCTAssertEqual(savedLines[15], "func extraStep() {}")
        XCTAssertEqual(savedLines[16], "func step16() {}")
        XCTAssertEqual(savedLines[61], "func step61() {} // modified")
        XCTAssertEqual(savedLines.first, "func step1() {}")
        XCTAssertEqual(savedLines.last, "func step100() {}")
    }

    func testPartialBufferSafeSplicingFallback() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("Partial.swift")
        var originalLines: [String] = []
        for i in 1...50 {
            originalLines.append("item \(i)")
        }
        try originalLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        // Partial buffer representing lines 20..24 (5 lines)
        let partialText = "item 20\nitem 21\nitem 22 (edited)\nitem 23\nitem 24"
        let baselineText = "item 20\nitem 21\nitem 22\nitem 23\nitem 24"
        let buffer = Buffer(
            filePath: "Partial.swift",
            text: partialText,
            baselineText: baselineText,
            startLineNumber: 20,
            fullDiskPath: fileURL.path,
            diskFileLineCount: 50
        )
        buffer.isFullFile = false // Explicit partial buffer

        try buffer.saveToFile(baseDirectory: tmpDir.path)

        // Disk file should still have all 50 lines!
        let savedText = try String(contentsOf: fileURL, encoding: .utf8)
        let savedLines = savedText.components(separatedBy: "\n")
        XCTAssertEqual(savedLines.count, 50)
        XCTAssertEqual(savedLines[0], "item 1")
        XCTAssertEqual(savedLines[21], "item 22 (edited)")
        XCTAssertEqual(savedLines[49], "item 50")
    }
}
