import XCTest
@testable import AnyDiffCore

final class LSPSourceKitIntegrationTests: XCTestCase {

    private static var sharedSwiftPackageURL: URL?

    private static func sharedSwiftPackage() throws -> URL {
        if let existing = sharedSwiftPackageURL, FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyDiffSharedLSPTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "SharedLSPTestProject",
            targets: [
                .target(name: "GreeterKit"),
                .target(name: "DataEngineKit"),
                .target(name: "CompletionKit")
            ]
        )
        """
        try packageSwift.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let files: [(target: String, name: String, code: String)] = [
            ("GreeterKit", "Greeter.swift", """
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
            """),
            ("DataEngineKit", "DataEngine.swift", """
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

            /// Summarizes pipeline metrics.
            public func summarizePipeline() -> Int { 42 }
            """),
            ("CompletionKit", "Profile.swift", """
            public struct Profile {
                public var username: String
                public func displayName() -> String { username }
            }

            public func check() {
                let p = Profile(username: "antigravity")
                p.
            }
            """)
        ]

        for entry in files {
            let dir = tempDir.appendingPathComponent("Sources/\(entry.target)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try entry.code.write(to: dir.appendingPathComponent(entry.name), atomically: true, encoding: .utf8)
        }

        sharedSwiftPackageURL = tempDir
        return tempDir
    }

    override class func tearDown() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await LSPWorkspaceService.shared.stopAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        if let dir = sharedSwiftPackageURL {
            try? FileManager.default.removeItem(at: dir)
            sharedSwiftPackageURL = nil
        }
        super.tearDown()
    }

    func testSourceKitLSPGoToDefinitionDirect() async throws {
        // 1. Locate sourcekit-lsp
        guard let server = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = try Self.sharedSwiftPackage()
        let testFilePath = tempDir.appendingPathComponent("Sources/GreeterKit/Greeter.swift").path
        let testCode = try String(contentsOfFile: testFilePath, encoding: .utf8)

        // 2. Start LSPClient directly
        let client = LSPClient(
            executablePath: server.command,
            arguments: server.args,
            workingDirectory: tempDir.path
        )

        try await client.start(rootPath: tempDir.path)
        let state = await client.state
        XCTAssertEqual(state, .ready)

        // 3. Open document
        try await client.didOpen(filePath: testFilePath, text: testCode, languageId: "swift")

        // 4. Query Go to Definition for GreeterService on line 8 (0-based), col 18 ('G' in GreeterService)
        // In "    let service = GreeterService(greeting: "Hello, world!")"
        var locations: [LSPLocation] = []
        for _ in 0..<60 {
            locations = try await client.gotoDefinition(filePath: testFilePath, line: 8, character: 18)
            if !locations.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
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

        let tempDir = try Self.sharedSwiftPackage()
        let testFilePath = tempDir.appendingPathComponent("Sources/DataEngineKit/DataEngine.swift").path
        let testCode = try String(contentsOfFile: testFilePath, encoding: .utf8)

        // Using high-level LSPWorkspaceService (1-based editor coordinates)
        // Line 9, Column 18 is 'D' in DataEngine
        var locations: [LSPLocation] = []
        for _ in 0..<60 {
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
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(locations.isEmpty, "Workspace service should return definition locations via sourcekit-lsp")
        if let first = locations.first {
            XCTAssertEqual(first.targetLine, 1) // struct DataEngine is on line 1
            XCTAssertTrue(first.targetFilePath.hasSuffix("DataEngine.swift"))
        }
    }

    func testSourceKitLSPCompletions() async throws {
        guard let _ = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = try Self.sharedSwiftPackage()
        let testFilePath = tempDir.appendingPathComponent("Sources/CompletionKit/Profile.swift").path
        let testCode = try String(contentsOfFile: testFilePath, encoding: .utf8)

        // Line 8 is "    p.", column 7 is right after the dot (1-based: "    p." has 6 chars -> col 7)
        var items: [LSPCompletionItem] = []
        for _ in 0..<60 {
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
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(items.isEmpty, "sourcekit-lsp should return completions after dot")
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains(where: { $0.contains("username") || $0.contains("displayName") }))
    }

    func testHoverOnLSPProcessSession() async throws {
        guard let _ = await LSPWorkspaceService.shared.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp executable is not available on this machine")
        }

        let tempDir = try Self.sharedSwiftPackage()
        let filePath = tempDir.appendingPathComponent("Sources/DataEngineKit/DataEngine.swift").path
        let text = try String(contentsOfFile: filePath, encoding: .utf8)

        // Line 14, Column 13 is 'summarizePipeline' in "public func summarizePipeline() -> Int { 42 }"
        var hover: LSPHover?
        for _ in 0..<60 {
            hover = try await LSPWorkspaceService.shared.getHover(
                filePath: filePath,
                line: 14,
                column: 13,
                rootPath: tempDir.path,
                contentSupplier: { text }
            )
            if hover != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(hover, "Hover on summarizePipeline should return documentation/signature")
    }
}
