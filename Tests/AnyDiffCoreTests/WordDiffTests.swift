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
}
