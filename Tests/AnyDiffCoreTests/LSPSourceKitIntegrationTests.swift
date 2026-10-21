import XCTest
@testable import AnyDiffCore

final class LSPSourceKitIntegrationTests: XCTestCase {

    override func tearDown() async throws {
        await LSPWorkspaceService.shared.stopAll()
    }

    func testSourceKitLSPGoToDefinitionDirect() async throws {
        // 1. Locate sourcekit-lsp
        guard let server = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDiffLSPTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 2. Set up a minimal Swift Package
        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "TestProject",
            targets: [
                .target(name: "TestProject")
            ]
        )
        """
        try packageSwift.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let sourcesDir = tempDir.appendingPathComponent("Sources/TestProject")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let testCode = """
        public struct GreeterService {
            public let greeting: String
            public init(greeting: String) {
                self.greeting = greeting
            }
        }

        public func runGreeter() {
            let service = GreeterService(greeting: "Hello, world!")
            print(service.greeting)
        }
        """
        let testFilePath = sourcesDir.appendingPathComponent("Greeter.swift").path
        try testCode.write(toFile: testFilePath, atomically: true, encoding: .utf8)

        // 3. Start LSPClient directly
        let client = LSPClient(
            executablePath: server.command,
            arguments: server.args,
            workingDirectory: tempDir.path
        )

        try await client.start(rootPath: tempDir.path)
        let state = await client.state
        XCTAssertEqual(state, .ready)

        // 4. Open document
        try await client.didOpen(filePath: testFilePath, text: testCode, languageId: "swift")

        // 5. Query Go to Definition for GreeterService on line 8 (0-based), col 18 ('G' in GreeterService)
        // In "    let service = GreeterService(greeting: "Hello, world!")"
        var locations: [LSPLocation] = []
        for _ in 0..<10 {
            locations = try await client.gotoDefinition(filePath: testFilePath, line: 8, character: 18)
            if !locations.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTAssertFalse(locations.isEmpty, "sourcekit-lsp should return definition locations")
        guard let location = locations.first else {
            XCTFail("No location returned")
            await client.stop()
            return
        }

        // Definition should point to `public struct GreeterService` on line 0 (0-based) -> targetLine 1 (1-based)
        XCTAssertEqual(location.targetLine, 1)
        XCTAssertTrue(location.targetFilePath.hasSuffix("Greeter.swift"))

        await client.stop()
    }

    func testWorkspaceServiceGoToDefinitionWorkflow() async throws {
        guard let _ = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDiffWorkspaceTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "WorkspaceTestProject",
            targets: [
                .target(name: "WorkspaceTestProject")
            ]
        )
        """
        try packageSwift.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let sourcesDir = tempDir.appendingPathComponent("Sources/WorkspaceTestProject")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let testCode = """
        public struct DataEngine {
            public var count: Int
            public init(count: Int) {
                self.count = count
            }
        }

        public func executePipeline() {
            let engine = DataEngine(count: 100)
            _ = engine
        }
        """
        let testFilePath = sourcesDir.appendingPathComponent("DataEngine.swift").path
        try testCode.write(toFile: testFilePath, atomically: true, encoding: .utf8)

        // Using high-level LSPWorkspaceService (1-based editor coordinates)
        // Line 9, Column 18 is 'D' in DataEngine
        var locations: [LSPLocation] = []
        for _ in 0..<10 {
            locations = try await LSPWorkspaceService.shared.gotoDefinition(
                filePath: testFilePath,
                line: 9,
                column: 18,
                rootPath: tempDir.path,
                contentSupplier: { testCode }
            )
            if !locations.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTAssertFalse(locations.isEmpty, "Workspace service should return definition locations via sourcekit-lsp")
        if let first = locations.first {
            XCTAssertEqual(first.targetLine, 1) // struct DataEngine is on line 1
            XCTAssertTrue(first.targetFilePath.hasSuffix("DataEngine.swift"))
        }

        await LSPWorkspaceService.shared.stopAll()
    }

    func testGoToDefinitionOnMultiBufferSwift() async throws {
        let root = FileManager.default.currentDirectoryPath
        let relativePath = "Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift"
        let fullPath = (root as NSString).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fullPath) else { return }

        let text = try String(contentsOfFile: fullPath)
        let lines = text.components(separatedBy: "\n")
        var targetLineIdx = -1
        var targetColIdx = -1
        for (idx, l) in lines.enumerated() {
            if let range = l.range(of: "filePath as NSString") {
                targetLineIdx = idx + 1 // 1-based line
                targetColIdx = l.distance(from: l.startIndex, to: range.lowerBound) + 3 // 1-based col inside filePath
                print("MultiBuffer.swift test target line: \(targetLineIdx), col: \(targetColIdx)")
                break
            }
        }

        XCTAssertTrue(targetLineIdx > 0)

        print("Calling gotoDefinition with relativePath: \(relativePath)")
        let locsRel = try await LSPWorkspaceService.shared.gotoDefinition(
            filePath: relativePath,
            line: targetLineIdx,
            column: targetColIdx,
            rootPath: root,
            contentSupplier: { text }
        )
        print("Locations returned with relativePath: \(locsRel)")

        print("Calling gotoDefinition with fullPath: \(fullPath)")
        let locsFull = try await LSPWorkspaceService.shared.gotoDefinition(
            filePath: fullPath,
            line: targetLineIdx,
            column: targetColIdx,
            rootPath: root,
            contentSupplier: { text }
        )
        print("Locations returned with fullPath: \(locsFull)")
    }

    func testSourceKitLSPCompletions() async throws {
        guard let _ = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDiffCompletionTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "CompletionTestProject",
            targets: [
                .target(name: "CompletionTestProject")
            ]
        )
        """
        try packageSwift.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let sourcesDir = tempDir.appendingPathComponent("Sources/CompletionTestProject")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let testCode = """
        public struct Profile {
            public var username: String
            public func displayName() -> String { username }
        }

        public func check() {
            let p = Profile(username: "antigravity")
            p.
        }
        """
        let testFilePath = sourcesDir.appendingPathComponent("Profile.swift").path
        try testCode.write(toFile: testFilePath, atomically: true, encoding: .utf8)

        // Line 8 is "    p.", column 7 is right after the dot (1-based: "    p." has 6 chars -> col 7)
        var items: [LSPCompletionItem] = []
        for _ in 0..<10 {
            items = try await LSPWorkspaceService.shared.getCompletions(
                filePath: testFilePath,
                line: 8,
                column: 7,
                rootPath: tempDir.path,
                triggerCharacter: ".",
                contentSupplier: { testCode }
            )
            if !items.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTAssertFalse(items.isEmpty, "sourcekit-lsp should return completions after dot")
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains("username") || $0.contains("displayName") }))
    }

    func testHoverOnLSPProcessSession() async throws {
        let root = FileManager.default.currentDirectoryPath
        let filePath = (root as NSString).appendingPathComponent("Sources/AnyDiffCore/LSP/Process/LSPProcessManager.swift")
        guard let text = try? String(contentsOfFile: filePath) else { return }
        let hover = try await LSPWorkspaceService.shared.getHover(
            filePath: filePath,
            line: 57,
            column: 24,
            rootPath: root,
            contentSupplier: { text }
        )
        XCTAssertNotNil(hover, "Hover on LSPProcessSession should return documentation/signature")
    }

    func testCSharpLSPWorkflowOnTestProject() async throws {
        guard let _ = await LSPWorkspaceService.shared.resolveServer(for: "csharp") else {
            throw XCTSkip("C# language server is not available on this machine")
        }

        let projectRoot = "/Users/max/dev/anycode/csharp-test-project"
        let programPath = (projectRoot as NSString).appendingPathComponent("Program.cs")
        guard FileManager.default.fileExists(atPath: programPath) else {
            throw XCTSkip("C# test project not present at \(projectRoot)")
        }

        let programText = try String(contentsOfFile: programPath, encoding: .utf8)

        // 1. Go to Definition on `Greeter` in `var greeter = new Greeter();` (1-based line 4, col 19)
        let locations = try await LSPWorkspaceService.shared.gotoDefinition(
            filePath: programPath,
            line: 4,
            column: 19,
            rootPath: projectRoot,
            contentSupplier: { programText }
        )
        XCTAssertFalse(locations.isEmpty, "C# LSP should resolve cross-file definition of Greeter")
        if let first = locations.first {
            XCTAssertTrue(first.targetFilePath.hasSuffix("Greeter.cs"))
            XCTAssertEqual(first.targetLine, 3)
        }

        // 2. Hover on `Greet` in `Console.WriteLine(greeter.Greet(name));` (1-based line 6, col 27)
        let hover = try await LSPWorkspaceService.shared.getHover(
            filePath: programPath,
            line: 6,
            column: 27,
            rootPath: projectRoot,
            contentSupplier: { programText }
        )
        XCTAssertNotNil(hover, "C# LSP should return hover signature for Greeter.Greet")
        XCTAssertTrue(hover?.markdownString.contains("Greet") ?? false)

        // 3. Code Completion after editing document via didChange (inserting `greeter.` on 1-based line 5)
        var editedLines = programText.components(separatedBy: "\n")
        if editedLines.count > 4 {
            editedLines[4] = "greeter."
        }
        let editedText = editedLines.joined(separator: "\n")

        let completions = try await LSPWorkspaceService.shared.getCompletions(
            filePath: programPath,
            line: 5,
            column: 9,
            rootPath: projectRoot,
            triggerCharacter: ".",
            contentSupplier: { editedText }
        )
        XCTAssertFalse(completions.isEmpty, "C# LSP should return completions after greeter. following incremental didChange")
        let labels = completions.map(\.label)
        XCTAssertTrue(labels.contains("Greet"), "Completions on greeter. should include Greet, got: \(labels)")

        // 4. Cold-start completion on a newly opened file (`HighlightShowcase.cs`) without prior hover/definition
        let showcasePath = (projectRoot as NSString).appendingPathComponent("HighlightShowcase.cs")
        if let showcaseText = try? String(contentsOfFile: showcasePath, encoding: .utf8) {
            let showcaseCompletions = try await LSPWorkspaceService.shared.getCompletions(
                filePath: showcasePath,
                line: 38,
                column: 22,
                rootPath: projectRoot,
                triggerCharacter: ".",
                contentSupplier: { showcaseText }
            )
            XCTAssertFalse(showcaseCompletions.isEmpty, "C# LSP should return completions on newly opened HighlightShowcase.cs")
            let showcaseLabels = showcaseCompletions.map(\.label)
            XCTAssertTrue(showcaseLabels.contains("AddRange"), "Completions on _people. should include AddRange")
        }
    }
}
