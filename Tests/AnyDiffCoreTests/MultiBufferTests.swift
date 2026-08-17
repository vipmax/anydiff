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

    func testInsertingMultipleNewlinesInModifiedHunk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalDiskContent = """
        import Foundation
        
        /// Fast and robust parser for Git Unified Diffs
        public final class GitDiffParser: Sendable {
            public static let shared = GitDiffParser()
        }
        """
        let filePath = "GitDiffParser.swift"
        let fullPath = tempDir.appendingPathComponent(filePath).path
        try originalDiskContent.write(toFile: fullPath, atomically: true, encoding: .utf8)

        let diffSample = """
        diff --git a/GitDiffParser.swift b/GitDiffParser.swift
        --- a/GitDiffParser.swift
        +++ b/GitDiffParser.swift
        @@ -1,3 +1,6 @@
         import Foundation
         
        +/// Splits streaming byte chunks
        +/// using fast SIMD
        +public final class ChunkLineSplitter {
        """
        let parsed = GitDiffParser.shared.parse(diffText: diffSample)
        let file = parsed[0]
        let hunk = file.hunks[0]

        let mb = MultiBuffer()
        let rm = ReviewManager()
        let newFile = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
        let oldBaseline = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
        let buffer = Buffer(filePath: file.displayPath, lines: newFile, baselineLines: oldBaseline, startLineNumber: 1, fullDiskPath: fullPath)
        buffer.isFullFile = false
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: file.displayPath,
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        XCTAssertEqual(dm.codeLines.count, 5)

        // 1. Press Enter at line 1 (row 1, column 0) and trigger auto-save
        let pt1 = MultiBufferPoint(row: 1, column: 0)
        mb.replace(range: pt1..<pt1, with: "\n")
        dm.rebuild()
        try buffer.saveToFile()

        // 2. Press Enter again at line 2 and trigger auto-save
        let pt2 = MultiBufferPoint(row: 2, column: 0)
        mb.replace(range: pt2..<pt2, with: "\n")
        dm.rebuild()
        try buffer.saveToFile()

        // 3. Press Enter 3rd time at line 3 and trigger auto-save
        let pt3 = MultiBufferPoint(row: 3, column: 0)
        mb.replace(range: pt3..<pt3, with: "\n")
        dm.rebuild()
        try buffer.saveToFile()

        // Total lines should be 8: 1 unchanged, 1 unchanged (original empty line), 3 added empty lines, 3 added ChunkLineSplitter lines
        XCTAssertEqual(dm.codeLines.count, 8)
        XCTAssertEqual(dm.codeLines[0].diffKind, .unchanged)
        XCTAssertEqual(dm.codeLines[0].text, "import Foundation")
        XCTAssertEqual(dm.codeLines[1].diffKind, .unchanged)
        XCTAssertEqual(dm.codeLines[1].text, "")

        // The next 3 newly inserted empty lines and the 3 ChunkLineSplitter lines must all be .added
        for i in 2..<8 {
            XCTAssertEqual(dm.codeLines[i].diffKind, .added, "Line at index \(i) must have .added diffKind")
        }

        // Verify the saved file on disk: must contain the new lines without any duplication or truncation of the rest of the file
        let diskSaved = try String(contentsOfFile: fullPath, encoding: .utf8)
        let diskLines = diskSaved.components(separatedBy: "\n")
        XCTAssertTrue(diskLines.contains("public final class GitDiffParser: Sendable {"))
        XCTAssertTrue(diskLines.contains("public final class ChunkLineSplitter {"))
        XCTAssertEqual(diskLines.first, "import Foundation")
    }

    func testMultiHunkIndependentEditingAndSaving() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var lines: [String] = []
        for i in 1...100 {
            lines.append("line_\(i)")
        }
        let fullPath = tempDir.appendingPathComponent("MultiHunk.swift").path
        try lines.joined(separator: "\n").write(toFile: fullPath, atomically: true, encoding: .utf8)

        let mb = MultiBuffer()

        // Hunk 1 at line 10 (lines 10..12)
        let hunk1Lines = ["line_10", "line_11", "line_12"]
        let buf1 = Buffer(filePath: "MultiHunk.swift", lines: hunk1Lines, baselineLines: hunk1Lines, startLineNumber: 10, fullDiskPath: fullPath)
        buf1.isFullFile = false
        mb.addBuffer(buf1)
        let ex1 = Excerpt(bufferId: buf1.id, filePath: "MultiHunk.swift", fileStatus: .modified, bufferRange: 0..<3)
        mb.addExcerpt(ex1)

        // Hunk 2 at line 50 (lines 50..52)
        let hunk2Lines = ["line_50", "line_51", "line_52"]
        let buf2 = Buffer(filePath: "MultiHunk.swift", lines: hunk2Lines, baselineLines: hunk2Lines, startLineNumber: 50, fullDiskPath: fullPath)
        buf2.isFullFile = false
        mb.addBuffer(buf2)
        let ex2 = Excerpt(bufferId: buf2.id, filePath: "MultiHunk.swift", fileStatus: .modified, bufferRange: 0..<3)
        mb.addExcerpt(ex2)

        // 1. Edit Hunk 1: insert 2 new lines in Hunk 1
        let pt1 = MultiBufferPoint(row: 1, column: 7) // end of line_11
        mb.replace(range: pt1..<pt1, with: "\nnew_hunk1_a\nnew_hunk1_b")

        // buf2 startLineNumber should be shifted from 50 to 52!
        XCTAssertEqual(buf2.startLineNumber, 52)

        // Save Hunk 1 to disk
        try buf1.saveToFile()

        // 2. Now edit Hunk 2: insert 1 new line in Hunk 2
        let pt2 = MultiBufferPoint(row: 5, column: 7) // end of line_50 in second excerpt (ex1 has 5 rows now: 0..4, so row 5 is line_50)
        mb.replace(range: pt2..<pt2, with: "\nnew_hunk2_a")

        // Save Hunk 2 to disk
        try buf2.saveToFile()

        // Verify disk contents
        let savedText = try String(contentsOfFile: fullPath, encoding: .utf8)
        let savedLines = savedText.components(separatedBy: "\n")

        // Line count should be 100 + 2 + 1 = 103 lines
        XCTAssertEqual(savedLines.count, 103)

        // Verify Hunk 1 additions at lines 11, 12
        XCTAssertEqual(savedLines[9], "line_10")
        XCTAssertEqual(savedLines[10], "line_11")
        XCTAssertEqual(savedLines[11], "new_hunk1_a")
        XCTAssertEqual(savedLines[12], "new_hunk1_b")
        XCTAssertEqual(savedLines[13], "line_12")

        // Verify Hunk 2 additions at line 53 (shifted by +2 from Hunk 1)
        XCTAssertEqual(savedLines[51], "line_50")
        XCTAssertEqual(savedLines[52], "new_hunk2_a")
        XCTAssertEqual(savedLines[53], "line_51")
        XCTAssertEqual(savedLines[54], "line_52")

        // Verify original first and last lines are completely intact
        XCTAssertEqual(savedLines.first, "line_1")
        XCTAssertEqual(savedLines.last, "line_100")
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

    func testToggleCollapsePerformanceOnLargeDiff() {
        let mb = MultiBuffer()
        let rm = ReviewManager()

        // Create 200 files, each with 50 diff lines = 10,000 lines
        for f in 0..<200 {
            let hunkLines = (0..<50).map { i in
                DiffLine(kind: (i % 5 == 0) ? .added : .unchanged, text: "let var_\(f)_\(i) = calculateValue(\(i))", oldLineNumber: i + 1, newLineNumber: i + 1)
            }
            let hunk = DiffHunk(
                oldRange: 1..<51,
                newRange: 1..<51,
                header: "@@ -1,50 +1,50 @@",
                lines: hunkLines
            )
            let buffer = Buffer(
                filePath: "File_\(f).swift",
                text: hunkLines.map(\.text).joined(separator: "\n"),
                language: "swift",
                totalAdditions: 10,
                totalDeletions: 0,
                startLineNumber: 1
            )
            mb.addBuffer(buffer)
            let excerpt = Excerpt(
                bufferId: buffer.id,
                filePath: "File_\(f).swift",
                fileStatus: .modified,
                bufferRange: 0..<50,
                hunk: hunk,
                isCollapsed: false,
                isFileStart: true
            )
            mb.addExcerpt(excerpt)
        }

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        // 200 headers + 10,000 code lines = 10,200 lines
        XCTAssertEqual(dm.displayLines.count, 10_200)
        XCTAssertGreaterThan(dm.maxLineChars, 20)

        // Toggle collapse on first file
        let t0 = Date()
        mb.toggleCollapse(at: 0)
        dm.rebuild()
        let elapsed = Date().timeIntervalSince(t0)

        // Should take well123123 under 50ms for 10k lines
        XCTAssertLessThan(elapsed, 0.05)
        // 1st file collapsed (only header remains, 50 code lines removed) -> 10,150 lines
        XCTAssertEqual(dm.displayLines.count, 10_150)

        if case .excerptHeader(let h) = dm.displayLines[0] {
            XCTAssertTrue(h.isCollapsed)
            XCTAssertEqual(h.filePath, "File_0.swift")
        } else {
            XCTFail("First line should be header")
        }

        // Toggle back to expanded
        mb.toggleCollapse(at: 0)
        dm.rebuild()
        XCTAssertEqual(dm.displayLines.count, 10_200)
        if case .excerptHeader(let h) = dm.displayLines[0] {
            XCTAssertFalse(h.isCollapsed)
        } else {
            XCTFail("First line should be header")
        }
    }

    func testRepeatedExcerptExpansionAndMergingMaintainsValidIndices() {
        let mb = MultiBuffer()
        let rm = ReviewManager()

        // File 1: Buffer with 50 lines, 2 separate excerpts (0..<10 and 20..<30)
        let f1Lines = (0..<50).map { "func f1_line_\($0)() {}" }
        let buf1 = Buffer(filePath: "File1.swift", text: f1Lines.joined(separator: "\n"), language: "swift", startLineNumber: 1)
        mb.addBuffer(buf1)

        let exc1_a = Excerpt(bufferId: buf1.id, filePath: "File1.swift", bufferRange: 0..<10, hunk: nil, isCollapsed: false, isFileStart: true)
        let exc1_b = Excerpt(bufferId: buf1.id, filePath: "File1.swift", bufferRange: 20..<30, hunk: nil, isCollapsed: false, isFileStart: false)
        mb.addExcerpt(exc1_a)
        mb.addExcerpt(exc1_b)

        // File 2: Buffer with 30 lines, 1 excerpt (0..<15)
        let f2Lines = (0..<30).map { "func f2_line_\($0)() {}" }
        let buf2 = Buffer(filePath: "File2.swift", text: f2Lines.joined(separator: "\n"), language: "swift", startLineNumber: 1)
        mb.addBuffer(buf2)

        let exc2 = Excerpt(bufferId: buf2.id, filePath: "File2.swift", bufferRange: 0..<15, hunk: nil, isCollapsed: false, isFileStart: true)
        mb.addExcerpt(exc2)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        XCTAssertEqual(mb.excerpts.count, 3)

        // Verify all code lines have valid bufferLocations
        for row in 0..<dm.codeLineCount {
            let loc = dm.bufferLocation(for: MultiBufferPoint(row: row, column: 0))
            XCTAssertNotNil(loc, "Location must be valid for row \(row)")
        }

        // Expand excerpt 0 down by 10 lines (0..<20)
        mb.expandExcerpt(at: 0, up: 0, down: 10)
        dm.rebuild()

        // Excerpt 0 (0..<20) and Excerpt 1 (20..<30) should now be merged by mergeAdjacentExcerpts()!
        XCTAssertEqual(mb.excerpts.count, 2)
        XCTAssertEqual(mb.excerpts[0].filePath, "File1.swift")
        XCTAssertEqual(mb.excerpts[0].bufferRange, 0..<30)
        XCTAssertEqual(mb.excerpts[1].filePath, "File2.swift")

        // CRITICAL CHECK: Make sure all code lines in File2 now have excerptIndex == 1 (not stale 2!)
        for row in 0..<dm.codeLineCount {
            guard let loc = dm.bufferLocation(for: MultiBufferPoint(row: row, column: 0)) else {
                XCTFail("Location became nil for row \(row) after expansion/merge!")
                continue
            }
            if loc.buffer.filePath == "File2.swift" {
                XCTAssertEqual(loc.excerptIndex, 1, "File2 excerptIndex must be 1 after merge of File1 excerpts")
            } else {
                XCTAssertEqual(loc.excerptIndex, 0, "File1 excerptIndex must be 0")
            }
        }

        // Expand again multiple times
        mb.expandExcerpt(at: 1, up: 0, down: 5)
        dm.rebuild()

        for row in 0..<dm.codeLineCount {
            let loc = dm.bufferLocation(for: MultiBufferPoint(row: row, column: 0))
            XCTAssertNotNil(loc, "Location must be valid for row \(row)")
        }

        // Toggle collapse on File1
        mb.toggleCollapse(at: 0)
        dm.rebuild()

        // File2 should still be completely valid
        for row in 0..<dm.codeLineCount {
            guard let loc = dm.bufferLocation(for: MultiBufferPoint(row: row, column: 0)) else {
                XCTFail("Location became nil after collapsing File1 for row \(row)")
                continue
            }
            XCTAssertEqual(loc.buffer.filePath, "File2.swift")
            XCTAssertEqual(loc.excerptIndex, 1)
        }

        // Toggle back to expand File
        mb.toggleCollapse(at: 0)
        dm.rebuild()
        XCTAssertEqual(mb.excerpts[0].isCollapsed, false)
        for row in 0..<dm.codeLineCount {
            let loc = dm.bufferLocation(for: MultiBufferPoint(row: row, column: 0))
            XCTAssertNotNil(loc)
        }
    }

    func testExpandDownAndToggleCollapseSubsequentHeader() {
        let text1 = (0..<100).map { "FileA line \($0)" }.joined(separator: "\n")
        let text2 = (0..<50).map { "justfile line \($0)" }.joined(separator: "\n")
        let text3 = (0..<50).map { "FileC line \($0)" }.joined(separator: "\n")

        let buf1 = Buffer(filePath: "FileA.swift", text: text1)
        let buf2 = Buffer(filePath: "justfile", text: text2)
        let buf3 = Buffer(filePath: "FileC.swift", text: text3)

        let mb = MultiBuffer()
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)
        mb.addBuffer(buf3)

        // FileA has two excerpts that can merge upon expansion
        let exc1A = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<10, isFileStart: true)
        let exc1B = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 15..<25, isFileStart: false)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "justfile", bufferRange: 0..<10, isFileStart: true)
        let exc3 = Excerpt(bufferId: buf3.id, filePath: "FileC.swift", bufferRange: 0..<10, isFileStart: true)

        mb.setExcerpts([exc1A, exc1B, exc2, exc3])
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        dm.rebuild()

        XCTAssertEqual(mb.excerpts.count, 4)

        // 1. Expand excerpt 0 down by 5 lines (0..<15) -> merges exc1A and exc1B into 0..<25
        mb.expandExcerpt(at: 0, up: 0, down: 5)
        dm.rebuild()

        // Excerpts count reduced from 4 to 3 (exc2 "justfile" is now at index 1)
        XCTAssertEqual(mb.excerpts.count, 3)
        XCTAssertEqual(mb.excerpts[0].filePath, "FileA.swift")
        XCTAssertEqual(mb.excerpts[1].filePath, "justfile")
        XCTAssertEqual(mb.excerpts[2].filePath, "FileC.swift")

        // 2. Locate the DisplayLine for "justfile" header
        var justfileHeaderFound = false
        for line in dm.displayLines {
            if case .excerptHeader(let headerInfo) = line, headerInfo.filePath == "justfile" {
                justfileHeaderFound = true
                XCTAssertEqual(headerInfo.excerptIndex, 1, "Header excerptIndex must reflect current index 1 after previous merge")
                
                // 3. Simulate clicking the header via toggleCollapse(filePath:) and toggleCollapse(at:)
                mb.toggleCollapse(filePath: headerInfo.filePath)
                break
            }
        }
        XCTAssertTrue(justfileHeaderFound, "justfile header must exist in displayLines")

        dm.rebuild()

        // 4. Verify justfile is collapsed
        XCTAssertTrue(mb.excerpts[1].isCollapsed, "justfile excerpt must be collapsed")
        let justfileCodeLines = dm.displayLines.filter {
            if case .code(let c) = $0, c.excerptIndex == 1 { return true }
            return false
        }
        XCTAssertEqual(justfileCodeLines.count, 0, "No code lines should be displayed for collapsed justfile")

        // 5. Click header again to un-collapse
        mb.toggleCollapse(filePath: "justfile")
        dm.rebuild()

        XCTAssertFalse(mb.excerpts[1].isCollapsed, "justfile excerpt must be un-collapsed")
        let justfileCodeLinesAfter = dm.displayLines.filter {
            if case .code(let c) = $0, c.excerptIndex == 1 { return true }
            return false
        }
        XCTAssertGreaterThan(justfileCodeLinesAfter.count, 0, "Code lines must be restored when un-collapsed")

        // 6. Test expanding justfile down and collapsing FileC
        mb.expandExcerpt(at: 1, up: 0, down: 5)
        dm.rebuild()

        mb.toggleCollapse(filePath: "FileC.swift")
        dm.rebuild()

        XCTAssertTrue(mb.excerpts[2].isCollapsed, "FileC must be collapsed after toggle")
    }
}
