import XCTest
@testable import AnyDiffCore

final class SelectionQuoteTests: XCTestCase {
    func testFormatEditorQuoteWithLineRange() {
        let quote = SelectionQuote(
            id: "editor:/path/to/App.swift",
            text: "let x = 10",
            source: .editor,
            label: "App.swift (L42-45)",
            filePath: "/path/to/App.swift",
            displayPath: "src/App.swift",
            lineRange: 42...45,
            language: "swift"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertTrue(formatted.contains("[App.swift:L42-L45](src/App.swift#L42-L45)"))
        XCTAssertTrue(formatted.contains("```swift\nlet x = 10\n```"))
    }

    func testFormatEditorQuoteSingleLine() {
        let quote = SelectionQuote(
            id: "editor:/path/to/App.swift",
            text: "let y = 20",
            source: .editor,
            label: "App.swift (L42)",
            filePath: "/path/to/App.swift",
            displayPath: "src/App.swift",
            lineRange: 42...42,
            language: "swift"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertTrue(formatted.contains("[App.swift:L42](src/App.swift#L42)"))
    }

    func testFormatAgentQuote() {
        let quote = SelectionQuote(
            id: "agent:1",
            text: "Hello\nWorld",
            source: .agent,
            label: "Quote from Assistant"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertEqual(formatted, "> Hello\n> World")
    }

    func testFormatPromptWithMultipleQuotes() {
        let quote1 = SelectionQuote(
            id: "editor:1",
            text: "print(1)",
            source: .editor,
            label: "test.py",
            filePath: "test.py",
            language: "python"
        )
        let prompt = SelectionQuoteFormatter.formatPrompt(userText: "Fix this issue", quotes: [quote1])
        XCTAssertTrue(prompt.contains("[test.py](test.py)\n```python\nprint(1)\n```"))
        XCTAssertTrue(prompt.hasSuffix("Fix this issue"))
    }

    func testSelectionQuoteStoreScopedClear() {
        let store = SelectionQuoteStore()
        let quote = SelectionQuote(
            id: "editor:fileA",
            text: "code",
            source: .editor,
            label: "fileA"
        )
        store.setQuote(quote)
        XCTAssertNotNil(store.currentQuote)

        // Clear with different id should NOT clear
        store.clearQuote(scopedToId: "editor:fileB")
        XCTAssertNotNil(store.currentQuote)

        // Clear with matching id SHOULD clear
        store.clearQuote(scopedToId: "editor:fileA")
        XCTAssertNil(store.currentQuote)
    }

    func testFormatEditorQuotePreservesIndentationAndLeadingEmptyLines() {
        let indentedCode = "\n    public override init() {\n        super.init()\n    }\n"
        let quote = SelectionQuote(
            id: "editor:fileA",
            text: indentedCode,
            source: .editor,
            label: "fileA",
            filePath: "fileA.swift",
            language: "swift"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertTrue(formatted.contains("```swift\n\n    public override init() {\n        super.init()\n    }\n```"))
    }

    func testFormatPromptBlocksInterleaved() {
        let q1 = SelectionQuote(
            id: "editor:file1",
            text: "let a = 1",
            source: .editor,
            label: "file1.swift",
            filePath: "file1.swift",
            language: "swift"
        )
        let q2 = SelectionQuote(
            id: "editor:file2",
            text: "let b = 2",
            source: .editor,
            label: "file2.swift",
            filePath: "file2.swift",
            language: "swift"
        )
        let blocks: [PromptBlock] = [
            .text("First look at this:"),
            .quote(q1),
            .text("Then look at this:"),
            .quote(q2),
            .text("Please fix both.")
        ]
        let result = SelectionQuoteFormatter.formatPromptBlocks(blocks)
        let expectedParts = [
            "First look at this:",
            "[file1.swift](file1.swift)\n```swift\nlet a = 1\n```",
            "Then look at this:",
            "[file2.swift](file2.swift)\n```swift\nlet b = 2\n```",
            "Please fix both."
        ]
        XCTAssertEqual(result, expectedParts.joined(separator: "\n\n"))
    }
}
