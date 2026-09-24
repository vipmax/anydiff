import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class MarkdownParserTests: XCTestCase {
    func testHeaderParsing() {
        let md = """
        # Header 1
        ## Header 2
        ### Header 3
        #### Header 4
        ##### Header 5
        ###### Header 6
        ####### Not a valid header

        #NoSpaceNotAHeader
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 8)
        XCTAssertEqual(blocks[0], .header(level: 1, text: "Header 1"))
        XCTAssertEqual(blocks[1], .header(level: 2, text: "Header 2"))
        XCTAssertEqual(blocks[2], .header(level: 3, text: "Header 3"))
        XCTAssertEqual(blocks[3], .header(level: 4, text: "Header 4"))
        XCTAssertEqual(blocks[4], .header(level: 5, text: "Header 5"))
        XCTAssertEqual(blocks[5], .header(level: 6, text: "Header 6"))
        XCTAssertEqual(blocks[6], .paragraph("####### Not a valid header"))
        XCTAssertEqual(blocks[7], .paragraph("#NoSpaceNotAHeader"))
    }

    func testListAndChecklistParsing() {
        let md = """
        - Item 1
        - [ ] Todo item
        - [x] Done item
        1. First
        2. [ ] Numbered todo
        3. [x] Numbered done
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .bulletItem("Item 1"))
        XCTAssertEqual(blocks[1], .bulletItem("☐ Todo item"))
        XCTAssertEqual(blocks[2], .bulletItem("☑ Done item"))
        XCTAssertEqual(blocks[3], .numberedItem(number: "1", text: "First"))
        XCTAssertEqual(blocks[4], .numberedItem(number: "2", text: "☐ Numbered todo"))
        XCTAssertEqual(blocks[5], .numberedItem(number: "3", text: "☑ Numbered done"))
    }

    func testCodeBlockParsing() {
        let md = """
        ```swift
        let x = 42
        print(x)
        ```
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .codeBlock(language: "swift", code: "let x = 42\nprint(x)"))
    }

    func testBlockquoteAndDivider() {
        let md = """
        > This is a quote
        > second line

        ---
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .quote("This is a quote\nsecond line"))
        XCTAssertEqual(blocks[1], .divider)
    }

    func testTableParsing() {
        let md = """
        | Header A | Header B |
        |---|---|
        | Row 1 A  | Row 1 B  |
        | Row 2 A  | Row 2 B  |

        After table paragraph
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .table(
            headers: ["Header A", "Header B"],
            rows: [
                ["Row 1 A", "Row 1 B"],
                ["Row 2 A", "Row 2 B"]
            ]
        ))
        XCTAssertEqual(blocks[1], .paragraph("After table paragraph"))
    }

    func testImageParsing() {
        let md = """
        ![App Logo](Resources/AppIcon.png)
        ![Screenshot](https://example.com/demo.png "Title")
        ![](relative/empty-alt.jpg)

        Paragraph before
        ![Inline separated](assets/diagram.svg)
        Paragraph after
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .image(alt: "App Logo", path: "Resources/AppIcon.png"))
        XCTAssertEqual(blocks[1], .image(alt: "Screenshot", path: "https://example.com/demo.png"))
        XCTAssertEqual(blocks[2], .image(alt: "", path: "relative/empty-alt.jpg"))
        XCTAssertEqual(blocks[3], .paragraph("Paragraph before"))
        XCTAssertEqual(blocks[4], .image(alt: "Inline separated", path: "assets/diagram.svg"))
        XCTAssertEqual(blocks[5], .paragraph("Paragraph after"))
    }

    func testParseReadme() throws {
        let repoRoot = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readmeURL = repoRoot.appendingPathComponent("README.md")
        let text = try String(contentsOf: readmeURL, encoding: .utf8)
        let blocks = MarkdownParser.parse(text)
        let sections = MarkdownSectionCompiler.compile(
            blocks: blocks,
            theme: .vesper,
            filePath: "README.md",
            rootDirectory: repoRoot.path
        )
        XCTAssertGreaterThan(sections.count, 0)
        var totalH: CGFloat = 28
        for s in sections {
            let h: CGFloat
            switch s {
            case .text(let tv, _):
                h = tv.measuredHeight(for: 700)
            case .codeBlock(let cb):
                h = cb.measuredHeight(for: 700)
            case .imageGroup(let ig):
                h = ig.measuredHeight(for: 700)
            case .table(let tb):
                h = max(36, tb.fittingSize.height)
            case .divider:
                h = 16
            }
            totalH += h + 14
        }
        XCTAssertGreaterThan(totalH, 1000)
    }

    func testMarkdownTableScrollForwarding() {
        let md = """
        # Title

        | Col A | Col B | Col C | Col D | Col E |
        | --- | --- | --- | --- | --- |
        | Val 1 | Val 2 | Val 3 | Val 4 | Val 5 |
        | Val 6 | Val 7 | Val 8 | Val 9 | Val 10 |

        End of text
        """
        let blocks = MarkdownParser.parse(md)
        let sections = MarkdownSectionCompiler.compile(
            blocks: blocks,
            theme: .vesper,
            filePath: "test.md",
            rootDirectory: "/"
        )

        guard let tableSection = sections.first(where: {
            if case .table = $0 { return true }
            return false
        }), case .table(let tableScrollView) = tableSection else {
            XCTFail("Table section not found")
            return
        }

        let docScrollView = MarkdownNativeDocumentScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        docScrollView.containerView.setSections(sections)
        docScrollView.containerView.layoutContent(for: 800)

        // The table is in the scroll hierarchy
        XCTAssertEqual(tableScrollView.enclosingScrollView, docScrollView)

        // 5 columns at minWidth 90 is ~450+ pt.
        // At width 800, contentWidth is min(860, 800 - 96) = 704 pt, so it fits without horizontal scroller.
        XCTAssertFalse(tableScrollView.hasHorizontalScroller)

        // At width 350, available width is max(200, 350 - 96) = 254 pt.
        // 450+ pt is wider than 254 pt, so horizontal scroller MUST be enabled.
        docScrollView.containerView.layoutContent(for: 350)
        XCTAssertTrue(tableScrollView.hasHorizontalScroller)
    }
}

