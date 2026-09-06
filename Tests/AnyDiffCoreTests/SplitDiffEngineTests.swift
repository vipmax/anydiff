import XCTest
@testable import AnyDiffCore

final class SplitDiffEngineTests: XCTestCase {
    func testAlignUnchangedLines() {
        let lines: [(line: DiffLine, bufferRow: Int)] = [
            (DiffLine(kind: .unchanged, text: "func hello() {", oldLineNumber: 1, newLineNumber: 1), 0),
            (DiffLine(kind: .unchanged, text: "    print(1)", oldLineNumber: 2, newLineNumber: 2), 1),
            (DiffLine(kind: .unchanged, text: "}", oldLineNumber: 3, newLineNumber: 3), 2)
        ]

        let rows = SplitDiffEngine.shared.align(diffLines: lines)
        XCTAssertEqual(rows.count, 3)

        XCTAssertEqual(rows[0].left.lineNumber, 1)
        XCTAssertEqual(rows[0].right.lineNumber, 1)
        XCTAssertFalse(rows[0].left.isSpacer)
        XCTAssertFalse(rows[0].right.isSpacer)
        XCTAssertEqual(rows[0].left.text, "func hello() {")
        XCTAssertEqual(rows[0].right.text, "func hello() {")
    }

    func testAlignPureAdditions() {
        let lines: [(line: DiffLine, bufferRow: Int)] = [
            (DiffLine(kind: .added, text: "new line 1", oldLineNumber: nil, newLineNumber: 10), 0),
            (DiffLine(kind: .added, text: "new line 2", oldLineNumber: nil, newLineNumber: 11), 1)
        ]

        let rows = SplitDiffEngine.shared.align(diffLines: lines)
        XCTAssertEqual(rows.count, 2)

        XCTAssertTrue(rows[0].left.isSpacer)
        XCTAssertNil(rows[0].left.lineNumber)
        XCTAssertEqual(rows[0].right.lineNumber, 10)
        XCTAssertEqual(rows[0].right.text, "new line 1")

        XCTAssertTrue(rows[1].left.isSpacer)
        XCTAssertEqual(rows[1].right.lineNumber, 11)
        XCTAssertEqual(rows[1].right.text, "new line 2")
    }

    func testAlignPureDeletions() {
        let lines: [(line: DiffLine, bufferRow: Int)] = [
            (DiffLine(kind: .deleted, text: "old line 1", oldLineNumber: 5, newLineNumber: nil), 0),
            (DiffLine(kind: .deleted, text: "old line 2", oldLineNumber: 6, newLineNumber: nil), 0)
        ]

        let rows = SplitDiffEngine.shared.align(diffLines: lines)
        XCTAssertEqual(rows.count, 2)

        XCTAssertFalse(rows[0].left.isSpacer)
        XCTAssertEqual(rows[0].left.lineNumber, 5)
        XCTAssertEqual(rows[0].left.text, "old line 1")
        XCTAssertTrue(rows[0].right.isSpacer)

        XCTAssertFalse(rows[1].left.isSpacer)
        XCTAssertEqual(rows[1].left.lineNumber, 6)
        XCTAssertTrue(rows[1].right.isSpacer)
    }

    func testAlignUnbalancedModifications() {
        // 1 deleted, 2 added
        let lines: [(line: DiffLine, bufferRow: Int)] = [
            (DiffLine(kind: .deleted, text: "let a = 1", oldLineNumber: 10, newLineNumber: nil), 0),
            (DiffLine(kind: .added, text: "let a = 10", oldLineNumber: nil, newLineNumber: 10), 0),
            (DiffLine(kind: .added, text: "let b = 20", oldLineNumber: nil, newLineNumber: 11), 1)
        ]

        let rows = SplitDiffEngine.shared.align(diffLines: lines)
        XCTAssertEqual(rows.count, 2)

        // Row 0: matched deleted and added
        XCTAssertFalse(rows[0].left.isSpacer)
        XCTAssertFalse(rows[0].right.isSpacer)
        XCTAssertEqual(rows[0].left.text, "let a = 1")
        XCTAssertEqual(rows[0].right.text, "let a = 10")
        XCTAssertFalse(rows[0].left.wordDiffRanges.isEmpty)
        XCTAssertFalse(rows[0].right.wordDiffRanges.isEmpty)

        // Row 1: left is spacer, right is added
        XCTAssertTrue(rows[1].left.isSpacer)
        XCTAssertFalse(rows[1].right.isSpacer)
        XCTAssertEqual(rows[1].right.text, "let b = 20")
        XCTAssertEqual(rows[1].right.lineNumber, 11)
    }

    func testAlignInterleavedModifications() {
        // Interleaved: del1, add1, del2, add2
        let lines: [(line: DiffLine, bufferRow: Int)] = [
            (DiffLine(kind: .deleted, text: "del 1", oldLineNumber: 1, newLineNumber: nil), 0),
            (DiffLine(kind: .added, text: "add 1", oldLineNumber: nil, newLineNumber: 1), 0),
            (DiffLine(kind: .deleted, text: "del 2", oldLineNumber: 2, newLineNumber: nil), 1),
            (DiffLine(kind: .added, text: "add 2", oldLineNumber: nil, newLineNumber: 2), 1)
        ]

        let rows = SplitDiffEngine.shared.align(diffLines: lines)
        XCTAssertEqual(rows.count, 2)

        XCTAssertEqual(rows[0].left.text, "del 1")
        XCTAssertEqual(rows[0].right.text, "add 1")
        XCTAssertEqual(rows[1].left.text, "del 2")
        XCTAssertEqual(rows[1].right.text, "add 2")
    }
}
