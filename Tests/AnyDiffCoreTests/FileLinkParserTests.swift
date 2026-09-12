import XCTest
@testable import AnyDiffCore

final class FileLinkParserTests: XCTestCase {
    func testWebLinks() {
        let url = URL(string: "https://github.com/vipmax/anydiff")!
        let target = FileLinkParser.parse(url: url)
        XCTAssertEqual(target.targetType, .web(url: url))
    }

    func testCustomSchemeLinks() {
        let mailto = URL(string: "mailto:support@anydiff.com")!
        let mailtoTarget = FileLinkParser.parse(url: mailto)
        XCTAssertEqual(mailtoTarget.targetType, .custom(url: mailto))

        let vscode = URL(string: "vscode://file/path/to/file.swift:10")!
        let vscodeTarget = FileLinkParser.parse(url: vscode)
        XCTAssertEqual(vscodeTarget.targetType, .custom(url: vscode))
    }

    func testFileLineAnchorSingle() {
        let url = URL(string: "file:///path/to/main.swift#L42")!
        let target = FileLinkParser.parse(url: url)
        XCTAssertEqual(target.targetType, .file(path: "/path/to/main.swift", line: 42, endLine: nil))
    }

    func testFileLineAnchorRange() {
        let url = URL(string: "file:///path/to/main.swift#L42-L55")!
        let target = FileLinkParser.parse(url: url)
        XCTAssertEqual(target.targetType, .file(path: "/path/to/main.swift", line: 42, endLine: 55))
    }

    func testFileLineAnchorNumeric() {
        let url = URL(string: "file:///path/to/main.swift#42")!
        let target = FileLinkParser.parse(url: url)
        XCTAssertEqual(target.targetType, .file(path: "/path/to/main.swift", line: 42, endLine: nil))
    }

    func testMarkdownHeadingAnchorIgnoredAsLineNumber() {
        let url = URL(string: "file:///path/to/README.md#section-1")!
        let target = FileLinkParser.parse(url: url)
        XCTAssertEqual(target.targetType, .file(path: "/path/to/README.md", line: nil, endLine: nil))

        let (line, endLine) = FileLinkParser.parseLineAnchor("heading-2")
        XCTAssertNil(line)
        XCTAssertNil(endLine)
    }

    func testFilePathSuffixColon() {
        let target = FileLinkParser.parse(urlString: "Sources/AnyDiff/main.swift:42", workingDirectory: "/tmp")
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.targetType, .file(path: "/tmp/Sources/AnyDiff/main.swift", line: 42, endLine: nil))
    }

    func testDirectoryResolution() {
        let tmpDir = NSTemporaryDirectory()
        let target = FileLinkParser.parse(urlString: tmpDir)
        let resolved = URL(fileURLWithPath: tmpDir).standardizedFileURL.path
        XCTAssertEqual(target?.targetType, .directory(path: resolved))
    }
}
