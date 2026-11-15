import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

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

    func testFormatMarkdownQuoteWithLineRange() {
        let quote = SelectionQuote(
            id: "markdown:/path/to/README.md:123",
            text: "This is a great feature",
            source: .markdown,
            label: "README.md (L10-12)",
            filePath: "/path/to/README.md",
            displayPath: "README.md",
            lineRange: 10...12,
            language: "markdown"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertTrue(formatted.contains("[README.md:L10-L12](README.md#L10-L12)"))
        XCTAssertTrue(formatted.contains("```markdown\nThis is a great feature\n```"))
    }

    func testFormatMarkdownQuoteCodeBlock() {
        let quote = SelectionQuote(
            id: "markdown:/path/to/README.md:456",
            text: "func hello() { print(\"hi\") }",
            source: .markdown,
            label: "README.md (L20)",
            filePath: "/path/to/README.md",
            displayPath: "docs/README.md",
            lineRange: 20...20,
            language: "swift"
        )
        let formatted = SelectionQuoteFormatter.formatSingleQuote(quote)
        XCTAssertTrue(formatted.contains("[README.md:L20](docs/README.md#L20)"))
        XCTAssertTrue(formatted.contains("```swift\nfunc hello() { print(\"hi\") }\n```"))
    }

    func testMarkdownSelectionLineFinder() {
        let markdown = """
        # Title

        A quick brown fox
        jumps over the lazy dog.

        ```swift
        let a = 1
        let b = 2
        ```

        - Item one
        - Item two

        > A quoted statement
        """
        let lines = markdown.components(separatedBy: "\n")
        let blocks = MarkdownParser.parse(markdown)
        let blockRanges = MarkdownSelectionLineFinder.findBlockLineRanges(blocks: blocks, in: lines)
        XCTAssertEqual(blockRanges.count, blocks.count)

        let range1 = MarkdownSelectionLineFinder.findLineRange(in: lines, for: "jumps over")
        XCTAssertEqual(range1, 4...4)

        let range2 = MarkdownSelectionLineFinder.findLineRange(in: lines, for: "brown fox\njumps over")
        XCTAssertEqual(range2, 3...4)

        let range3 = MarkdownSelectionLineFinder.findLineRange(in: lines, for: "let b = 2")
        XCTAssertEqual(range3, 8...8)

        let range4 = MarkdownSelectionLineFinder.findLineRange(in: lines, for: "A quoted statement")
        XCTAssertEqual(range4, 14...14)
    }

    func testAgentInputMakeInputBlocksRestoresQuotesAndSurroundingText() {
        let quote = SelectionQuote(
            id: "agent:msg:text_0",
            text: "status indicator badge",
            source: .agent,
            label: "Quote from Assistant"
        )
        let draftBlocks: [PromptBlock] = [
            .text("context before"),
            .quote(quote),
            .text("comment after quote")
        ]

        let restored = AgentInputView.makeInputBlocks(from: draftBlocks, fallbackText: "ignored")
        XCTAssertEqual(restored.map(\.asPromptBlock), draftBlocks)

        if case .text(let first) = restored[0], case .text(let last) = restored[2] {
            XCTAssertEqual(first.focusRequest, 0)
            XCTAssertEqual(last.focusRequest, 1)
        } else {
            XCTFail("Expected text blocks at indices 0 and 2")
        }

        // Empty draftBlocks falls back to draftPrompt text
        let fromFallback = AgentInputView.makeInputBlocks(from: [], fallbackText: "plain draft")
        XCTAssertEqual(fromFallback.map(\.asPromptBlock), [.text("plain draft")])

        // Quote-only draftBlocks still ensures an editable text block
        let quoteOnly = AgentInputView.makeInputBlocks(from: [.quote(quote)], fallbackText: "")
        XCTAssertEqual(quoteOnly.map(\.asPromptBlock), [.quote(quote), .text("")])
    }

    func testDraftBlocksPreservedAcrossStartScreenAndClearedOnReset() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        guard let session = coordinator.activeSession else {
            XCTFail("Expected active session")
            return
        }

        let quote = SelectionQuote(
            id: "agent:msg:text_0",
            text: "quoted snippet",
            source: .agent,
            label: "Quote from Assistant"
        )

        // Quote-only draft counts as sendable draft content
        session.draftBlocks = [.quote(quote), .text("")]
        XCTAssertTrue(session.manager.hasDraftContent)

        let expectedBlocks: [PromptBlock] = [
            .text("before quote"),
            .quote(quote),
            .text("after quote")
        ]
        session.draftBlocks = expectedBlocks
        session.draftPrompt = SelectionQuoteFormatter.formatPromptBlocks(expectedBlocks)

        // Navigate to empty agents panel (start screen) and back to the agent session
        coordinator.openStartScreen()
        XCTAssertTrue(coordinator.showStartScreen)
        coordinator.selectSession(id: session.id)
        XCTAssertFalse(coordinator.showStartScreen)

        XCTAssertEqual(coordinator.activeSession?.draftBlocks, expectedBlocks)
        XCTAssertEqual(
            AgentInputView.makeInputBlocks(
                from: coordinator.activeSession?.draftBlocks ?? [],
                fallbackText: coordinator.activeSession?.draftPrompt ?? ""
            ).map(\.asPromptBlock),
            expectedBlocks
        )

        session.manager.clearSession()
        XCTAssertTrue(session.draftBlocks.isEmpty)
        XCTAssertEqual(session.draftPrompt, "")
        XCTAssertFalse(session.manager.hasDraftContent)
    }
}
