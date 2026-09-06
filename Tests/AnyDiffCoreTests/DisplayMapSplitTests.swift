import XCTest
@testable import AnyDiffCore


final class DisplayMapSplitTests: XCTestCase {
    func testDisplayMapSplitModeRebuildAndVisibleLines() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let buffer = Buffer(filePath: "test.swift", text: "header\nnew line 1\nnew line 2")
        multiBuffer.addBuffer(buffer)

        let hunk = DiffHunk(
            oldRange: 1..<3,
            newRange: 1..<4,
            header: "@@ -1,2 +1,3 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "header", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .deleted, text: "old line", oldLineNumber: 2, newLineNumber: nil),
                DiffLine(kind: .added, text: "new line 1", oldLineNumber: nil, newLineNumber: 2),
                DiffLine(kind: .added, text: "new line 2", oldLineNumber: nil, newLineNumber: 3)
            ]
        )

        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "test.swift",
            fileStatus: .modified,
            bufferRange: 0..<3,
            hunk: hunk
        ))

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)
        displayMap.layoutMode = .sideBySide

        // 1 header + 3 split rows (1 unchanged + max(1 del, 2 add) = 3)
        XCTAssertEqual(displayMap.displayLineCount, 4)

        let visible = displayMap.visibleLines(in: 0..<4)
        XCTAssertEqual(visible.count, 4)

        // Line 0: excerpt header
        if case .excerptHeader(let header) = visible[0].line {
            XCTAssertEqual(header.filePath, "test.swift")
        } else {
            XCTFail("Expected excerptHeader")
        }

        // Line 1: unchanged "header"
        if case .splitCode(let row1) = visible[1].line {
            XCTAssertEqual(row1.left.text, "header")
            XCTAssertEqual(row1.right.text, "header")
            XCTAssertFalse(row1.left.isSpacer)
            XCTAssertFalse(row1.right.isSpacer)
        } else {
            XCTFail("Expected splitCode")
        }

        // Line 2: "old line" on left, "new line 1" on right
        if case .splitCode(let row2) = visible[2].line {
            XCTAssertEqual(row2.left.text, "old line")
            XCTAssertEqual(row2.right.text, "new line 1")
            XCTAssertFalse(row2.left.isSpacer)
            XCTAssertFalse(row2.right.isSpacer)
        } else {
            XCTFail("Expected splitCode")
        }

        // Line 3: spacer on left, "new line 2" on right
        if case .splitCode(let row3) = visible[3].line {
            XCTAssertTrue(row3.left.isSpacer)
            XCTAssertEqual(row3.right.text, "new line 2")
            XCTAssertEqual(row3.right.lineNumber, 3)
        } else {
            XCTFail("Expected splitCode")
        }
    }

    func testDisplayMapSplitModeWithZeroCopyHunkLineSpans() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let diffText = "unchanged line\n-deleted line 1\n-deleted line 2\n+added line 1\n"
        let data = diffText.data(using: .utf8)!

        let span0 = LineSpan(offset: 0, length: 14, kind: .unchanged, oldLineNumber: 1, newLineNumber: 1)
        let span1 = LineSpan(offset: 15, length: 15, kind: .deleted, oldLineNumber: 2, newLineNumber: 0)
        let span2 = LineSpan(offset: 31, length: 15, kind: .deleted, oldLineNumber: 3, newLineNumber: 0)
        let span3 = LineSpan(offset: 47, length: 13, kind: .added, oldLineNumber: 0, newLineNumber: 2)

        let hunk = DiffHunk(
            oldRange: 1..<4,
            newRange: 1..<3,
            header: "@@ -1,3 +1,2 @@",
            lines: [],
            lineSpans: [span0, span1, span2, span3]
        )

        let buffer = Buffer(
            filePath: "DisplayLine.swift",
            storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
            language: "swift",
            startLineNumber: 1,
            isLazySlice: false
        )
        multiBuffer.addBuffer(buffer)

        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "DisplayLine.swift",
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide

        // 1 header + 3 split rows (1 unchanged + max(2 del, 1 add) = 3)
        XCTAssertEqual(displayMap.displayLineCount, 4)

        let visible = displayMap.visibleLines(in: 0..<4)
        XCTAssertEqual(visible.count, 4)

        // Row 1: unchanged line on both sides
        if case .splitCode(let row1) = visible[1].line {
            XCTAssertEqual(row1.left.text, "unchanged line")
            XCTAssertEqual(row1.right.text, "unchanged line")
            XCTAssertFalse(row1.left.isSpacer)
            XCTAssertFalse(row1.right.isSpacer)
        } else {
            XCTFail("Expected splitCode")
        }

        // Row 2: deleted line 1 on left, added line 1 on right
        if case .splitCode(let row2) = visible[2].line {
            XCTAssertEqual(row2.left.text, "-deleted line 1")
            XCTAssertEqual(row2.left.diffKind, .deleted)
            XCTAssertFalse(row2.left.isSpacer)

            XCTAssertEqual(row2.right.text, "+added line 1")
            XCTAssertEqual(row2.right.diffKind, .added)
            XCTAssertFalse(row2.right.isSpacer)
        } else {
            XCTFail("Expected splitCode")
        }

        // Row 3: deleted line 2 on left, spacer on right
        if case .splitCode(let row3) = visible[3].line {
            XCTAssertEqual(row3.left.text, "-deleted line 2")
            XCTAssertEqual(row3.left.diffKind, .deleted)
            XCTAssertFalse(row3.left.isSpacer)

            XCTAssertTrue(row3.right.isSpacer)
        } else {
            XCTFail("Expected splitCode")
        }
    }

    func testSplitModeMultiFileBufferLocationResolution() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let bufA = Buffer(filePath: "FileA.swift", text: "lineA1\nlineA2\nlineA3")
        multiBuffer.addBuffer(bufA)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: bufA.id,
            filePath: "FileA.swift",
            fileStatus: .modified,
            bufferRange: 0..<3,
            hunk: DiffHunk(
                oldRange: 1..<4,
                newRange: 1..<4,
                header: "@@ -1,3 +1,3 @@",
                lines: [
                    DiffLine(kind: .unchanged, text: "lineA1", oldLineNumber: 1, newLineNumber: 1),
                    DiffLine(kind: .unchanged, text: "lineA2", oldLineNumber: 2, newLineNumber: 2),
                    DiffLine(kind: .unchanged, text: "lineA3", oldLineNumber: 3, newLineNumber: 3)
                ]
            )
        ))

        let bufB = Buffer(filePath: "FileB.swift", text: "lineB1\nlineB2\nlineB3")
        multiBuffer.addBuffer(bufB)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: bufB.id,
            filePath: "FileB.swift",
            fileStatus: .added,
            bufferRange: 0..<3,
            hunk: DiffHunk(
                oldRange: 0..<0,
                newRange: 1..<4,
                header: "@@ -0,0 +1,3 @@",
                lines: [
                    DiffLine(kind: .added, text: "lineB1", oldLineNumber: nil, newLineNumber: 1),
                    DiffLine(kind: .added, text: "lineB2", oldLineNumber: nil, newLineNumber: 2),
                    DiffLine(kind: .added, text: "lineB3", oldLineNumber: nil, newLineNumber: 3)
                ]
            )
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide

        // Find visible lines for File B
        let allVisible = displayMap.visibleLines(in: 0..<displayMap.displayLineCount)

        // Find the split code line for "lineB3"
        var targetMBRow: Int? = nil
        for item in allVisible {
            if case .splitCode(let sInfo) = item.line, sInfo.right.text == "lineB3" {
                targetMBRow = sInfo.right.multiBufferRow
                break
            }
        }

        XCTAssertNotNil(targetMBRow, "Should find multiBufferRow for lineB3")
        guard let mbRow = targetMBRow else { return }

        // Resolving buffer location for this row must point to FileB.swift, NOT FileA.swift!
        let loc = displayMap.bufferLocation(for: MultiBufferPoint(row: mbRow, column: 0))
        XCTAssertNotNil(loc)
        XCTAssertEqual(loc?.buffer.filePath, "FileB.swift", "Must map to FileB.swift, not FileA.swift")
        XCTAssertEqual(loc?.excerptIndex, 1, "Must map to excerptIndex 1")
        XCTAssertEqual(loc?.point.row, 2, "Must map to buffer row 2 (line 3)")
        XCTAssertFalse(loc?.isDeleted ?? true)

        let fastInfo = displayMap.lineBufferRowAndDiffKind(forCodeRow: mbRow)
        XCTAssertNotNil(fastInfo)
        XCTAssertEqual(fastInfo?.bufferRow, 2)
        XCTAssertFalse(fastInfo?.isDeleted ?? true)
    }

    func testFoldExpandPreservesHunkDiffWithoutLargeDeletions() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var fileLines: [String] = []
        for i in 1...20 {
            fileLines.append("line \(i)")
        }
        let filePath = "TestFile.swift"
        let fullPath = tempDir.appendingPathComponent(filePath).path
        try fileLines.joined(separator: "\n").write(toFile: fullPath, atomically: true, encoding: .utf8)

        let diffText = """
--- a/TestFile.swift
+++ b/TestFile.swift
@@ -5,4 +5,4 @@
 line 5
-old line 6
+line 6
 line 7
"""
        let data = Data(diffText.utf8)
        let files = GitDiffParser.shared.parseZeroCopy(data: data)
        let file = try XCTUnwrap(files.first)
        let hunk = try XCTUnwrap(file.hunks.first)

        let mb = MultiBuffer()
        mb.baseDirectory = tempDir.path
        mb.setContentMode(.diff)

        let buffer = Buffer(
            filePath: filePath,
            storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
            language: "swift",
            startLineNumber: hunk.newRange.lowerBound,
            fullDiskPath: fullPath,
            isLazySlice: true
        )
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: filePath,
            fileStatus: .modified,
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk,
            isCollapsed: false,
            isFileStart: true
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        dm.layoutMode = .sideBySide
        dm.rebuild()

        // Expand excerpt down by 3 lines
        mb.expandExcerpt(at: 0, up: 0, down: 3)
        dm.rebuild()

        let loc0 = dm.excerptLocations[0]
        let visibleTarget = dm.visibleLines(in: loc0.displayRange)

        // Verify that the expanded lines are unchanged and there are no giant deletion blocks
        let expandedLine = visibleTarget.first(where: { line in
            if case .splitCode(let s) = line.line {
                return s.right.text == "line 8"
            }
            return false
        })
        XCTAssertNotNil(expandedLine, "Expanded line 8 must be present in split view")
        if case .splitCode(let s)? = expandedLine?.line {
            XCTAssertEqual(s.left.diffKind, .unchanged)
            XCTAssertEqual(s.right.diffKind, .unchanged)
            XCTAssertEqual(s.right.text, "line 8")
        }
    }

    func testTextContentModeForcesUnifiedModeRegardlessOfLayoutMode() {
        let mb = MultiBuffer()
        mb.setContentMode(.text)
        let buffer = Buffer(filePath: "search_match.swift", text: "let a = 1\nlet b = 2\nlet c = 3")
        mb.addBuffer(buffer)
        mb.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "search_match.swift",
            fileStatus: .modified,
            bufferRange: 0..<3
        ))

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        dm.layoutMode = .sideBySide
        dm.rebuild()

        // Although layoutMode is set to .sideBySide, because contentMode is .text (e.g. search results),
        // effectiveLayoutMode must be .unified and visibleLines must produce .code lines, not .splitCode.
        XCTAssertEqual(dm.effectiveLayoutMode, .unified)

        let visible = dm.visibleLines(in: 0..<dm.displayLineCount)
        let hasSplitCode = visible.contains { line in
            if case .splitCode = line.line { return true }
            return false
        }
        XCTAssertFalse(hasSplitCode, "Plain text content (e.g. search multiBuffer) must not use splitCode lines")

        let hasUnifiedCode = visible.contains { line in
            if case .code = line.line { return true }
            return false
        }
        XCTAssertTrue(hasUnifiedCode, "Plain text content must use standard unified .code lines")
    }

    func testLineBufferRowAndDiffKindAndVisualPointInSplitMode() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        let hunk = DiffHunk(
            oldRange: 1..<5,
            newRange: 1..<5,
            header: "@@ -1,4 +1,4 @@",
            lines: [
                DiffLine(kind: .unchanged, text: "line 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .deleted, text: "old line 2", oldLineNumber: 2, newLineNumber: nil),
                DiffLine(kind: .deleted, text: "old line 3", oldLineNumber: 3, newLineNumber: nil),
                DiffLine(kind: .added, text: "new line 2", oldLineNumber: nil, newLineNumber: 2),
                DiffLine(kind: .added, text: "new line 3", oldLineNumber: nil, newLineNumber: 3),
                DiffLine(kind: .unchanged, text: "line 4", oldLineNumber: 4, newLineNumber: 4),
            ]
        )

        let buffer = Buffer(filePath: "Sample.swift", text: "line 1\nnew line 2\nnew line 3\nline 4")
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "Sample.swift",
            fileStatus: .modified,
            bufferRange: 0..<4,
            hunk: hunk
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()

        // 6 unified lines aligned into 4 split rows:
        // Row 0: unchanged "line 1"          -> bufferRow 0
        // Row 1: "old line 2" / "new line 2" -> bufferRow 1
        // Row 2: "old line 3" / "new line 3" -> bufferRow 2
        // Row 3: unchanged "line 4"          -> bufferRow 3
        XCTAssertEqual(displayMap.codeLineCount, 4)

        // Verify lineBufferRowAndDiffKind for each codeRow in Split Mode
        let row0 = displayMap.lineBufferRowAndDiffKind(forCodeRow: 0)
        XCTAssertEqual(row0?.bufferRow, 0)
        XCTAssertEqual(row0?.isDeleted, false)

        let row1 = displayMap.lineBufferRowAndDiffKind(forCodeRow: 1)
        XCTAssertEqual(row1?.bufferRow, 1)
        XCTAssertEqual(row1?.isDeleted, false)

        let row2 = displayMap.lineBufferRowAndDiffKind(forCodeRow: 2)
        XCTAssertEqual(row2?.bufferRow, 2)
        XCTAssertEqual(row2?.isDeleted, false)

        let row3 = displayMap.lineBufferRowAndDiffKind(forCodeRow: 3)
        XCTAssertEqual(row3?.bufferRow, 3, "Row 3 must map to bufferRow 3, not hunk line 3 (which was an added line)")
        XCTAssertEqual(row3?.isDeleted, false)

        // Verify visualPoint resolution using binary search!
        let vPoint = displayMap.visualPoint(for: buffer.id, bufferPoint: BufferPoint(row: 3, column: 0))
        XCTAssertNotNil(vPoint)
        XCTAssertEqual(vPoint?.row, 3, "Visual point for buffer row 3 must resolve to codeRow 3 in split mode")
    }

    func testFastSourceLocationAndCursorPreservationInSplitMode() {
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(.diff)

        // Hunk resembling the user's scenario: 2 deleted, 7 added, then unchanged line 162, 163, 164
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
                DiffLine(kind: .added, text: "", oldLineNumber: nil, newLineNumber: 164),
            ]
        )

        let buffer = Buffer(filePath: "DisplayLine.swift", text: "add 1\nadd 2\nadd 3\nadd 4\nadd 5\nadd 6\nadd 7\n    }\n\n")
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "DisplayLine.swift",
            fileStatus: .modified,
            bufferRange: 0..<10,
            hunk: hunk
        ))

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        displayMap.layoutMode = .sideBySide
        displayMap.rebuild()

        // In Split mode:
        // Rows 0..6: 2 deletions aligned with first 2 additions, remaining 5 additions
        // Row 7: "    }" (line 162)
        // Row 8: empty (line 163)
        // Row 9: added empty (line 164)
        XCTAssertEqual(displayMap.codeLineCount, 10)

        // Row 9 must resolve to line 164, NEVER line 162!
        let loc9 = displayMap.fastSourceLocation(forCodeRow: 9)
        XCTAssertNotNil(loc9)
        XCTAssertEqual(loc9?.lineNumber, 164, "Code row 9 must resolve to line 164, not shifted backwards to 162")

        let resolvedRow = displayMap.codeRow(forFilePath: "DisplayLine.swift", lineNumber: 164)
        XCTAssertEqual(resolvedRow, 9, "Restoring cursor for line 164 must target code row 9")

        // Row 7 must resolve to line 162
        let loc7 = displayMap.fastSourceLocation(forCodeRow: 7)
        XCTAssertEqual(loc7?.lineNumber, 162)
    }
}
