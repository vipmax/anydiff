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

    func testLazyPromotionOnEditAndAtomicSaving() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var originalLines: [String] = []
        for i in 1...50 {
            originalLines.append("func step\(i)() { print(\(i)) }")
        }
        let fullPath = tempDir.appendingPathComponent("LazyPromo.swift").path
        try originalLines.joined(separator: "\n").write(toFile: fullPath, atomically: true, encoding: .utf8)

        let mb = MultiBuffer()

        // Initialize lazy slice buffer at line 10
        let hunkLines = [originalLines[9], originalLines[10]]
        let buf = Buffer(filePath: "LazyPromo.swift", lines: hunkLines, baselineLines: hunkLines, startLineNumber: 10, fullDiskPath: fullPath, isLazySlice: true)
        buf.isFullFile = false
        mb.addBuffer(buf)

        let ex = Excerpt(bufferId: buf.id, filePath: "LazyPromo.swift", fileStatus: .modified, bufferRange: 0..<2)
        mb.addExcerpt(ex)

        XCTAssertTrue(buf.isLazySlice)
        XCTAssertFalse(buf.isFullFile)
        XCTAssertEqual(buf.lineCount, 2)

        // Perform edit in the lazy buffer: insert text
        let editPt = MultiBufferPoint(row: 0, column: hunkLines[0].count)
        mb.replace(range: editPt..<editPt, with: "\n    // newly added line in step10")

        // Buffer should now be promoted to full file!
        XCTAssertFalse(buf.isLazySlice)
        XCTAssertTrue(buf.isFullFile)
        XCTAssertEqual(buf.lineCount, 51)
        XCTAssertEqual(buf.startLineNumber, 1)

        // Excerpt should now point to full file range (9..<12)
        XCTAssertEqual(mb.excerpts[0].bufferRange, 9..<12)

        // Save to disk
        try buf.saveToFile()

        // Verify disk contents
        let diskText = try String(contentsOfFile: fullPath, encoding: .utf8)
        let diskLines = diskText.components(separatedBy: "\n")
        XCTAssertEqual(diskLines.count, 51)
        XCTAssertEqual(diskLines[0], "func step1() { print(1) }")
        XCTAssertEqual(diskLines[9], "func step10() { print(10) }")
        XCTAssertEqual(diskLines[10], "    // newly added line in step10")
        XCTAssertEqual(diskLines[11], "func step11() { print(11) }")
        XCTAssertEqual(diskLines[50], "func step50() { print(50) }")
    }

    func testEditingLargeZeroCopyAdditionPreservesExistingDiff() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalLines = (1...200).map { "let original_\($0) = \($0)" }
        let addedLines = (1...159).map { "public func generated_\($0)() { return }" }
        var currentLines = originalLines
        currentLines.insert(contentsOf: addedLines, at: 113)

        let fileURL = tempDir.appendingPathComponent("LargeAddition.swift")
        try currentLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        var diffLines = [
            "diff --git a/LargeAddition.swift b/LargeAddition.swift",
            "--- a/LargeAddition.swift",
            "+++ b/LargeAddition.swift",
            "@@ -111,6 +111,165 @@"
        ]
        diffLines.append(contentsOf: originalLines[110..<113].map { " \($0)" })
        diffLines.append(contentsOf: addedLines.map { "+\($0)" })
        diffLines.append(contentsOf: originalLines[113..<116].map { " \($0)" })
        let diffData = Data((diffLines.joined(separator: "\n") + "\n").utf8)

        let parsedFiles = GitDiffParser.shared.parseZeroCopy(data: diffData)
        let hunk = try XCTUnwrap(parsedFiles.first?.hunks.first)
        XCTAssertEqual(hunk.lines.count, 0, "The regression requires the zero-copy LineSpan path")
        XCTAssertEqual(hunk.lineSpans.count, 165)

        let buffer = Buffer(
            filePath: "LargeAddition.swift",
            storage: .makeDiffFlat(data: diffData, spans: hunk.lineSpans, side: .new),
            totalAdditions: 159,
            totalDeletions: 0,
            startLineNumber: hunk.newRange.lowerBound,
            fullDiskPath: fileURL.path,
            diskFileLineCount: currentLines.count,
            isLazySlice: true
        )

        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "LargeAddition.swift",
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        XCTAssertEqual((0..<displayMap.codeLineCount).compactMap { displayMap.codeInfo(for: $0) }.filter { $0.diffKind == .added }.count, 159)

        // Edit one of the already-added lines, matching the UI bug: a single digit
        // must not make the other 158 green lines disappear after lazy promotion.
        let editedRow = 3
        let insertionPoint = MultiBufferPoint(row: editedRow, column: addedLines[0].count)
        multiBuffer.replace(range: insertionPoint..<insertionPoint, with: "1")
        displayMap.rebuild()

        XCTAssertEqual(buffer.baselineLines, originalLines)
        let afterEdit = (0..<displayMap.codeLineCount).compactMap { displayMap.codeInfo(for: $0) }
        XCTAssertEqual(afterEdit.filter { $0.diffKind == .added }.count, 159)
        XCTAssertEqual(afterEdit.filter { $0.diffKind == .deleted }.count, 0)
        XCTAssertTrue(afterEdit.contains { $0.text == addedLines[0] + "1" && $0.diffKind == .added })
    }

    func testEditingLastOfMultipleZeroCopyHunksPreservesAllDiffBoundaries() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var originalLines = (1...15).map { "let line_\($0) = \($0)" }
        originalLines.append(contentsOf: ["func existing() {", "    }", "}", ""])

        var currentLines = originalLines
        currentLines.insert(contentsOf: ["let first_addition = true", "let second_addition = true"], at: 2)
        currentLines.insert("let middle_addition = true", at: 12)
        currentLines.insert(contentsOf: ["", "/// New parser", "final class Parser {", "    }", "}"], at: currentLines.count - 1)

        let fileURL = tempDir.appendingPathComponent("MultipleHunks.swift")
        try currentLines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let diffText = """
        diff --git a/MultipleHunks.swift b/MultipleHunks.swift
        --- a/MultipleHunks.swift
        +++ b/MultipleHunks.swift
        @@ -2,2 +2,4 @@
         let line_2 = 2
        +let first_addition = true
        +let second_addition = true
         let line_3 = 3
        @@ -10,2 +12,3 @@
         let line_10 = 10
        +let middle_addition = true
         let line_11 = 11
        @@ -16,4 +19,9 @@
         func existing() {
             }
         }
        +
        +/// New parser
        +final class Parser {
        +    }
        +}
        \(String(repeating: " ", count: 1))
        """
        let diffData = Data(diffText.utf8)
        let parsedFiles = GitDiffParser.shared.parseZeroCopy(data: diffData)
        let parsedFile = try XCTUnwrap(parsedFiles.first)
        XCTAssertEqual(parsedFile.hunks.count, 3)
        XCTAssertTrue(parsedFile.hunks.allSatisfy { $0.lines.isEmpty && !$0.lineSpans.isEmpty })

        let multiBuffer = MultiBuffer()
        var hunkBuffers: [Buffer] = []
        for hunk in parsedFile.hunks {
            let additions = hunk.lineSpans.filter { $0.kind == .added }.count
            let deletions = hunk.lineSpans.filter { $0.kind == .deleted }.count
            let buffer = Buffer(
                filePath: "MultipleHunks.swift",
                storage: .makeDiffFlat(data: diffData, spans: hunk.lineSpans, side: .new),
                totalAdditions: additions,
                totalDeletions: deletions,
                startLineNumber: hunk.newRange.lowerBound,
                fullDiskPath: fileURL.path,
                diskFileLineCount: currentLines.count,
                isLazySlice: true
            )
            multiBuffer.addBuffer(buffer)
            multiBuffer.addExcerpt(Excerpt(
                bufferId: buffer.id,
                filePath: "MultipleHunks.swift",
                fileStatus: .modified,
                bufferRange: 0..<buffer.lineCount,
                hunk: hunk
            ))
            hunkBuffers.append(buffer)
        }

        let targetBuffer = try XCTUnwrap(hunkBuffers.last)
        let rowInLastHunk = 4 // "/// New parser"
        let multiBufferRow = hunkBuffers.dropLast().reduce(0) { $0 + $1.lineCount } + rowInLastHunk
        let insertionPoint = MultiBufferPoint(row: multiBufferRow, column: "/// New parser".count)
        multiBuffer.replace(range: insertionPoint..<insertionPoint, with: "1")

        XCTAssertEqual(targetBuffer.baselineLines, originalLines)
        XCTAssertEqual(multiBuffer.buffers.count, 1, "All excerpts should share the promoted full-file buffer")
        XCTAssertTrue(multiBuffer.excerpts.allSatisfy { $0.bufferId == targetBuffer.id })

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let visibleCode = (0..<displayMap.codeLineCount).compactMap { displayMap.codeInfo(for: $0) }
        XCTAssertEqual(visibleCode.filter { $0.diffKind == .added }.count, 8)
        XCTAssertEqual(visibleCode.filter { $0.diffKind == .deleted }.count, 0)
        XCTAssertEqual(visibleCode.first { $0.bufferRow == 19 }?.diffKind, .unchanged)
        XCTAssertEqual(visibleCode.first { $0.bufferRow == 20 }?.diffKind, .unchanged)
        XCTAssertEqual(visibleCode.first { $0.text == "/// New parser1" }?.diffKind, .added)
    }

    func testLazyPromotionOnExpand() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var originalLines: [String] = []
        for i in 1...50 {
            originalLines.append("item_\(i)")
        }
        let fullPath = tempDir.appendingPathComponent("LazyExpand.swift").path
        try originalLines.joined(separator: "\n").write(toFile: fullPath, atomically: true, encoding: .utf8)

        let mb = MultiBuffer()

        // Hunk at line 20 (items 20..22)
        let hunkLines = ["item_20", "item_21", "item_22"]
        let buf = Buffer(filePath: "LazyExpand.swift", lines: hunkLines, baselineLines: hunkLines, startLineNumber: 20, fullDiskPath: fullPath, isLazySlice: true)
        buf.isFullFile = false
        mb.addBuffer(buf)

        let ex = Excerpt(bufferId: buf.id, filePath: "LazyExpand.swift", fileStatus: .modified, bufferRange: 0..<3)
        mb.addExcerpt(ex)

        XCTAssertTrue(buf.isLazySlice)

        // Expand up 5 lines and down 5 lines
        let result = mb.expandExcerpt(at: 0, up: 5, down: 5)
        XCTAssertEqual(result.linesAddedUp, 5)
        XCTAssertEqual(result.linesAddedDown, 5)

        // Buffer should be promoted to full file with 50 lines
        XCTAssertFalse(buf.isLazySlice)
        XCTAssertTrue(buf.isFullFile)
        XCTAssertEqual(buf.lineCount, 50)

        // Excerpt range expanded from 19..<22 to 14..<27 (13 lines)
        XCTAssertEqual(mb.excerpts[0].bufferRange, 14..<27)
        XCTAssertEqual(mb.excerpts[0].bufferRange.count, 13)

        // First visible line is item_15 (index 14) and last is item_27 (index 26)
        XCTAssertEqual(buf.lines[14], "item_15")
        XCTAssertEqual(buf.lines[26], "item_27")
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

    func testLazyLocalLastHunkShowsExpandWithoutReadingFileLineCount() throws {
        let visibleLines = (21...30).map { "line \($0)" }
        let hunkLines = visibleLines.enumerated().map { offset, text in
            DiffLine(kind: .unchanged, text: text, oldLineNumber: 21 + offset, newLineNumber: 21 + offset)
        }
        let hunk = DiffHunk(
            oldRange: 21..<31,
            newRange: 21..<31,
            header: "@@ -21,10 +21,10 @@",
            lines: hunkLines
        )
        let buffer = Buffer(
            filePath: "LongFile.swift",
            lines: visibleLines,
            startLineNumber: 21,
            fullDiskPath: "/path/is/intentionally/not/read/LongFile.swift",
            diskFileLineCount: nil,
            isLazySlice: true
        )

        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "LongFile.swift",
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let location = try XCTUnwrap(displayMap.excerptLocations.first)
        XCTAssertNil(buffer.diskFileLineCount)
        XCTAssertEqual(location.bottomHidden, 0)
        XCTAssertTrue(location.hasBottomGap)
        XCTAssertEqual(displayMap.codeLines.last?.expandInfo?.direction, .down)
        let bottomGap = displayMap.displayLines.compactMap { line -> DisplayFoldGapInfo? in
            guard case .foldGap(let info) = line, !info.isTopGap else { return nil }
            return info
        }.first
        XCTAssertEqual(bottomGap?.hiddenCount, 0)
        XCTAssertEqual(bottomGap?.isCountKnown, false, "Unknown tails must not show a fake hidden-line count")
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

    func testCollapsedFilePreservationAcrossDiffReload() {
        let mb = MultiBuffer()
        let buf1 = Buffer(filePath: "main.swift", text: "line 1\nline 2\nline 3")
        let buf2 = Buffer(filePath: "DisplayMap.swift", text: "func a() {}\nfunc b() {}\nfunc c() {}")
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        let exc1 = Excerpt(bufferId: buf1.id, filePath: "main.swift", bufferRange: 0..<3, isFileStart: true)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "DisplayMap.swift", bufferRange: 0..<3, isFileStart: true)
        mb.setExcerpts([exc1, exc2])

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        dm.rebuild()

        // 1. User collapses main.swift
        mb.toggleCollapse(filePath: "main.swift")
        dm.rebuild()
        XCTAssertTrue(mb.excerpts[0].isCollapsed, "main.swift must be collapsed")
        XCTAssertFalse(mb.excerpts[1].isCollapsed, "DisplayMap.swift must remain expanded")

        // 2. Simulate diff reload with modified main.swift (gained 5 new lines)
        let collapsedFilePaths = Set(mb.excerpts.filter { $0.isCollapsed }.map { $0.filePath })
        XCTAssertTrue(collapsedFilePaths.contains("main.swift"))

        // Rebuild MultiBuffer with new contents
        let newMB = MultiBuffer()
        let newBuf1 = Buffer(filePath: "main.swift", text: "line 1\nline 2\nnew 1\nnew 2\nnew 3\nnew 4\nline 3")
        let newBuf2 = Buffer(filePath: "DisplayMap.swift", text: "func a() {}\nfunc b() {}\nfunc c() {}")
        newMB.addBuffer(newBuf1)
        newMB.addBuffer(newBuf2)

        let newExc1 = Excerpt(
            bufferId: newBuf1.id,
            filePath: "main.swift",
            bufferRange: 0..<7,
            isCollapsed: collapsedFilePaths.contains("main.swift"),
            isFileStart: true
        )
        let newExc2 = Excerpt(
            bufferId: newBuf2.id,
            filePath: "DisplayMap.swift",
            bufferRange: 0..<3,
            isCollapsed: collapsedFilePaths.contains("DisplayMap.swift"),
            isFileStart: true
        )
        newMB.setExcerpts([newExc1, newExc2])

        let newDM = DisplayMap(multiBuffer: newMB, reviewManager: rm)
        newDM.rebuild()

        // 3. Verify main.swift is STILL collapsed after reload!
        XCTAssertTrue(newMB.excerpts[0].isCollapsed, "main.swift must preserve collapsed state across reload")
        XCTAssertFalse(newMB.excerpts[1].isCollapsed, "DisplayMap.swift must preserve expanded state across reload")

        // Verify DisplayMap only renders the header for main.swift, not its 7 lines
        let mainCodeLines = newDM.displayLines.filter {
            if case .code(let c) = $0, c.excerptIndex == 0 { return true }
            return false
        }
        XCTAssertEqual(mainCodeLines.count, 0, "No code lines should be visible for collapsed main.swift")

        // Verify DisplayMap.swift code rows are intact
        let displayMapCodeLines = newDM.displayLines.filter {
            if case .code(let c) = $0, c.excerptIndex == 1 { return true }
            return false
        }
        XCTAssertEqual(displayMapCodeLines.count, 3, "DisplayMap.swift code lines must be visible")
    }

    func testCursorAndScrollAnchorPreservationAcrossReload() {
        let mb = MultiBuffer()
        let buf1 = Buffer(filePath: "FileA.swift", text: "A1\nA2\nA3")
        let buf2 = Buffer(filePath: "FileB.swift", text: "B1\nB2\nB3\nB4\nB5")
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        let exc1 = Excerpt(bufferId: buf1.id, filePath: "FileA.swift", bufferRange: 0..<3, isFileStart: true)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "FileB.swift", bufferRange: 0..<5, isFileStart: true)
        mb.setExcerpts([exc1, exc2])

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        dm.rebuild()

        // Cursor is at FileB.swift line 3 (B3)
        let targetRow = dm.codeRow(forFilePath: "FileB.swift", lineNumber: 3)
        XCTAssertNotNil(targetRow)
        let targetDisplayIdx = dm.displayLineIndex(forFilePath: "FileB.swift", lineNumber: 3)
        XCTAssertNotNil(targetDisplayIdx)

        // Now FileA.swift gains 20 lines in a diff reload
        let newMB = MultiBuffer()
        let linesA = (1...25).map { "A\($0)" }.joined(separator: "\n")
        let newBuf1 = Buffer(filePath: "FileA.swift", text: linesA)
        let newBuf2 = Buffer(filePath: "FileB.swift", text: "B1\nB2\nB3\nB4\nB5")
        newMB.addBuffer(newBuf1)
        newMB.addBuffer(newBuf2)

        let newExc1 = Excerpt(bufferId: newBuf1.id, filePath: "FileA.swift", bufferRange: 0..<25, isFileStart: true)
        let newExc2 = Excerpt(bufferId: newBuf2.id, filePath: "FileB.swift", bufferRange: 0..<5, isFileStart: true)
        newMB.setExcerpts([newExc1, newExc2])

        let newDM = DisplayMap(multiBuffer: newMB, reviewManager: rm)
        newDM.rebuild()

        // Locate FileB.swift line 3 in new DisplayMap
        let restoredRow = newDM.codeRow(forFilePath: "FileB.swift", lineNumber: 3)
        XCTAssertNotNil(restoredRow)
        let restoredCodeInfo = newDM.codeInfo(for: restoredRow!)
        XCTAssertEqual(restoredCodeInfo?.text, "B3")
        XCTAssertEqual(restoredCodeInfo?.bufferRow, 2)

        // Check header display line index lookup
        let headerLineIdx = newDM.displayLineIndex(forFilePath: "FileB.swift", lineNumber: nil, isHeader: true)
        XCTAssertNotNil(headerLineIdx)
        if case .excerptHeader(let h) = newDM.displayLine(at: headerLineIdx!) {
            XCTAssertEqual(h.filePath, "FileB.swift")
        } else {
            XCTFail("Must find header line for FileB.swift")
        }
    }

    func testPerFileSelfSaveSuppressionAndDirtyCheck() {
        let mb = MultiBuffer()
        let bufA = Buffer(filePath: "FileA.swift", text: "line 1\nline 2")
        let bufB = Buffer(filePath: "FileB.swift", text: "line 1\nline 2")
        mb.addBuffer(bufA)
        mb.addBuffer(bufB)

        // Initially neither file is dirty or self-saved
        XCTAssertFalse(mb.isFileDirty(filePath: "FileA.swift"))
        XCTAssertFalse(mb.isFileDirty(filePath: "FileB.swift"))
        XCTAssertFalse(mb.isSelfSavedRecently(filePath: "FileA.swift"))
        XCTAssertFalse(mb.isSelfSavedRecently(filePath: "FileB.swift"))

        // User edits FileA.swift
        let excA = Excerpt(bufferId: bufA.id, filePath: "FileA.swift", bufferRange: 0..<2, isFileStart: true)
        mb.setExcerpts([excA])
        mb.replace(range: MultiBufferPoint(row: 0, column: 0)..<MultiBufferPoint(row: 0, column: 4), with: "edit")

        // Only FileA.swift is dirty, FileB.swift is NOT dirty
        XCTAssertTrue(mb.isFileDirty(filePath: "FileA.swift"))
        XCTAssertFalse(mb.isFileDirty(filePath: "FileB.swift"))

        // Record self-save on FileA.swift
        mb.recordSelfSave(for: "FileA.swift")
        XCTAssertTrue(mb.isSelfSavedRecently(filePath: "FileA.swift"))
        XCTAssertFalse(mb.isSelfSavedRecently(filePath: "FileB.swift"), "External file must NOT be marked as self-saved")

        // Also test relative/absolute path matching
        XCTAssertTrue(mb.isSelfSavedRecently(filePath: "/some/deep/path/FileA.swift"))
    }

    func testExactSelfSaveDoesNotSuppressSameBasenameInAnotherDirectory() {
        let mb = MultiBuffer()
        mb.baseDirectory = "/tmp/anydiff-watch"
        mb.recordSelfSave(for: "Sources/File.swift")

        XCTAssertTrue(mb.isSelfSavedRecentlyExact(filePath: "/tmp/anydiff-watch/Sources/File.swift"))
        XCTAssertFalse(mb.isSelfSavedRecentlyExact(filePath: "/tmp/anydiff-watch/Tests/File.swift"))
    }

    func testSelfSaveEventIsAllowedWhenAnotherEditorChangedDiskText() throws {
        let filePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("anydiff-self-save-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        let buffer = Buffer(filePath: filePath, text: "local\n")
        buffer.isFullFile = true
        buffer.fullDiskPath = filePath
        let mb = MultiBuffer()
        mb.addBuffer(buffer)
        try "local\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        mb.recordSelfSave(for: filePath)

        XCTAssertTrue(mb.shouldIgnoreSelfSavedEvent(filePath: filePath, diskPath: filePath))

        try "zed\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        XCTAssertFalse(mb.shouldIgnoreSelfSavedEvent(filePath: filePath, diskPath: filePath))
    }

    func testReplacingOneFilePreservesUnchangedBufferAndExcerptIdentity() {
        let mb = MultiBuffer()
        let oldA = Buffer(filePath: "FileA.swift", text: "old A")
        let oldB = Buffer(filePath: "FileB.swift", text: "stable B")
        let exA = Excerpt(bufferId: oldA.id, filePath: oldA.filePath, bufferRange: 0..<1)
        let exB = Excerpt(bufferId: oldB.id, filePath: oldB.filePath, bufferRange: 0..<1)
        mb.addBuffer(oldA)
        mb.addBuffer(oldB)
        mb.setExcerpts([exA, exB])

        let newA = Buffer(filePath: "FileA.swift", text: "new A")
        let newExA = Excerpt(bufferId: newA.id, filePath: newA.filePath, bufferRange: 0..<1)
        mb.replaceFile(filePath: "FileA.swift", buffers: [newA], excerpts: [newExA])

        XCTAssertNil(mb.buffer(for: oldA.id))
        XCTAssertEqual(mb.buffer(for: oldB.id)?.id, oldB.id)
        XCTAssertEqual(mb.excerpts[1].id, exB.id)
        XCTAssertEqual(mb.excerpts[1].bufferId, oldB.id)
        XCTAssertEqual(mb.line(at: 1), "stable B")
    }

    func testRemovingBufferInvalidatesUndoAndRedoTransactions() {
        let mb = MultiBuffer()
        let old = Buffer(filePath: "old.swift", text: "old")
        mb.addBuffer(old)
        mb.addExcerpt(Excerpt(bufferId: old.id, filePath: old.filePath, bufferRange: 0..<1))

        mb.replace(
            range: MultiBufferPoint(row: 0, column: 3)..<MultiBufferPoint(row: 0, column: 3),
            with: " edit"
        )
        XCTAssertTrue(mb.undoManager.canUndo)
        _ = mb.undoManager.popUndo()
        XCTAssertTrue(mb.undoManager.canRedo)

        mb.replaceFile(filePath: old.filePath, buffers: [], excerpts: [])

        XCTAssertFalse(mb.undoManager.canUndo)
        XCTAssertFalse(mb.undoManager.canRedo)
    }

    func testTypingAfterCoalescingIntervalCreatesSeparateUndoOperation() {
        let manager = MultiBufferUndoManager()
        let bufferId = BufferId()
        let firstCursor = MultiBufferPoint(row: 0, column: 0)
        let secondCursor = MultiBufferPoint(row: 0, column: 1)
        let finalCursor = MultiBufferPoint(row: 0, column: 2)

        manager.push(transaction: EditTransaction(
            timestamp: Date(timeIntervalSince1970: 100),
            edits: [TextEdit(
                bufferId: bufferId,
                range: BufferPoint(row: 0, column: 0)..<BufferPoint(row: 0, column: 1),
                oldRange: BufferPoint(row: 0, column: 0)..<BufferPoint(row: 0, column: 0),
                oldText: "",
                newText: "a"
            )],
            cursorBefore: firstCursor,
            cursorAfter: secondCursor,
            isTyping: true
        ))
        manager.push(transaction: EditTransaction(
            timestamp: Date(timeIntervalSince1970: 101.1),
            edits: [TextEdit(
                bufferId: bufferId,
                range: BufferPoint(row: 0, column: 1)..<BufferPoint(row: 0, column: 2),
                oldRange: BufferPoint(row: 0, column: 1)..<BufferPoint(row: 0, column: 1),
                oldText: "",
                newText: "b"
            )],
            cursorBefore: secondCursor,
            cursorAfter: finalCursor,
            isTyping: true
        ))

        let second = manager.popUndo()
        XCTAssertEqual(second?.edits.count, 1)
        XCTAssertEqual(second?.edits.first?.newText, "b")
        let first = manager.popUndo()
        XCTAssertEqual(first?.edits.count, 1)
        XCTAssertEqual(first?.edits.first?.newText, "a")
    }

    func testExternalTextUpdateIsAddedAfterUserEditInUndoHistory() {
        let mb = MultiBuffer()
        let buffer = Buffer(
            filePath: "File.swift",
            text: "one\ntwo\nthree",
            baselineText: "one\ntwo\nold-three"
        )
        buffer.isFullFile = true
        mb.addBuffer(buffer)
        mb.addExcerpt(Excerpt(bufferId: buffer.id, filePath: buffer.filePath, bufferRange: 0..<3))

        mb.replace(
            range: MultiBufferPoint(row: 0, column: 3)..<MultiBufferPoint(row: 0, column: 3),
            with: "X"
        )
        XCTAssertEqual(buffer.text(), "oneX\ntwo\nthree")

        XCTAssertTrue(mb.applyExternalTextUpdate(
            filePath: buffer.filePath,
            newText: "oneXY\ntwo\nthreeZ",
            updateBaseline: false
        ))
        XCTAssertEqual(buffer.text(), "oneXY\ntwo\nthreeZ")
        XCTAssertEqual(buffer.baselineText, "one\ntwo\nold-three")

        let external = mb.undoManager.popUndo()
        XCTAssertEqual(external?.edits.count, 2)
        XCTAssertEqual(external?.edits.map(\.newText), ["oneXY\n", "threeZ"])
        let local = mb.undoManager.popUndo()
        XCTAssertEqual(local?.edits.first?.oldText, "")
        XCTAssertEqual(local?.edits.first?.newText, "X")
    }

    func testExternalTextUpdateHandlesEmptyFullFileBuffer() {
        let mb = MultiBuffer()
        let buffer = Buffer(filePath: "Empty.txt", text: "")
        buffer.isFullFile = true
        mb.addBuffer(buffer)
        mb.addExcerpt(Excerpt(bufferId: buffer.id, filePath: buffer.filePath, bufferRange: 0..<0))

        XCTAssertTrue(mb.applyExternalTextUpdate(
            filePath: buffer.filePath,
            newText: "created",
            updateBaseline: false
        ))
        XCTAssertEqual(buffer.text(), "created")
    }

    func testRenamedFileRemovesOldPathAndAddsNewPathWithoutTouchingOthers() {
        let mb = MultiBuffer()
        let old = Buffer(filePath: "old.swift", text: "renamed")
        let stable = Buffer(filePath: "stable.swift", text: "untouched")
        let oldExcerpt = Excerpt(bufferId: old.id, filePath: old.filePath, bufferRange: 0..<1)
        let stableExcerpt = Excerpt(bufferId: stable.id, filePath: stable.filePath, bufferRange: 0..<1)
        mb.addBuffer(old)
        mb.addBuffer(stable)
        mb.setExcerpts([oldExcerpt, stableExcerpt])

        mb.replaceFile(filePath: "old.swift", buffers: [], excerpts: [])
        let renamed = Buffer(filePath: "new.swift", text: "renamed")
        mb.replaceFile(
            filePath: "new.swift",
            buffers: [renamed],
            excerpts: [Excerpt(bufferId: renamed.id, filePath: "new.swift", bufferRange: 0..<1)]
        )

        XCTAssertTrue(mb.excerpts.allSatisfy { $0.filePath != "old.swift" })
        XCTAssertEqual(mb.buffer(for: stable.id)?.id, stable.id)
        XCTAssertTrue(mb.excerpts.contains { $0.filePath == "new.swift" })
    }

    func testEditChangesBufferVersionSoInFlightRefreshCannotBeApplied() {
        let mb = MultiBuffer()
        let buffer = Buffer(filePath: "FileA.swift", text: "line")
        mb.addBuffer(buffer)
        mb.addExcerpt(Excerpt(bufferId: buffer.id, filePath: buffer.filePath, bufferRange: 0..<1))

        let versionBeforeRefresh = buffer.version
        mb.replace(range: MultiBufferPoint(row: 0, column: 4)..<MultiBufferPoint(row: 0, column: 4), with: "\nnew")

        XCTAssertGreaterThan(buffer.version, versionBeforeRefresh)
        XCTAssertTrue(mb.isFileDirty(filePath: "FileA.swift"))
        // MainWindow's refresh gate uses exactly this version/dirty pair to
        // discard a stale asynchronous filesystem result.
    }

    func testLazySlicePromotionPreservesAnchorAndCursor() {
        let mb = MultiBuffer()
        let hunk1Lines = ["Hunk1 Line 10", "Hunk1 Line 11"]
        let hunk2Lines = [
            "Hunk2 Line 54",
            "Hunk2 Line 55",
            "Hunk2 Line 56",
            "Hunk2 Line 57",
            "Hunk2 Line 58",
            "Hunk2 Line 59",
            "Hunk2 Line 60"
        ]

        let buf1 = Buffer(filePath: "Sources/main.swift", lines: hunk1Lines, startLineNumber: 10, isLazySlice: true)
        let buf2 = Buffer(filePath: "Sources/main.swift", lines: hunk2Lines, startLineNumber: 54, isLazySlice: true)
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        let exc1 = Excerpt(bufferId: buf1.id, filePath: "Sources/main.swift", bufferRange: 0..<2, isFileStart: true)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "Sources/main.swift", bufferRange: 0..<7, isFileStart: false)
        mb.setExcerpts([exc1, exc2])

        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)
        dm.rebuild()

        // Locate line 60 before promotion
        let rowBefore = dm.codeRow(forFilePath: "Sources/main.swift", lineNumber: 60)
        XCTAssertNotNil(rowBefore)
        let cInfoBefore = dm.codeInfo(for: rowBefore!)
        XCTAssertEqual(cInfoBefore?.newLineNumber, 60)

        // Expand excerpt 1 (down)
        mb.expandExcerpt(at: 1, up: 0, down: 5)
        dm.rebuild()

        // Locate line 60 after promotion/expansion
        let rowAfter = dm.codeRow(forFilePath: "Sources/main.swift", lineNumber: 60)
        XCTAssertNotNil(rowAfter)
        let displayIdxAfter = dm.displayLineIndex(forFilePath: "Sources/main.swift", lineNumber: 60, isHeader: false)
        XCTAssertNotNil(displayIdxAfter)
        let cInfoAfter = dm.codeInfo(for: rowAfter!)
        XCTAssertEqual(cInfoAfter?.newLineNumber, 60)
        XCTAssertEqual(cInfoAfter?.text, "Hunk2 Line 60")
    }

    func testFirstCodeRowForFilePath() {
        let mb = MultiBuffer()
        let file1Lines = ["File1 Line 1", "File1 Line 2"]
        let file2Lines = ["File2 Line 1", "File2 Line 2"]

        let buf1 = Buffer(filePath: "Sources/A.swift", lines: file1Lines)
        let buf2 = Buffer(filePath: "Sources/B.swift", lines: file2Lines)
        mb.addBuffer(buf1)
        mb.addBuffer(buf2)

        let exc1 = Excerpt(bufferId: buf1.id, filePath: "Sources/A.swift", bufferRange: 0..<2, isFileStart: true)
        let exc2 = Excerpt(bufferId: buf2.id, filePath: "Sources/B.swift", bufferRange: 0..<2, isFileStart: true)
        mb.setExcerpts([exc1, exc2])

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        dm.rebuild()

        let firstA = dm.firstCodeRow(forFilePath: "Sources/A.swift")
        let firstB = dm.firstCodeRow(forFilePath: "Sources/B.swift")
        let firstNonExistent = dm.firstCodeRow(forFilePath: "Sources/C.swift")

        XCTAssertEqual(firstA, 0)
        XCTAssertEqual(firstB, 2)
        XCTAssertNil(firstNonExistent)
    }

    func testMaxLineCharsCalculatedFromLongLines() {
        let mb = MultiBuffer()
        let longLine = String(repeating: "A", count: 250)
        let shortLine = "Short"

        let buf = Buffer(filePath: "Sources/Long.swift", lines: [longLine, shortLine])
        mb.addBuffer(buf)

        let exc = Excerpt(bufferId: buf.id, filePath: "Sources/Long.swift", bufferRange: 0..<2, isFileStart: true)
        mb.setExcerpts([exc])

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        dm.rebuild()

        XCTAssertEqual(dm.maxLineChars, 250)
    }

    func testTextContentModeIgnoresDiffHunkAndRendersPlainLines() {
        let lines = ["first line", "second line"]
        let buffer = Buffer(
            filePath: "agent/output.txt",
            lines: lines,
            baselineLines: []
        )
        let hunk = DiffHunk(
            oldRange: 1..<1,
            newRange: 1..<3,
            header: "@@ -0,0 +1,2 @@",
            lines: lines.enumerated().map { index, line in
                DiffLine(kind: .added, text: line, newLineNumber: index + 1)
            },
            status: .added
        )

        let mb = MultiBuffer()
        mb.setContentMode(.text)
        mb.addBuffer(buffer)
        mb.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: buffer.filePath,
            fileStatus: .added,
            bufferRange: 0..<lines.count,
            hunk: hunk
        ))

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        let visibleLines = (0..<dm.codeLineCount).compactMap { dm.codeInfo(for: $0) }

        XCTAssertEqual(mb.contentMode, .text)
        XCTAssertEqual(visibleLines.map(\.text), lines)
        XCTAssertTrue(visibleLines.allSatisfy { $0.diffKind == .unchanged })
        XCTAssertTrue(visibleLines.allSatisfy { $0.wordDiffRanges.isEmpty })
    }

    func testLineRenderCachePartialInvalidation() {
        let cache = LineRenderCache()
        let attrStr = NSAttributedString(string: "hello")
        let ctLine = CTLineCreateWithAttributedString(attrStr)

        cache.set(lineIndex: 10, ctLine: ctLine)
        cache.set(lineIndex: 11, ctLine: ctLine)
        cache.set(lineIndex: 12, ctLine: ctLine)

        XCTAssertNotNil(cache.get(lineIndex: 10))
        XCTAssertNotNil(cache.get(lineIndex: 11))
        XCTAssertNotNil(cache.get(lineIndex: 12))

        // Invalidate single line
        cache.invalidate(lineIndex: 11)
        XCTAssertNotNil(cache.get(lineIndex: 10))
        XCTAssertNil(cache.get(lineIndex: 11))
        XCTAssertNotNil(cache.get(lineIndex: 12))

        // Invalidate from 10
        cache.invalidate(from: 10)
        XCTAssertNil(cache.get(lineIndex: 10))
        XCTAssertNil(cache.get(lineIndex: 12))
    }
}
