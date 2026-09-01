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

    func testWordDiffWhitespaceAndEmptyLines() {
        // 1. Empty to spaces
        let (old1, new1) = WordDiffEngine.shared.diffWords(oldText: "", newText: "    ")
        XCTAssertEqual(old1, [])
        XCTAssertEqual(new1, [0..<4])

        // 2. Spaces to empty
        let (old2, new2) = WordDiffEngine.shared.diffWords(oldText: "    ", newText: "")
        XCTAssertEqual(old2, [0..<4])
        XCTAssertEqual(new2, [])

        // 3. Tab to spaces
        let (old3, new3) = WordDiffEngine.shared.diffWords(oldText: "\t", newText: "    ")
        XCTAssertEqual(old3, [0..<1])
        XCTAssertEqual(new3, [0..<4])

        // 4. Added indentation spaces
        let (old4, new4) = WordDiffEngine.shared.diffWords(oldText: "  ", newText: "    ")
        XCTAssertEqual(old4, [])
        XCTAssertEqual(new4, [2..<4])
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

    func testWordDiffRenderCacheOperations() {
        let cache = WordDiffRenderCache()

        // 1. Initial get is empty
        XCTAssertNil(cache.get(lineIndex: 42))

        // 2. Set and get
        let ranges = [0..<5, 10..<15]
        cache.set(lineIndex: 42, wordDiffRanges: ranges)
        XCTAssertEqual(cache.get(lineIndex: 42), ranges)

        // 3. Collision / slot mapping (42 + 2048 lands on same slot)
        let otherRanges = [2..<8]
        cache.set(lineIndex: 42 + WordDiffRenderCache.slotCount, wordDiffRanges: otherRanges)
        XCTAssertEqual(cache.get(lineIndex: 42 + WordDiffRenderCache.slotCount), otherRanges)
        // Original lineIndex 42 should now be evicted/overwritten
        XCTAssertNil(cache.get(lineIndex: 42))

        // 4. Invalidation of single lineIndex
        cache.set(lineIndex: 100, wordDiffRanges: ranges)
        XCTAssertEqual(cache.get(lineIndex: 100), ranges)
        cache.invalidate(lineIndex: 100)
        XCTAssertNil(cache.get(lineIndex: 100))

        // 5. Invalidation from lineIndex
        cache.set(lineIndex: 50, wordDiffRanges: ranges)
        cache.set(lineIndex: 60, wordDiffRanges: ranges)
        cache.set(lineIndex: 70, wordDiffRanges: ranges)
        cache.invalidate(from: 60)
        XCTAssertEqual(cache.get(lineIndex: 50), ranges)
        XCTAssertNil(cache.get(lineIndex: 60))
        XCTAssertNil(cache.get(lineIndex: 70))

        // 6. Clear
        cache.clear()
        XCTAssertNil(cache.get(lineIndex: 50))
    }

    func testWordDiffEarlyExitOnLengthDisparity() {
        // High token length disparity: 44 tokens vs 15 tokens
        let oldLongLine = "        return FileIcon(systemName: \"curlybraces\", color: NSColor(red: 0.19, green: 0.47, blue: 0.78, alpha: 1.0), languageName: \"TypeScript\")"
        let newShortLine = "        return FileIcon(svg: Icons.typescript, languageName: \"TypeScript\")"

        let (oldDiffs, newDiffs) = WordDiffEngine.shared.diffWords(oldText: oldLongLine, newText: newShortLine)
        XCTAssertTrue(oldDiffs.isEmpty)
        XCTAssertTrue(newDiffs.isEmpty)
    }

    func testZeroCopyHunkMaterializationCachedAcrossDisplayQueries() throws {
        let patch = """
        diff --git a/Icons.swift b/Icons.swift
        index 1111111..2222222 100644
        --- a/Icons.swift
        +++ b/Icons.swift
        @@ -1,3 +1,3 @@
        -let swiftIcon = "swift.badge"
        +let swiftIcon = "swift.fill"
         let rustIcon = "gearshape"
        """
        let data = Data(patch.utf8)
        let file = try XCTUnwrap(GitDiffParser.shared.parseZeroCopy(data: data).first)
        let hunk = try XCTUnwrap(file.hunks.first)

        let buffer = Buffer(
            filePath: "Icons.swift",
            storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
            startLineNumber: 1,
            isLazySlice: true
        )
        let mb = MultiBuffer()
        mb.addBuffer(buffer)
        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: "Icons.swift",
            bufferRange: 0..<2,
            hunk: hunk
        )
        mb.addExcerpt(excerpt)

        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())

        // First query: materializes and runs word diff
        let lines1 = dm.visibleLines(in: 0..<5)
        let codeItems1 = lines1.compactMap { item -> DisplayCodeLineInfo? in
            if case .code(let info) = item.line { return info }
            return nil
        }
        XCTAssertFalse(codeItems1.isEmpty)
        let diffRanges1 = codeItems1.first(where: { $0.diffKind == .added })?.wordDiffRanges
        XCTAssertNotNil(diffRanges1)
        XCTAssertFalse(diffRanges1?.isEmpty ?? true)

        // Second query: should hit cache and yield identical results
        let lines2 = dm.visibleLines(in: 0..<5)
        let codeItems2 = lines2.compactMap { item -> DisplayCodeLineInfo? in
            if case .code(let info) = item.line { return info }
            return nil
        }
        let diffRanges2 = codeItems2.first(where: { $0.diffKind == .added })?.wordDiffRanges
        XCTAssertEqual(diffRanges1, diffRanges2)
    }
}

