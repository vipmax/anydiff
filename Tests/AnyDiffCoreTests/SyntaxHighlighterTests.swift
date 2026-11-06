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

    func testLinuxRootCommitHighlighterRobustness() async throws {
        let linuxPath = "/Users/max/dev/linux"
        guard FileManager.default.fileExists(atPath: linuxPath) else { return }

        var fileCount = 0
        let highlighter = SyntaxHighlighter.shared

        // Stream diff files and highlight every line of the first 100 files to ensure zero crashes
        for try await file in GitService.shared.streamDiffFiles(at: linuxPath, target: .commit(hash: "1da177e4c3f41524e886b7f1b8a0c1fc7321cac2", summary: "")) {
            fileCount += 1
            let lang = Buffer.detectLanguage(for: file.displayPath)
            for hunk in file.hunks {
                for line in hunk.lines {
                    _ = highlighter.tokenize(line: line.text, language: lang)
                }
            }
            if fileCount >= 100 {
                break
            }
        }
        XCTAssertGreaterThanOrEqual(fileCount, 100)
    }
}
