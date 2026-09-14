import XCTest
@testable import AnyDiffUI

final class AgentMarkdownParserTests: XCTestCase {

    func testHeadersLevel1Through6() {
        let input = """
        # Header 1
        ## Header 2
        ### Header 3
        #### Header 4
        ##### Header 5
        ###### Header 6
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 6)

        XCTAssertEqual(blocks[0], .header(level: 1, text: "Header 1"))
        XCTAssertEqual(blocks[1], .header(level: 2, text: "Header 2"))
        XCTAssertEqual(blocks[2], .header(level: 3, text: "Header 3"))
        XCTAssertEqual(blocks[3], .header(level: 4, text: "Header 4"))
        XCTAssertEqual(blocks[4], .header(level: 5, text: "Header 5"))
        XCTAssertEqual(blocks[5], .header(level: 6, text: "Header 6"))
    }

    func testHeadersWithoutSpaceAreNotHeaders() {
        let input = """
        #hashtag is not a header
        ####### Seven hashes is not a header
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph(let text) = blocks[0] {
            XCTAssertTrue(text.contains("#hashtag"))
            XCTAssertTrue(text.contains("#######"))
        } else {
            XCTFail("Expected paragraph block")
        }
    }

    func testThematicBreakDividers() {
        let input = """
        Paragraph 1
        ---
        Paragraph 2
        ***
        Paragraph 3
        ___
        - - -
        Paragraph 4
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 8)

        XCTAssertEqual(blocks[0], .paragraph("Paragraph 1"))
        XCTAssertEqual(blocks[1], .divider)
        XCTAssertEqual(blocks[2], .paragraph("Paragraph 2"))
        XCTAssertEqual(blocks[3], .divider)
        XCTAssertEqual(blocks[4], .paragraph("Paragraph 3"))
        XCTAssertEqual(blocks[5], .divider)
        XCTAssertEqual(blocks[6], .divider)
        XCTAssertEqual(blocks[7], .paragraph("Paragraph 4"))
    }

    func testNonDividers() {
        let input = """
        --
        ***bold text***
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .paragraph("--\n***bold text***"))
    }

    func testBulletListsAndTaskItems() {
        let input = """
        - Dash item
        * Asterisk item
        + Plus item
        - [ ] Unchecked task
        * [x] Checked task
        + [X] Uppercase checked task
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 6)

        XCTAssertEqual(blocks[0], .bulletItem("Dash item"))
        XCTAssertEqual(blocks[1], .bulletItem("Asterisk item"))
        XCTAssertEqual(blocks[2], .bulletItem("Plus item"))
        XCTAssertEqual(blocks[3], .bulletItem("☐ Unchecked task"))
        XCTAssertEqual(blocks[4], .bulletItem("☑ Checked task"))
        XCTAssertEqual(blocks[5], .bulletItem("☑ Uppercase checked task"))
    }

    func testNumberedLists() {
        let input = """
        1. First point
        2. Second point
        3) Third point with parenthesis
        10. Tenth point
        1. [ ] Numbered task
        2. [x] Completed numbered task
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 6)

        XCTAssertEqual(blocks[0], .numberedItem(number: "1", text: "First point"))
        XCTAssertEqual(blocks[1], .numberedItem(number: "2", text: "Second point"))
        XCTAssertEqual(blocks[2], .numberedItem(number: "3", text: "Third point with parenthesis"))
        XCTAssertEqual(blocks[3], .numberedItem(number: "10", text: "Tenth point"))
        XCTAssertEqual(blocks[4], .numberedItem(number: "1", text: "☐ Numbered task"))
        XCTAssertEqual(blocks[5], .numberedItem(number: "2", text: "☑ Completed numbered task"))
    }

    func testCodeBlocksWithBackticksAndTildes() {
        let input = """
        ```swift
        let x = 42
        ```
        ~~~bash
        echo "hello"
        ~~~
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 2)

        XCTAssertEqual(blocks[0], .codeBlock(language: "swift", code: "let x = 42"))
        XCTAssertEqual(blocks[1], .codeBlock(language: "bash", code: "echo \"hello\""))
    }

    func testStreamingUnclosedCodeBlock() {
        let input = """
        ```python
        print("streaming...")
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .codeBlock(language: "python", code: "print(\"streaming...\")"))
    }

    func testQuotes() {
        let input = """
        > This is a quote
        > continuing on line 2
        """

        let blocks = AgentMarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0], .quote("This is a quote\ncontinuing on line 2"))
    }

    func testUserScreenshotRegression() {
        let input = """
        Да, отличный вопрос! Сейчас в приложении действительно 3 мультибуффера:

        1. multiBuffer — основной рабочий дифф (working tree / ветка / коммит).
        2. reviewMultiBuffer — дифф ревью правок агента (когда агент что-то изменил и мы инспектируем его ход).
        3. searchMultiBuffer — результаты глобального поиска по проекту (когда нажимаем ⌘F по всему проекту).

        ---

        **Нужно ли плодить 4-й мультибуффер под просмотр файла?**
        У нас тут есть два хороших пути:

        #### Путь 1: Без 4-го мультибуффера — использовать существующий
        reviewMultiBuffer (или multiBuffer)
        """

        let blocks = AgentMarkdownParser.parse(input)

        XCTAssertEqual(blocks[0], .paragraph("Да, отличный вопрос! Сейчас в приложении действительно 3 мультибуффера:"))
        XCTAssertEqual(blocks[1], .numberedItem(number: "1", text: "multiBuffer — основной рабочий дифф (working tree / ветка / коммит)."))
        XCTAssertEqual(blocks[2], .numberedItem(number: "2", text: "reviewMultiBuffer — дифф ревью правок агента (когда агент что-то изменил и мы инспектируем его ход)."))
        XCTAssertEqual(blocks[3], .numberedItem(number: "3", text: "searchMultiBuffer — результаты глобального поиска по проекту (когда нажимаем ⌘F по всему проекту)."))
        XCTAssertEqual(blocks[4], .divider)
        XCTAssertEqual(blocks[5], .paragraph("**Нужно ли плодить 4-й мультибуффер под просмотр файла?**\nУ нас тут есть два хороших пути:"))
        XCTAssertEqual(blocks[6], .header(level: 4, text: "Путь 1: Без 4-го мультибуффера — использовать существующий"))
        XCTAssertEqual(blocks[7], .paragraph("reviewMultiBuffer (или multiBuffer)"))
    }
}
