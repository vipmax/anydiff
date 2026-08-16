import XCTest
@testable import AnyDiffCore

final class WordDiffTests: XCTestCase {
    func testWordDiffIntraLine() {
        let oldLine = "let total = calculateSum(a, b)"
        let newLine = "let total = calculateTotal(a, b, c)"

        let (oldDiffs, newDiffs) = WordDiffEngine.shared.diffWords(oldText: oldLine, newText: newLine)

        XCTAssertFalse(oldDiffs.isEmpty)
        XCTAssertFalse(newDiffs.isEmpty)
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

    func testBenchmarkWithPruning() {
        var oldLines: [String] = []
        var newLines: [String] = []

        for i in 0..<5000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        oldLines.append("func calculateOldLogic() -> Bool { return false }")
        newLines.append("func calculateNewLogic() -> Bool { return true }")

        for i in 5001..<10000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        measure {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: true)
        }
    }

    func testBenchmarkWithoutPruning() {
        var oldLines: [String] = []
        var newLines: [String] = []

        for i in 0..<5000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        oldLines.append("func calculateOldLogic() -> Bool { return false }")
        newLines.append("func calculateNewLogic() -> Bool { return true }")

        for i in 5001..<10000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        measure {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: false)
        }
    }

    func testComparisonAndCorrectnessBenchmark() {
        var oldLines: [String] = []
        var newLines: [String] = []

        for i in 0..<5000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        oldLines.append("func calculateOldLogic() -> Bool { return false }")
        newLines.append("func calculateNewLogic() -> Bool { return true }")

        for i in 5001..<10000 {
            oldLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
            newLines.append("struct UserRecord\(i) { let id: Int = \(i) }")
        }

        // 1. Correctness: results must be 100% identical
        let withPruning = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: true)
        let withoutPruning = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: false)

        XCTAssertEqual(withPruning.count, withoutPruning.count)
        for i in 0..<withPruning.count {
            XCTAssertEqual(withPruning[i].kind, withoutPruning[i].kind)
            XCTAssertEqual(withPruning[i].text, withoutPruning[i].text)
            XCTAssertEqual(withPruning[i].oldLineNumber, withoutPruning[i].oldLineNumber)
            XCTAssertEqual(withPruning[i].newLineNumber, withoutPruning[i].newLineNumber)
        }

        // 2. High-precision timing comparison (10 iterations)
        let iterations = 10

        // Warm up
        _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: true)
        _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: false)

        let startWith = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: true)
        }
        let timeWithPruning = (CFAbsoluteTimeGetCurrent() - startWith) / Double(iterations)

        let startWithout = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines, enablePrefixSuffixPruning: false)
        }
        let timeWithoutPruning = (CFAbsoluteTimeGetCurrent() - startWithout) / Double(iterations)

        let speedup = timeWithoutPruning / max(0.000001, timeWithPruning)
        print("=== BENCHMARK 1 (10,000 lines, 1 line edit D=2) ===")
        print("WITH PRUNING:    \(String(format: "%.4f", timeWithPruning * 1000)) ms")
        print("WITHOUT PRUNING: \(String(format: "%.4f", timeWithoutPruning * 1000)) ms")
        print("SPEEDUP:         \(String(format: "%.1f", speedup))x faster")
        print("===================================================")

        // Scenario 2: 10,000 lines with a block of 60 lines changed (D=60)
        var oldLines60: [String] = []
        var newLines60: [String] = []
        for i in 0..<5000 {
            oldLines60.append("func item\(i)() { print(\(i)) }")
            newLines60.append("func item\(i)() { print(\(i)) }")
        }
        for i in 0..<30 {
            oldLines60.append("func oldBlockMethod\(i)() {}")
            newLines60.append("func newReplacementMethod\(i)(value: Int) {}")
        }
        for i in 5000..<10000 {
            oldLines60.append("func item\(i)() { print(\(i)) }")
            newLines60.append("func item\(i)() { print(\(i)) }")
        }

        let startWith60 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines60, newLines: newLines60, enablePrefixSuffixPruning: true)
        }
        let timeWithPruning60 = (CFAbsoluteTimeGetCurrent() - startWith60) / Double(iterations)

        let startWithout60 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines60, newLines: newLines60, enablePrefixSuffixPruning: false)
        }
        let timeWithoutPruning60 = (CFAbsoluteTimeGetCurrent() - startWithout60) / Double(iterations)

        let speedup60 = timeWithoutPruning60 / max(0.000001, timeWithPruning60)
        print("=== BENCHMARK 2 (10,000 lines, 60 lines block edit D=60) ===")
        print("WITH PRUNING:    \(String(format: "%.4f", timeWithPruning60 * 1000)) ms")
        print("WITHOUT PRUNING: \(String(format: "%.4f", timeWithoutPruning60 * 1000)) ms")
        print("SPEEDUP:         \(String(format: "%.1f", speedup60))x faster")
        print("=============================================================")

        XCTAssertLessThan(timeWithPruning, timeWithoutPruning)
    }

    func testBenchmarkDiffLinesForSliceTargetedZeroCopy() {
        var oldLines: [String] = []
        var newLines: [String] = []

        for i in 0..<50000 {
            oldLines.append("let record\(i) = fetchUserData(id: \(i))")
            newLines.append("let record\(i) = fetchUserData(id: \(i))")
        }

        oldLines.append("let modifiedRecord = nil")
        newLines.append("let modifiedRecord = fetchUserData(id: 999999)")

        for i in 50001..<100000 {
            oldLines.append("let record\(i) = fetchUserData(id: \(i))")
            newLines.append("let record\(i) = fetchUserData(id: \(i))")
        }

        // Target range is the 20-line excerpt around the edit: 49990..<50010
        let targetRange = 49990..<50010
        let iterations = 20

        // 1. Full materialization (old way: 100,000 DiffLine structs)
        let startFull = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLines(oldLines: oldLines, newLines: newLines)
        }
        let timeFull = (CFAbsoluteTimeGetCurrent() - startFull) / Double(iterations)

        // 2. Targeted slice (new Zero-Copy way: only 20 DiffLine structs)
        let startSlice = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = LineDiffEngine.shared.diffLinesForSlice(
                oldLines: oldLines,
                newLines: newLines,
                targetRange: targetRange
            )
        }
        let timeSlice = (CFAbsoluteTimeGetCurrent() - startSlice) / Double(iterations)

        let speedup = timeFull / max(0.000001, timeSlice)
        print("=== BENCHMARK 3: ZERO-COPY TARGETED SLICING (100,000 lines file) ===")
        print("OLD WAY (FULL 100,000 STRUCTS): \(String(format: "%.4f", timeFull * 1000)) ms")
        print("NEW WAY (ZERO-COPY 20 LINES):    \(String(format: "%.4f", timeSlice * 1000)) ms")
        print("SPEEDUP:                         \(String(format: "%.1f", speedup))x FASTER!")
        print("====================================================================")

        XCTAssertLessThan(timeSlice, timeFull)
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
