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
}
