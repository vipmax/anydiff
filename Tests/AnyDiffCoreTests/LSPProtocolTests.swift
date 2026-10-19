import XCTest
@testable import AnyDiffCore

final class LSPProtocolTests: XCTestCase {

    // MARK: - Framing Tests

    func testLSPFramingEncode() throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize"]
        let data = try LSPFraming.encode(jsonDict: payload)

        let string = String(data: data, encoding: .utf8)!
        XCTAssertTrue(string.hasPrefix("Content-Length: "))
        XCTAssertTrue(string.contains("\r\n\r\n"))

        // Extract body
        let parts = string.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        let header = parts[0]
        let body = parts[1]

        let length = Int(header.replacingOccurrences(of: "Content-Length: ", with: ""))!
        XCTAssertEqual(length, body.utf8.count)

        // Parse body JSON
        let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(decoded?["id"] as? Int, 1)
        XCTAssertEqual(decoded?["method"] as? String, "initialize")
    }

    func testLSPFramingReaderComplete() throws {
        let reader = LSPFraming.FrameReader()
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 42, "result": ["status": "ok"]]
        let frameData = try LSPFraming.encode(jsonDict: payload)

        let messages = reader.append(data: frameData)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["id"] as? Int, 42)
        let res = messages.first?["result"] as? [String: Any]
        XCTAssertEqual(res?["status"] as? String, "ok")
    }

    func testLSPFramingReaderChunkedStream() throws {
        let reader = LSPFraming.FrameReader()
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": "window/logMessage", "params": ["message": "hello"]]
        let frameData = try LSPFraming.encode(jsonDict: payload)

        var accumulated: [[String: Any]] = []
        // Feed byte by byte
        for byte in frameData {
            let msgs = reader.append(data: Data([byte]))
            accumulated.append(contentsOf: msgs)
        }

        XCTAssertEqual(accumulated.count, 1)
        XCTAssertEqual(accumulated.first?["method"] as? String, "window/logMessage")
    }

    func testLSPFramingReaderMultipleMessages() throws {
        let reader = LSPFraming.FrameReader()
        let msg1 = try LSPFraming.encode(jsonDict: ["jsonrpc": "2.0", "id": 1])
        let msg2 = try LSPFraming.encode(jsonDict: ["jsonrpc": "2.0", "id": 2])
        var combined = msg1
        combined.append(msg2)

        let parsed = reader.append(data: combined)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0]["id"] as? Int, 1)
        XCTAssertEqual(parsed[1]["id"] as? Int, 2)
    }

    // MARK: - Definition Response Parsing (Matching Zed's parsing model)

    func testLSPDefinitionResponseParserScalarLocation() {
        let scalar: [String: Any] = [
            "uri": "file:///Users/dev/project/Sources/main.swift",
            "range": [
                "start": ["line": 15, "character": 4],
                "end": ["line": 15, "character": 12]
            ]
        ]

        let results = LSPDefinitionResponseParser.parse(from: scalar)
        XCTAssertEqual(results.count, 1)
        let loc = results[0]
        XCTAssertEqual(loc.targetFilePath, "/Users/dev/project/Sources/main.swift")
        // Check 1-based indexing conversion
        XCTAssertEqual(loc.targetLine, 16)
        XCTAssertEqual(loc.targetColumn, 5)
    }

    func testLSPDefinitionResponseParserArrayLocations() {
        let array: [[String: Any]] = [
            [
                "uri": "file:///Users/dev/project/Sources/First.swift",
                "range": [
                    "start": ["line": 0, "character": 0],
                    "end": ["line": 0, "character": 10]
                ]
            ],
            [
                "uri": "file:///Users/dev/project/Sources/Second.swift",
                "range": [
                    "start": ["line": 99, "character": 19],
                    "end": ["line": 99, "character": 25]
                ]
            ]
        ]

        let results = LSPDefinitionResponseParser.parse(from: array)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].targetFilePath, "/Users/dev/project/Sources/First.swift")
        XCTAssertEqual(results[0].targetLine, 1)
        XCTAssertEqual(results[0].targetColumn, 1)

        XCTAssertEqual(results[1].targetFilePath, "/Users/dev/project/Sources/Second.swift")
        XCTAssertEqual(results[1].targetLine, 100)
        XCTAssertEqual(results[1].targetColumn, 20)
    }

    func testLSPDefinitionResponseParserLocationLinks() {
        let links: [[String: Any]] = [
            [
                "targetUri": "file:///Users/dev/project/src/lib.rs",
                "targetRange": [
                    "start": ["line": 10, "character": 0],
                    "end": ["line": 20, "character": 0]
                ],
                "targetSelectionRange": [
                    "start": ["line": 12, "character": 7],
                    "end": ["line": 12, "character": 15]
                ]
            ]
        ]

        let results = LSPDefinitionResponseParser.parse(from: links)
        XCTAssertEqual(results.count, 1)
        let loc = results[0]
        XCTAssertEqual(loc.targetFilePath, "/Users/dev/project/src/lib.rs")
        // Target selection range must take precedence over outer targetRange
        XCTAssertEqual(loc.targetLine, 13)
        XCTAssertEqual(loc.targetColumn, 8)
    }

    func testLSPDefinitionResponseParserEmptyOrNull() {
        XCTAssertEqual(LSPDefinitionResponseParser.parse(from: nil), [])
        XCTAssertEqual(LSPDefinitionResponseParser.parse(from: NSNull()), [])
        XCTAssertEqual(LSPDefinitionResponseParser.parse(from: [String: Any]()), [])
        XCTAssertEqual(LSPDefinitionResponseParser.parse(from: [[String: Any]]()), [])
        XCTAssertEqual(LSPDefinitionResponseParser.parse(from: "invalid string"), [])
    }

    // MARK: - File Path & URI Normalization Tests

    func testLocationFilePathPercentDecoding() {
        let loc = LSPLocation(
            uri: "file:///Users/dev/My%20Projects/Test%20App/main.rs",
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        )
        XCTAssertEqual(loc.targetFilePath, "/Users/dev/My Projects/Test App/main.rs")
    }

    // MARK: - Language Detection Tests

    func testLanguageDetection() {
        let service = LSPWorkspaceService.shared
        XCTAssertEqual(service.detectLanguage(for: "Sources/AnyDiff/main.swift"), "swift")
        XCTAssertEqual(service.detectLanguage(for: "src/main.rs"), "rust")
        XCTAssertEqual(service.detectLanguage(for: "scripts/deploy.py"), "python")
        XCTAssertEqual(service.detectLanguage(for: "cmd/server/main.go"), "go")
        XCTAssertEqual(service.detectLanguage(for: "web/src/index.ts"), "typescript")
        XCTAssertEqual(service.detectLanguage(for: "web/src/App.tsx"), "typescript")
        XCTAssertEqual(service.detectLanguage(for: "web/src/index.js"), "javascript")
        XCTAssertEqual(service.detectLanguage(for: "native/core.c"), "c")
        XCTAssertEqual(service.detectLanguage(for: "native/engine.cpp"), "cpp")
        XCTAssertEqual(service.detectLanguage(for: "scripts/setup.sh"), "bash")
        XCTAssertEqual(service.detectLanguage(for: "config/config.json"), "json")
        XCTAssertEqual(service.detectLanguage(for: "src/main.zig"), "zig")
        XCTAssertEqual(service.detectLanguage(for: "init.lua"), "lua")
    }

    // MARK: - Hover Response Parsing Tests

    func testLSPHoverResponseParserMarkupContent() {
        let json: [String: Any] = [
            "contents": [
                "kind": "markdown",
                "value": "```swift\nfunc greet(name: String) -> String\n```\nGreets someone nicely."
            ],
            "range": [
                "start": ["line": 10, "character": 4],
                "end": ["line": 10, "character": 9]
            ]
        ]

        let hover = LSPHoverResponseParser.parse(from: json)
        XCTAssertNotNil(hover)
        XCTAssertEqual(hover?.contents.count, 1)
        XCTAssertTrue(hover?.markdownString.contains("func greet") ?? false)
        XCTAssertTrue(hover?.markdownString.contains("Greets someone nicely.") ?? false)
        XCTAssertEqual(hover?.range?.start.line, 10)
        XCTAssertEqual(hover?.range?.start.character, 4)
    }

    func testLSPHoverResponseParserMarkedStringArray() {
        let json: [String: Any] = [
            "contents": [
                [
                    "language": "rust",
                    "value": "pub fn execute() -> Result<()>"
                ],
                "Runs the main execution loop."
            ]
        ]

        let hover = LSPHoverResponseParser.parse(from: json)
        XCTAssertNotNil(hover)
        XCTAssertEqual(hover?.contents.count, 2)
        XCTAssertTrue(hover?.markdownString.contains("```rust\npub fn execute") ?? false)
        XCTAssertTrue(hover?.markdownString.contains("Runs the main execution loop.") ?? false)
    }

    func testLSPHoverResponseParserNullAndEmpty() {
        XCTAssertNil(LSPHoverResponseParser.parse(from: nil))
        XCTAssertNil(LSPHoverResponseParser.parse(from: NSNull()))
        XCTAssertNil(LSPHoverResponseParser.parse(from: [String: Any]()))
        XCTAssertNil(LSPHoverResponseParser.parse(from: ["contents": ""]))
    }

    // MARK: - Document Synchronization & Save Lifecycle Tests

    func testMultiBufferOnBuffersSavedCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("TestFile.swift")
        try "initial content\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let buffer = Buffer(filePath: "TestFile.swift", text: "initial content", fullDiskPath: fileURL.path)
        let mb = MultiBuffer()
        mb.baseDirectory = tempDir.path
        mb.addBuffer(buffer)
        let excerpt = Excerpt(bufferId: buffer.id, filePath: "TestFile.swift", bufferRange: 0..<1)
        mb.setExcerpts([excerpt])

        final class Box: @unchecked Sendable {
            var files: [String] = []
        }
        let box = Box()
        mb.onBuffersSaved = { files in
            box.files = files
        }

        // Edit buffer
        _ = mb.replace(range: MultiBufferPoint(row: 0, column: 0)..<MultiBufferPoint(row: 0, column: 7), with: "updated")
        XCTAssertTrue(buffer.isDirty)

        let saved = mb.flushImmediateSave()
        XCTAssertEqual(saved, ["TestFile.swift"])
        XCTAssertEqual(box.files, ["TestFile.swift"])
        XCTAssertFalse(buffer.isDirty)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "updated content\n")
    }

    func testLSPWorkspaceServiceDocumentLifecycleTracking() async {
        let service = LSPWorkspaceService()
        let fakePath = "/tmp/fake_test_project/Main.swift"
        let root = "/tmp/fake_test_project"

        let isOpenInitial = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertFalse(isOpenInitial)

        await service.notifyDocumentOpened(filePath: fakePath, text: "let x = 1", rootPath: root)
        let isOpenAfterOpen = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertTrue(isOpenAfterOpen)

        // Saving should maintain open state
        await service.notifyDocumentSaved(filePath: fakePath, rootPath: root)
        let isOpenAfterSave = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertTrue(isOpenAfterSave)

        // Closing should remove from open set
        await service.notifyDocumentClosed(filePath: fakePath, rootPath: root)
        let isOpenAfterClose = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertFalse(isOpenAfterClose)
    }

    func testLSPWorkspaceServiceAutoOpensDocumentOnChanged() async {
        let service = LSPWorkspaceService()
        let fakePath = "/tmp/fake_test_project/App.swift"
        let root = "/tmp/fake_test_project"

        let isOpenInitial = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertFalse(isOpenInitial)

        // notifyDocumentChanged for an unopened file auto-opens it
        await service.notifyDocumentChanged(filePath: fakePath, text: "let y = 2", rootPath: root, debounceMs: 0)
        let isOpenAfterChange = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertTrue(isOpenAfterChange)

        await service.notifyDocumentClosed(filePath: fakePath, rootPath: root)
        let isOpenAfterClose = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertFalse(isOpenAfterClose)
    }

    func testLSPWorkspaceServiceStopAllClearsStateAndOpenDocuments() async {
        let service = LSPWorkspaceService()
        let fakePath = "/tmp/fake_test_project/App.swift"
        let root = "/tmp/fake_test_project"

        await service.notifyDocumentOpened(filePath: fakePath, text: "let y = 2", rootPath: root)
        let isOpen = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertTrue(isOpen)

        await service.stopAll()
        let isOpenAfterStopAll = await service.isDocumentOpen(filePath: fakePath, rootPath: root)
        XCTAssertFalse(isOpenAfterStopAll)
    }
}
