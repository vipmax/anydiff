import XCTest
@testable import AnyDiffCore

final class SyntaxHighlighterTests: XCTestCase {
    func testDollarAndAtEdgeCasesDoNotCrash() {
        let testCases = [
            "$$",
            "$$$",
            "$$VAR",
            "$@\"",
            "@$dir",
            "$(CC) -o $@ $< $$^",
            "let x = $$",
            "@@ -1,5 +1,5 @@",
            "echo \"hello $world\"",
            "$\"interpolated string\"",
            "@\"verbatim string\"",
            "$@\"multiline verbatim string\"",
            "$",
            "@"
        ]

        let highlighter = SyntaxHighlighter.shared
        for tc in testCases {
            let spans = highlighter.tokenize(line: tc, language: "makefile")
            XCTAssertNotNil(spans)
            let cSpans = highlighter.tokenize(line: tc, language: "c")
            XCTAssertNotNil(cSpans)
            let swiftSpans = highlighter.tokenize(line: tc, language: "swift")
            XCTAssertNotNil(swiftSpans)
        }
    }
}
