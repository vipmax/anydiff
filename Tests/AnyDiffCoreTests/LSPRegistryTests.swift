import XCTest
@testable import AnyDiffCore

final class LSPRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LSPRegistryBinaryDownloader.customBaseBinDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff-test-lsp-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let dir = LSPRegistryBinaryDownloader.customBaseBinDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        LSPRegistryBinaryDownloader.customBaseBinDirectory = nil
        super.tearDown()
    }

    // MARK: - Curated JSON Catalog Tests

    func testCuratedJSONCatalogLoadsCorrectly() {
        let servers = LSPRegistryService.loadDefaultServers()
        XCTAssertFalse(servers.isEmpty, "Curated servers catalog must not be empty")
        XCTAssertGreaterThanOrEqual(servers.count, 13, "Expected at least 13 curated servers")

        let expectedServerIds: Set<String> = [
            "rust-analyzer",
            "pyright",
            "typescript-language-server",
            "javascript-language-server",
            "vscode-json-language-server",
            "vscode-html-language-server",
            "vscode-css-language-server",
            "clangd",
            "clangd-cpp",
            "sourcekit-lsp",
            "marksman",
            "gopls",
            "yaml-language-server",
            "bash-language-server",
            "lua-language-server",
            "zls",
            "taplo",
            "roslyn-language-server",
            "csharp-ls",
            "jdtls",
            "kotlin-language-server",
            "intelephense",
            "ruby-lsp",
            "dart-language-server",
            "elixir-ls",
            "metals",
            "vue-language-server",
            "svelte-language-server",
            "astro-ls",
            "graphql-lsp",
            "prisma-language-server",
            "dockerfile-language-server-nodejs",
            "terraform-ls",
            "sql-language-server"
        ]

        let actualIds = Set(servers.map(\.id))
        for expectedId in expectedServerIds {
            XCTAssertTrue(actualIds.contains(expectedId), "Expected curated catalog to contain '\(expectedId)'")
        }

        for server in servers {
            XCTAssertFalse(server.name.isEmpty, "Server name must not be empty for \(server.id)")
            XCTAssertFalse(server.language.isEmpty, "Language must not be empty for \(server.id)")
            XCTAssertFalse(server.binary.isEmpty, "Binary must not be empty for \(server.id)")
            XCTAssertTrue(server.isLSP)
        }
    }

    // MARK: - Download Spec & Architecture Matching Tests

    func testDownloadSpecArchMatching() {
        let servers = LSPRegistryService.loadDefaultServers()

        // Rust-analyzer
        let rustAnalyzer = servers.first { $0.id == "rust-analyzer" }
        XCTAssertNotNil(rustAnalyzer)
        XCTAssertEqual(rustAnalyzer?.download?.type, .githubRelease)
        XCTAssertEqual(rustAnalyzer?.download?.owner, "rust-lang")
        XCTAssertEqual(rustAnalyzer?.download?.repo, "rust-analyzer")

        let rustArm = rustAnalyzer?.download?.matchingAsset(for: .arm64)
        XCTAssertNotNil(rustArm)
        XCTAssertTrue(rustArm?.file.contains("aarch64-apple-darwin") == true)
        XCTAssertEqual(rustArm?.archiveType, "gz")

        let rustIntel = rustAnalyzer?.download?.matchingAsset(for: .x86_64)
        XCTAssertNotNil(rustIntel)
        XCTAssertTrue(rustIntel?.file.contains("x86_64-apple-darwin") == true)
        XCTAssertEqual(rustIntel?.archiveType, "gz")

        // Marksman
        let marksman = servers.first { $0.id == "marksman" }
        XCTAssertNotNil(marksman)
        let marksmanArm = marksman?.download?.matchingAsset(for: .arm64)
        XCTAssertEqual(marksmanArm?.file, "marksman-macos")
        XCTAssertEqual(marksmanArm?.archiveType, "binary")

        // Clangd
        let clangd = servers.first { $0.id == "clangd" }
        XCTAssertNotNil(clangd)
        let clangdArm = clangd?.download?.matchingAsset(for: .arm64)
        XCTAssertTrue(clangdArm?.file.contains("clangd-mac-") == true)
        XCTAssertEqual(clangdArm?.archiveType, "zip")
        XCTAssertTrue(clangdArm?.relativeBin?.contains("bin/clangd") == true)

        // SourceKit-LSP is system toolchain
        let sourcekit = servers.first { $0.id == "sourcekit-lsp" }
        XCTAssertNotNil(sourcekit)
        XCTAssertEqual(sourcekit?.download?.type, .systemOnly)
    }

    func testNPMSpecs() {
        let servers = LSPRegistryService.loadDefaultServers()

        let pyright = servers.first { $0.id == "pyright" }
        XCTAssertNotNil(pyright)
        XCTAssertEqual(pyright?.download?.type, .npm)
        XCTAssertEqual(pyright?.download?.package, "pyright")
        XCTAssertEqual(pyright?.binary, "pyright-langserver")

        let ts = servers.first { $0.id == "typescript-language-server" }
        XCTAssertNotNil(ts)
        XCTAssertEqual(ts?.download?.type, .npm)
        XCTAssertEqual(ts?.download?.package, "typescript-language-server")

        let jsonServer = servers.first { $0.id == "vscode-json-language-server" }
        XCTAssertNotNil(jsonServer)
        XCTAssertEqual(jsonServer?.download?.type, .npm)
        XCTAssertEqual(jsonServer?.download?.package, "vscode-langservers-extracted")
        XCTAssertEqual(jsonServer?.binary, "vscode-json-language-server")
        XCTAssertEqual(jsonServer?.language, "json")

        let htmlServer = servers.first { $0.id == "vscode-html-language-server" }
        XCTAssertNotNil(htmlServer)
        XCTAssertEqual(htmlServer?.download?.type, .npm)
        XCTAssertEqual(htmlServer?.download?.package, "vscode-langservers-extracted")
        XCTAssertEqual(htmlServer?.binary, "vscode-html-language-server")
        XCTAssertEqual(htmlServer?.language, "html")

        let cssServer = servers.first { $0.id == "vscode-css-language-server" }
        XCTAssertNotNil(cssServer)
        XCTAssertEqual(cssServer?.download?.type, .npm)
        XCTAssertEqual(cssServer?.download?.package, "vscode-langservers-extracted")
        XCTAssertEqual(cssServer?.binary, "vscode-css-language-server")
        XCTAssertEqual(cssServer?.language, "css")
    }

    func testGoSpecs() {
        let servers = LSPRegistryService.loadDefaultServers()
        let gopls = servers.first { $0.id == "gopls" }
        XCTAssertNotNil(gopls)
        XCTAssertEqual(gopls?.download?.type, .go)
        XCTAssertEqual(gopls?.download?.package, "golang.org/x/tools/gopls@latest")
        XCTAssertEqual(gopls?.binary, "gopls")
    }

    // MARK: - Binary Downloader & Directory Tests

    func testPackageDirectoryIsolation() {
        let dir = LSPRegistryBinaryDownloader.packageDirectory(serverId: "rust-analyzer")
        XCTAssertTrue(dir.path.contains("rust-analyzer"))
    }

    func testInstalledStatusAndRemoval() throws {
        let testDef = LSPServerDefinition(
            id: "test-server",
            name: "Test Server",
            language: "swift",
            fileExtensions: ["swift"],
            summary: "Test LSP server",
            binary: "test-server",
            arguments: ["--stdio"],
            download: nil
        )

        XCTAssertFalse(LSPRegistryBinaryDownloader.isInstalled(package: testDef))

        // Create dummy executable in expected package directory
        let targetDir = LSPRegistryBinaryDownloader.packageDirectory(serverId: testDef.id)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let dummyPath = targetDir.appendingPathComponent("test-server").path
        FileManager.default.createFile(atPath: dummyPath, contents: "#!/bin/sh\necho test\n".data(using: .utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyPath)

        XCTAssertTrue(LSPRegistryBinaryDownloader.isInstalled(package: testDef))
        XCTAssertEqual(LSPRegistryBinaryDownloader.installedExecutablePath(package: testDef), dummyPath)

        // Remove
        LSPRegistryBinaryDownloader.removePackage(packageId: testDef.id)
        XCTAssertFalse(LSPRegistryBinaryDownloader.isInstalled(package: testDef))
    }

    // MARK: - Launch Command Generation Tests

    func testLaunchCommandArguments() throws {
        let pyrightSpec = LSPServerCatalog.launchSpec(for: "pyright")
        XCTAssertEqual(pyrightSpec.arguments, ["--stdio"])
        XCTAssertEqual(pyrightSpec.preferredBinary, "pyright-langserver")

        let bashSpec = LSPServerCatalog.launchSpec(for: "bash-language-server")
        XCTAssertEqual(bashSpec.arguments, ["start"])

        let taploSpec = LSPServerCatalog.launchSpec(for: "taplo")
        XCTAssertEqual(taploSpec.arguments, ["lsp", "stdio"])

        let pyright = LSPServerDefinition(
            id: "pyright",
            name: "Pyright",
            language: "python",
            fileExtensions: ["py", "pyi"],
            summary: "Python LSP",
            binary: "pyright-langserver",
            arguments: ["--stdio"],
            download: LSPServerDownloadSpec(
                type: .npm,
                package: "pyright",
                bin: "node_modules/.bin/pyright-langserver"
            )
        )

        // When uninstalled, returns nil (no phantom execution)
        XCTAssertNil(LSPRegistryService.shared.launchCommand(for: pyright))

        // Create mock installed binary in package dir
        let targetDir = LSPRegistryBinaryDownloader.packageDirectory(serverId: "pyright")
        let binDir = targetDir.appendingPathComponent("node_modules/.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let mockBin = binDir.appendingPathComponent("pyright-langserver")
        try "#!/bin/sh\nexit 0\n".write(to: mockBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockBin.path)

        let cmd = LSPRegistryService.shared.launchCommand(for: pyright)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.command, mockBin.path)
        XCTAssertEqual(cmd?.arguments, ["--stdio"])
    }

    // MARK: - Process Manager Tests

    func testProcessManagerLifecycle() async {
        let pm = LSPProcessManager()
        let isRunning = await pm.isRunning(packageId: "fake-package")
        XCTAssertFalse(isRunning)
        await pm.terminateAll()
    }

    // MARK: - Canonical Server Name Tests

    func testCanonicalServerNameNormalization() {
        // Direct binaries
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(fromExecutablePath: "/usr/bin/sourcekit-lsp"),
            "sourcekit-lsp"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(fromExecutablePath: "/Users/test/.cargo/bin/rust-analyzer"),
            "rust-analyzer"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(fromExecutablePath: "/opt/homebrew/bin/clangd"),
            "clangd"
        )

        // npx with explicit tool argument
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "/usr/local/bin/npx",
                arguments: ["-y", "pyright", "--stdio"]
            ),
            "pyright"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "/Users/test/.nvm/versions/node/v24.9.0/bin/npx",
                arguments: ["-y", "vscode-langservers-extracted", "vscode-html-language-server", "--stdio"]
            ),
            "vscode-html-language-server"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "/usr/local/bin/npx",
                arguments: ["-y", "@agentclientprotocol/codex-acp"]
            ),
            "codex-acp"
        )

        // Generic runner with language fallback
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "/usr/local/bin/npx",
                fallbackLanguageId: "python"
            ),
            "pyright"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "npx",
                fallbackLanguageId: "typescript"
            ),
            "typescript-language-server"
        )
        XCTAssertEqual(
            LSPServerCatalog.canonicalServerName(
                fromExecutablePath: "/bin/sh",
                fallbackLanguageId: "json"
            ),
            "vscode-json-language-server"
        )
    }

    func testDiscoverAvailableServersNeverReturnsGenericRunners() async {
        let servers = await LSPWorkspaceService.shared.discoverAvailableServers()
        let forbiddenNames: Set<String> = ["npx", "node", "bun", "python", "python3", "sh", "bash", "env"]

        for s in servers {
            XCTAssertFalse(
                forbiddenNames.contains(s.serverName.lowercased()),
                "Language server for \(s.languageId) resolved to generic runner name '\(s.serverName)' instead of canonical server name."
            )
            XCTAssertFalse(s.serverName.isEmpty, "Server name for \(s.languageId) must not be empty")
        }
    }

    func testCatalogDrivenFileExtensionDetection() {
        let ws = LSPWorkspaceService.shared
        XCTAssertEqual(ws.detectLanguage(for: "main.rs"), "rust")
        XCTAssertEqual(ws.detectLanguage(for: "app.py"), "python")
        XCTAssertEqual(ws.detectLanguage(for: "types.pyi"), "python")
        XCTAssertEqual(ws.detectLanguage(for: "Package.swift"), "swift")
        XCTAssertEqual(ws.detectLanguage(for: "index.ts"), "typescript")
        XCTAssertEqual(ws.detectLanguage(for: "app.tsx"), "typescript")
        XCTAssertEqual(ws.detectLanguage(for: "server.js"), "javascript")
        XCTAssertEqual(ws.detectLanguage(for: "index.html"), "html")
        XCTAssertEqual(ws.detectLanguage(for: "styles.css"), "css")
        XCTAssertEqual(ws.detectLanguage(for: "config.json"), "json")
        XCTAssertEqual(ws.detectLanguage(for: "README.md"), "markdown")
        XCTAssertEqual(ws.detectLanguage(for: "Cargo.toml"), "toml")
        XCTAssertEqual(ws.detectLanguage(for: "workflow.yml"), "yaml")
        XCTAssertEqual(ws.detectLanguage(for: "script.sh"), "bash")
        XCTAssertEqual(ws.detectLanguage(for: "main.zig"), "zig")
        XCTAssertEqual(ws.detectLanguage(for: "init.lua"), "lua")
        XCTAssertEqual(ws.detectLanguage(for: "main.go"), "go")
        XCTAssertEqual(ws.detectLanguage(for: "Program.cs"), "csharp")
        XCTAssertEqual(ws.detectLanguage(for: "script.csx"), "csharp")
        XCTAssertEqual(ws.detectLanguage(for: "Main.java"), "java")
        XCTAssertEqual(ws.detectLanguage(for: "App.kt"), "kotlin")
        XCTAssertEqual(ws.detectLanguage(for: "build.gradle.kts"), "kotlin")
        XCTAssertEqual(ws.detectLanguage(for: "index.php"), "php")
        XCTAssertEqual(ws.detectLanguage(for: "app.rb"), "ruby")
        XCTAssertEqual(ws.detectLanguage(for: "main.dart"), "dart")
        XCTAssertEqual(ws.detectLanguage(for: "router.ex"), "elixir")
        XCTAssertEqual(ws.detectLanguage(for: "Main.scala"), "scala")
        XCTAssertEqual(ws.detectLanguage(for: "App.vue"), "vue")
        XCTAssertEqual(ws.detectLanguage(for: "Counter.svelte"), "svelte")
        XCTAssertEqual(ws.detectLanguage(for: "Layout.astro"), "astro")
        XCTAssertEqual(ws.detectLanguage(for: "schema.graphql"), "graphql")
        XCTAssertEqual(ws.detectLanguage(for: "schema.prisma"), "prisma")
        XCTAssertEqual(ws.detectLanguage(for: "Dockerfile"), "dockerfile")
        XCTAssertEqual(ws.detectLanguage(for: "Dockerfile.prod"), "dockerfile")
        XCTAssertEqual(ws.detectLanguage(for: "main.tf"), "terraform")
        XCTAssertEqual(ws.detectLanguage(for: "query.sql"), "sql")
        XCTAssertEqual(Buffer.detectLanguage(for: "Program.cs"), "csharp")
        XCTAssertEqual(Buffer.detectLanguage(for: "Main.java"), "java")
        XCTAssertEqual(Buffer.detectLanguage(for: "App.kt"), "kotlin")
        XCTAssertEqual(Buffer.detectLanguage(for: "index.php"), "php")
        XCTAssertEqual(Buffer.detectLanguage(for: "app.rb"), "ruby")
        XCTAssertEqual(Buffer.detectLanguage(for: "main.dart"), "dart")
        XCTAssertEqual(Buffer.detectLanguage(for: "Dockerfile"), "dockerfile")
        XCTAssertEqual(Buffer.detectLanguage(for: "main.tf"), "terraform")
        XCTAssertEqual(Buffer.detectLanguage(for: "query.sql"), "sql")

        // React / JSX / TSX protocol languageId
        XCTAssertEqual(ws.documentLanguageId(for: "App.tsx"), "typescriptreact")
        XCTAssertEqual(ws.documentLanguageId(for: "Component.jsx"), "javascriptreact")
        XCTAssertEqual(ws.documentLanguageId(for: "index.ts"), "typescript")
        XCTAssertEqual(ws.documentLanguageId(for: "server.js"), "javascript")
    }

    func testServerDefinitionLaunchHelpers() {
        let servers = LSPRegistryService.loadDefaultServers()

        let pyright = servers.first { $0.id == "pyright" }!
        XCTAssertEqual(pyright.launchArguments(), ["--stdio"])
        XCTAssertEqual(pyright.binary, "pyright-langserver")
        XCTAssertEqual(pyright.binaryName(), "pyright-langserver")
        XCTAssertEqual(pyright.canonicalName(), "pyright")

        let jsonServer = servers.first { $0.id == "vscode-json-language-server" }!
        XCTAssertEqual(jsonServer.launchArguments(), ["--stdio"])
        XCTAssertEqual(jsonServer.binary, "vscode-json-language-server")
        XCTAssertEqual(jsonServer.canonicalName(), "vscode-json-language-server")

        let clangd = servers.first { $0.id == "clangd" }!
        XCTAssertEqual(clangd.launchArguments(), ["--background-index"])
        XCTAssertEqual(clangd.binary, "clangd")
        XCTAssertEqual(clangd.binaryName(), "clangd")

        let roslyn = servers.first { $0.id == "roslyn-language-server" }!
        XCTAssertEqual(roslyn.launchArguments(), ["--stdio", "--autoLoadProjects"])
        XCTAssertEqual(roslyn.binary, "roslyn-language-server")
        XCTAssertEqual(roslyn.canonicalName(), "roslyn-language-server")
        XCTAssertEqual(roslyn.name, "Roslyn Language Server (C#)")
    }

    func testPackageAvailabilityAndControl() async {
        let servers = LSPRegistryService.loadDefaultServers()
        let sourcekit = servers.first { $0.id == "sourcekit-lsp" }!
        let ws = LSPWorkspaceService.shared

        let isAvail = await ws.isPackageAvailable(sourcekit)
        // sourcekit-lsp is available on macOS if Xcode or Command Line Tools are installed
        if FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
            XCTAssertTrue(isAvail, "sourcekit-lsp should be recognized as available on macOS with developer tools")
        }

        // Test stopping package does not crash
        await ws.stopPackage(sourcekit)
    }

    func testCSharpServerResolutionAndHighlighting() async {
        let ws = LSPWorkspaceService.shared
        let resolved = await ws.resolveServer(for: "csharp")
        if let resolved = resolved {
            XCTAssertTrue(resolved.command.contains("roslyn-language-server") || resolved.command.contains("csharp-ls"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved.command))
        } else {
            print("C# language server not installed locally, skipping binary resolution assertion")
        }

        // Test syntax highlighting for C#
        let code = "using System; public sealed class Greeter { var msg = $\"Hello, world!\"; }"
        let spans = SyntaxHighlighter.shared.tokenize(line: code, language: "csharp")
        XCTAssertFalse(spans.isEmpty)
        let keywords = spans.filter { $0.tokenType == .keyword }
        XCTAssertTrue(keywords.count >= 4, "Should highlight using, public, sealed, class, var")
        let strings = spans.filter { $0.tokenType == .string }
        XCTAssertFalse(strings.isEmpty, "Should highlight $\"Hello, world!\" as string")
    }

    func testIdleTimeoutAutoStopsUnusedServer() async throws {
        let ws = LSPWorkspaceService()
        let defaultTimeout = await ws.idleTimeout
        XCTAssertEqual(defaultTimeout, 300, "Default LSP idle timeout should be 5 minutes (300 seconds)")

        guard let _ = await ws.resolveServer(for: "swift") else {
            throw XCTSkip("sourcekit-lsp not available on this machine")
        }

        await ws.setIdleTimeout(0.35)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        let client = try await ws.getOrStartClient(for: "swift", rootPath: repoRoot)
        XCTAssertNotNil(client)

        var statuses = await ws.activeServerStatuses()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.languageId, "swift")
        XCTAssertNotNil(statuses.first?.autoStopDeadline)

        // Disabling auto-stop clears the deadline and prevents shutdown
        await ws.setAutoStopEnabled(false, persist: false)
        statuses = await ws.activeServerStatuses()
        XCTAssertNil(statuses.first?.autoStopDeadline)
        try await Task.sleep(nanoseconds: 450_000_000)
        statuses = await ws.activeServerStatuses()
        XCTAssertEqual(statuses.count, 1, "Server should remain active when auto-stop is disabled")

        // Re-enabling auto-stop starts a fresh countdown
        await ws.setAutoStopEnabled(true, persist: false)
        statuses = await ws.activeServerStatuses()
        XCTAssertNotNil(statuses.first?.autoStopDeadline)

        // Activity before timeout should reset the timer and keep the server alive
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await ws.getOrStartClient(for: "swift", rootPath: repoRoot)
        try await Task.sleep(nanoseconds: 200_000_000)
        statuses = await ws.activeServerStatuses()
        XCTAssertEqual(statuses.count, 1, "Server should remain active when activity resets the idle timer")

        // Wait for full idle timeout to elapse without activity
        try await Task.sleep(nanoseconds: 300_000_000)
        statuses = await ws.activeServerStatuses()
        XCTAssertTrue(statuses.isEmpty, "Server should automatically shut down after idle timeout")
        let clientState = await client?.state
        XCTAssertEqual(clientState, .stopped)
    }

    func testTypeScriptReactServerStartsWithBundledTsServer() async throws {
        try requireIntegrationTestsEnabled()

        let prevCustomDir = LSPRegistryBinaryDownloader.customBaseBinDirectory
        let userBinDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anydiff/lsp/bin", isDirectory: true)
        LSPRegistryBinaryDownloader.customBaseBinDirectory = userBinDir
        defer { LSPRegistryBinaryDownloader.customBaseBinDirectory = prevCustomDir }

        let ws = LSPWorkspaceService()
        guard let resolved = await ws.resolveServer(for: "typescript") else {
            throw XCTSkip("typescript-language-server not installed in ~/.anydiff/lsp/bin")
        }

        let tempWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff-tsx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempWorkspace) }

        let tsxFile = tempWorkspace.appendingPathComponent("App.tsx")
        let tsxContent = """
        export interface Props {
            title: string;
        }
        export function App(props: Props) {
            return <div>{props.title}</div>;
        }
        """
        try tsxContent.write(to: tsxFile, atomically: true, encoding: .utf8)

        let client = try await ws.getOrStartClient(for: "typescript", rootPath: tempWorkspace.path)
        XCTAssertNotNil(client, "typescript-language-server should start even when workspace has no local node_modules/typescript")
        let state = await client?.state
        XCTAssertEqual(state, .ready)

        let docLang = ws.documentLanguageId(for: tsxFile.path)
        XCTAssertEqual(docLang, "typescriptreact")
        try await client?.didOpen(filePath: tsxFile.path, text: tsxContent, languageId: docLang)

        let hover = try await client?.getHover(filePath: tsxFile.path, line: 3, character: 17)
        XCTAssertNotNil(hover, "Hover on React TSX component function should return type info")
        let hoverText = hover?.contents.joined(separator: "\n") ?? ""
        XCTAssertTrue(hoverText.contains("App"), "Hover contents should mention App, got: \(hoverText)")

        await ws.stopServer(for: "typescript")
        _ = resolved
    }

    func testAllCatalogDownloadURLsAreValidAndReachable() async throws {
        let servers = LSPRegistryService.loadDefaultServers()
        var urlsToCheck: [(id: String, label: String, url: URL)] = []

        for server in servers {
            guard let dl = server.download else { continue }
            switch dl.type {
            case .githubRelease:
                let assets: [(String, LSPDownloadAsset?)] = [
                    ("asset", dl.asset),
                    ("arm64", dl.arm64),
                    ("x86_64", dl.x86_64)
                ]
                for (archLabel, maybeAsset) in assets {
                    guard let asset = maybeAsset else { continue }
                    let urlStr: String
                    if let direct = asset.url, !direct.isEmpty {
                        urlStr = direct
                    } else if let owner = dl.owner, let repo = dl.repo, let tag = dl.tag {
                        urlStr = "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(asset.file)"
                    } else {
                        XCTFail("Missing URL metadata for \(server.id) (\(archLabel))")
                        continue
                    }
                    guard let url = URL(string: urlStr) else {
                        XCTFail("Invalid URL for \(server.id) (\(archLabel)): \(urlStr)")
                        continue
                    }
                    urlsToCheck.append((server.id, archLabel, url))
                }
            case .npm:
                guard let pkg = dl.package, let ver = dl.version else {
                    XCTFail("Missing npm package or version for \(server.id)")
                    continue
                }
                let urlStr = "https://registry.npmjs.org/\(pkg)/\(ver)"
                guard let url = URL(string: urlStr) else {
                    XCTFail("Invalid npm URL for \(server.id): \(urlStr)")
                    continue
                }
                urlsToCheck.append((server.id, "npm", url))
            case .go, .systemOnly:
                break
            }
        }

        XCTAssertFalse(urlsToCheck.isEmpty)

        // Live network reachability check is gated by ANYDIFF_RUN_INTEGRATION_TESTS=1
        try requireIntegrationTestsEnabled()

        try await withThrowingTaskGroup(of: (String, String, Int, String).self) { group in
            for item in urlsToCheck {
                group.addTask {
                    var req = URLRequest(url: item.url)
                    req.httpMethod = "HEAD"
                    req.timeoutInterval = 15
                    req.setValue("AnyDiff-LSP-Test/1.0", forHTTPHeaderField: "User-Agent")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    return (item.id, item.label, status, item.url.absoluteString)
                }
            }

            for try await (id, label, status, urlStr) in group {
                XCTAssertTrue(
                    (200..<400).contains(status),
                    "Download URL for \(id) (\(label)) returned HTTP \(status): \(urlStr)"
                )
            }
        }
    }
}
