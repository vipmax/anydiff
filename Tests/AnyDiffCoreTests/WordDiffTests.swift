import XCTest
@testable import AnyDiffCore

final class WordDiffTests: XCTestCase {

    func testZeroCopyHunkHasWordDiffOnFirstDisplay() throws {
        let patch = """
        diff --git a/justfile b/justfile
        index 1111111..2222222 100644
        --- a/justfile
        +++ b/justfile
        @@ -32,1 +32,1 @@
        -# Run the test suite in Debug configuration.
        +# Run fast unit tests in Debug configuration.

        """
        let data = Data(patch.utf8)
        let file = try XCTUnwrap(GitDiffParser.shared.parseZeroCopy(data: data).first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertFalse(hunk.lineSpans.isEmpty)

        let buffer = Buffer(
            filePath: "justfile",
            storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
            startLineNumber: hunk.newRange.lowerBound,
            isLazySlice: true
        )
        let multiBuffer = MultiBuffer()
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: "justfile",
            bufferRange: 0..<buffer.lineCount,
            hunk: hunk
        ))
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: ReviewManager())
        let lines = (0..<displayMap.codeLineCount).compactMap { displayMap.codeInfo(for: $0) }
        let deleted = try XCTUnwrap(lines.first { $0.diffKind == .deleted })
        let added = try XCTUnwrap(lines.first { $0.diffKind == .added })

        XCTAssertFalse(deleted.wordDiffRanges.isEmpty)
        XCTAssertFalse(added.wordDiffRanges.isEmpty)
    }

    func testLiveDiffPreservesAppendBoundaryWithRepeatedClosingLines() {
        let oldLines = [
            "let top = 1",
            "let stableAnchor = 2",
            "func existing() {",
            "    }",
            "}",
            ""
        ]
        let appendedLines = [
            "",
            "/// New parser",
            "final class Parser {",
            "    }",
            "}"
        ]
        var newLines = oldLines
        newLines.insert("let earlierAddition = true", at: 1)
        newLines.insert(contentsOf: appendedLines, at: newLines.count - 1)

        let result = LineDiffEngine.shared.diffLinesForSlice(
            oldLines: oldLines,
            newLines: newLines,
            targetRange: 0..<newLines.count
        )
        XCTAssertEqual(result.lines.filter { $0.line.kind == .added }.count, appendedLines.count + 1)
        XCTAssertEqual(result.lines.filter { $0.line.kind == .deleted }.count, 0)

        let existingInnerBraceRow = 4
        let existingOuterBraceRow = 5
        XCTAssertEqual(result.lines.first { $0.bufferRow == existingInnerBraceRow && $0.line.kind != .deleted }?.line.kind, .unchanged,
                       "The existing closing brace must not move into the added block")
        XCTAssertEqual(result.lines.first { $0.bufferRow == existingOuterBraceRow && $0.line.kind != .deleted }?.line.kind, .unchanged,
                       "The existing outer brace must remain context")

        let appendedBlankRow = newLines.count - appendedLines.count - 1
        XCTAssertEqual(result.lines.first { $0.bufferRow == appendedBlankRow && $0.line.kind != .deleted }?.line.kind, .added,
                       "The newly appended blank line must remain part of the added block")
    }

    func testWordDiffIntraLine() {
        let oldLine = "let total = calculateSum(a, b)"
        let newLine = "let total = calculateTotal(a, b, c)"

        let (oldDiffs, newDiffs) = WordDiffEngine.shared.diffWords(oldText: oldLine, newText: newLine)

        XCTAssertFalse(oldDiffs.isEmpty)
        XCTAssertFalse(newDiffs.isEmpty)
    }

    func testWordDiffSuppressesLowSimilarityReplacement() {
        let oldLine = "let greeting = \"Привет, мир! Как твои дела сегодня?\""
        let newLine = "let title = \"Welcome to the AnyDiff application!\""

        let (oldDiffs, newDiffs) = WordDiffEngine.shared.diffWords(oldText: oldLine, newText: newLine)

        XCTAssertTrue(oldDiffs.isEmpty)
        XCTAssertTrue(newDiffs.isEmpty)
    }

    func testWordDiffCyrillicIntraLine() {
        let oldLine = "Привет, дорогой друг!"
        let newLine = "Привет, любимый друг!"

        let (oldDiffs, newDiffs) = WordDiffEngine.shared.diffWords(oldText: oldLine, newText: newLine)

        XCTAssertEqual(oldDiffs.count, 1)
        XCTAssertEqual(newDiffs.count, 1)
        if let oRange = oldDiffs.first, let nRange = newDiffs.first {
            let oStart = oldLine.utf16.index(oldLine.utf16.startIndex, offsetBy: oRange.lowerBound)
            let oEnd = oldLine.utf16.index(oldLine.utf16.startIndex, offsetBy: oRange.upperBound)
            let nStart = newLine.utf16.index(newLine.utf16.startIndex, offsetBy: nRange.lowerBound)
            let nEnd = newLine.utf16.index(newLine.utf16.startIndex, offsetBy: nRange.upperBound)
            XCTAssertEqual(String(oldLine.utf16[oStart..<oEnd]), "дорогой")
            XCTAssertEqual(String(newLine.utf16[nStart..<nEnd]), "любимый")
        }
    }

    func testWordDiffIsDisabledForMultiLineReplacement() {
        var lines = [
            DiffLine(kind: .deleted, text: "let first = oldValue"),
            DiffLine(kind: .deleted, text: "let second = oldValue"),
            DiffLine(kind: .added, text: "let first = newValue"),
            DiffLine(kind: .added, text: "let second = newValue")
        ]

        WordDiffEngine.shared.processWordDiffs(lines: &lines)

        XCTAssertTrue(lines.allSatisfy { $0.wordDiffRanges.isEmpty })
    }

    func testLiveWordDiffRecalculationOnEdit() {
        let diffSample = """
        --- a/Calculator.swift
        +++ b/Calculator.swift
        @@ -1,2 +1,2 @@
        -let total = calculateSum(a, b)
        +let total = calculateTotal(a, b)
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
        if case .code(let info) = dm.line(at: 2) {
            // Initially "calculateTotal" has word diff against deleted line
            XCTAssertFalse(info.wordDiffRanges.isEmpty)
        }

        // Live edit the added line: change "calculateTotal(a, b)" to "calculateSum(a, b)" (identical to deleted line)
        let len = mb.lineLength(at: 0)
        let editRange = MultiBufferPoint(row: 0, column: 0)..<MultiBufferPoint(row: 0, column: len)
        mb.replace(range: editRange, with: "let total = calculateSum(a, b)")
        dm.rebuild()

        if case .code(let info) = dm.line(at: 1) {
            // Since it matches the deleted line, it is now an unchanged line with no word diffs!
            XCTAssertEqual(info.diffKind, .unchanged)
            XCTAssertTrue(info.wordDiffRanges.isEmpty)
        }
    }

    func testMyersDiffCommonPrefixAndSuffixPruning() {
        var oldLines: [String] = []
        var newLines: [String] = []

        // 1000 identical lines at the top
        for i in 0..<1000 {
            oldLines.append("prefix line \(i)")
            newLines.append("prefix line \(i)")
        }

        // 2 changed lines in the middle
        oldLines.append("old middle line A")
        oldLines.append("old middle line B")
        newLines.append("new middle line A")
        newLines.append("new middle line B")

        // 1000 identical lines at the bottom
        for i in 0..<1000 {
            oldLines.append("suffix line \(i)")
            newLines.append("suffix line \(i)")
        }

        let diffLines = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines)

        // Total lines = 1000 prefix + 2 deleted + 2 added + 1000 suffix = 2004
        XCTAssertEqual(diffLines.count, 2004)
        XCTAssertEqual(diffLines[0].kind, .unchanged)
        XCTAssertEqual(diffLines[999].kind, .unchanged)
        XCTAssertEqual(diffLines[1000].kind, .deleted)
        XCTAssertEqual(diffLines[1000].text, "old middle line A")
        XCTAssertEqual(diffLines[1001].kind, .deleted)
        XCTAssertEqual(diffLines[1001].text, "old middle line B")
        XCTAssertEqual(diffLines[1002].kind, .added)
        XCTAssertEqual(diffLines[1002].text, "new middle line A")
        XCTAssertEqual(diffLines[1003].kind, .added)
        XCTAssertEqual(diffLines[1003].text, "new middle line B")
        XCTAssertEqual(diffLines[1004].kind, .unchanged)
        XCTAssertEqual(diffLines[2003].kind, .unchanged)
    }

    func testPruningCorrectness() {
        var oldLines: [String] = []
        var newLines: [String] = []

        for i in 0..<50 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        oldLines.append("func calculateOldLogic() -> Bool { return false }")
        newLines.append("func calculateNewLogic() -> Bool { return true }")

        for i in 51..<100 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        let withPruning = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: true)
        let withoutPruning = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: false)

        XCTAssertEqual(withPruning.count, withoutPruning.count)
        for i in 0..<withPruning.count {
            XCTAssertEqual(withPruning[i].kind, withoutPruning[i].kind)
            XCTAssertEqual(withPruning[i].text, withoutPruning[i].text)
            XCTAssertEqual(withPruning[i].oldLineNumber, withoutPruning[i].oldLineNumber)
            XCTAssertEqual(withPruning[i].newLineNumber, withoutPruning[i].newLineNumber)
        }
    }

    func testSliceDiffAdditionsAndDeletionsCounters() {
        let oldLines = ["line 1", "line 2", "line 3", "line 4", "line 5"]
        let newLines = ["line 1", "line 2 modified", "line 2.5 new", "line 4", "line 5", "line 6 new"]

        let result = LineDiffEngine.shared.diffLinesForSlice(
            oldLines: oldLines,
            newLines: newLines,
            targetRange: 0..<newLines.count
        )

        // Modified line 2 replaced: 1 deletion ("line 2"), 1 addition ("line 2 modified")
        // "line 2.5 new": 1 addition
        // "line 3": 1 deletion
        // "line 6 new": 1 addition
        // Total additions = 3, deletions = 2
        XCTAssertEqual(result.additions, 3)
        XCTAssertEqual(result.deletions, 2)
    }
}
