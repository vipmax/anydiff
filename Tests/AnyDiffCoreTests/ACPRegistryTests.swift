import XCTest
@testable import AnyDiffCore

final class ACPRegistryTests: XCTestCase {
    let sampleRegistryJSON = """
    {
      "version": "1.0.0",
      "agents": [
        {
          "id": "sample-npx-agent",
          "name": "Sample NPX Agent",
          "version": "1.2.3",
          "description": "An agent running via npx",
          "repository": "https://github.com/example/sample-npx",
          "authors": ["Sample Author"],
          "license": "MIT",
          "distribution": {
            "npx": {
              "package": "@example/sample-npx@1.2.3",
              "args": ["--acp", "--verbose"],
              "env": { "TEST_ENV": "1" }
            }
          }
        },
        {
          "id": "sample-binary-agent",
          "name": "Sample Binary Agent",
          "version": "2.0.0",
          "description": "A native binary agent",
          "repository": "https://github.com/example/sample-bin",
          "authors": ["Binary Team"],
          "distribution": {
            "binary": {
              "darwin-aarch64": {
                "archive": "https://example.com/darwin-arm64.tar.gz",
                "cmd": "./sample-bin",
                "args": ["--mode=acp"],
                "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
              },
              "darwin-x86_64": {
                "archive": "https://example.com/darwin-x86_64.tar.gz",
                "cmd": "./sample-bin",
                "args": ["--mode=acp"]
              }
            }
          }
        }
      ]
    }
    """

    func testRegistryJSONParsing() throws {
        let data = sampleRegistryJSON.data(using: .utf8)!
        let decoder = JSONDecoder()
        let index = try decoder.decode(ACPRegistryIndex.self, from: data)

        XCTAssertEqual(index.version, "1.0.0")
        XCTAssertEqual(index.agents.count, 2)

        let npxAgent = index.agents[0]
        XCTAssertEqual(npxAgent.id, "sample-npx-agent")
        XCTAssertEqual(npxAgent.name, "Sample NPX Agent")
        XCTAssertEqual(npxAgent.version, "1.2.3")
        XCTAssertNotNil(npxAgent.distribution.npx)
        XCTAssertEqual(npxAgent.distribution.npx?.package, "@example/sample-npx@1.2.3")
        XCTAssertEqual(npxAgent.distribution.npx?.args, ["--acp", "--verbose"])
        XCTAssertTrue(npxAgent.isSupportedOnCurrentPlatform)

        let binaryAgent = index.agents[1]
        XCTAssertEqual(binaryAgent.id, "sample-binary-agent")
        XCTAssertEqual(binaryAgent.name, "Sample Binary Agent")
        XCTAssertNotNil(binaryAgent.distribution.binary)
        XCTAssertTrue(binaryAgent.isSupportedOnCurrentPlatform)
        XCTAssertNotNil(binaryAgent.currentPlatformBinaryTarget)
    }

    func testAgentPresetConversionNpx() throws {
        let data = sampleRegistryJSON.data(using: .utf8)!
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: data)
        let npxAgent = index.agents[0]

        let preset = npxAgent.toAgentPreset()
        XCTAssertEqual(preset.id, "sample-npx-agent")
        XCTAssertEqual(preset.name, "Sample NPX Agent")
        XCTAssertEqual(preset.command, "npx")
        XCTAssertEqual(preset.arguments, "-y @example/sample-npx@1.2.3 --acp --verbose")
        XCTAssertEqual(preset.providerName, "Sample Author")
        XCTAssertTrue(preset.isCustom)
        XCTAssertFalse(preset.isMock)
        XCTAssertEqual(preset.effectiveCommand, "npx -y @example/sample-npx@1.2.3 --acp --verbose")
    }

    func testAgentPresetConversionBinary() throws {
        let data = sampleRegistryJSON.data(using: .utf8)!
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: data)
        let binaryAgent = index.agents[1]

        // 1. Without installed path (defaults to expected Application Support path)
        let defaultPreset = binaryAgent.toAgentPreset()
        XCTAssertEqual(defaultPreset.id, "sample-binary-agent")
        XCTAssertTrue(defaultPreset.command.contains("AnyDiff/bin/sample-binary-agent/2.0.0/sample-bin"))
        XCTAssertEqual(defaultPreset.arguments, "--mode=acp")

        // 2. With installed path provided
        let customPath = "/opt/custom/sample-bin"
        let installedPreset = binaryAgent.toAgentPreset(binaryInstalledPath: customPath)
        XCTAssertEqual(installedPreset.command, customPath)
        XCTAssertEqual(installedPreset.arguments, "--mode=acp")
    }

    func testCoordinatorInstallAndUninstall() throws {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)
        let data = sampleRegistryJSON.data(using: .utf8)!
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: data)
        let npxAgent = index.agents[0]

        XCTAssertFalse(coordinator.isAgentInstalled(id: npxAgent.id))

        let installedPreset = coordinator.installRegistryAgent(npxAgent)
        XCTAssertEqual(installedPreset.id, npxAgent.id)
        XCTAssertTrue(coordinator.isAgentInstalled(id: npxAgent.id))
        XCTAssertTrue(coordinator.allPresets.contains(where: { $0.id == npxAgent.id }))

        coordinator.uninstallRegistryAgent(id: npxAgent.id)
        XCTAssertFalse(coordinator.isAgentInstalled(id: npxAgent.id))
        XCTAssertFalse(coordinator.allPresets.contains(where: { $0.id == npxAgent.id }))
    }

    func testSanitizeCmd() {
        XCTAssertEqual(ACPRegistryBinaryDownloader.sanitizeCmd("./bin-agent"), "bin-agent")
        XCTAssertEqual(ACPRegistryBinaryDownloader.sanitizeCmd("bin-agent"), "bin-agent")
        XCTAssertEqual(ACPRegistryBinaryDownloader.sanitizeCmd(" ./bin-agent "), "bin-agent")
    }

    func testEffectiveCommandMultiWordAndSpaces() {
        // Multi-word command without arguments (e.g. user entered "npx -y custom-acp")
        let npxPreset = AgentPreset(
            name: "Custom NPX",
            command: "npx -y custom-acp"
        )
        XCTAssertEqual(npxPreset.effectiveCommand, "npx -y custom-acp")

        // Shell pipeline / compound command (e.g. agy preset)
        let agyPreset = AgentPreset.agy
        XCTAssertFalse(agyPreset.effectiveCommand.hasPrefix("\""))
        XCTAssertEqual(agyPreset.effectiveCommand, "command -v agy-acp-server >/dev/null 2>&1 && agy-acp-server || agy --acp")

        // Command with separate arguments
        let pythonPreset = AgentPreset(
            name: "Python Agent",
            command: "python3",
            arguments: "-m my_agent --port 8080"
        )
        XCTAssertEqual(pythonPreset.effectiveCommand, "python3 -m my_agent --port 8080")

        // Quoted path with spaces
        let spacePathPreset = AgentPreset(
            name: "Space Agent",
            command: "\"/Users/test/Application Support/agent\"",
            arguments: "--acp"
        )
        XCTAssertEqual(spacePathPreset.effectiveCommand, "\"/Users/test/Application Support/agent\" --acp")
    }

    func testBinaryDownloaderCancellationThrowsCancellationError() async {
        let target = ACPRegistryBinaryTarget(
            archive: "https://example.com/nonexistent_archive.tar.gz",
            cmd: "dummy"
        )
        let downloadTask = Task {
            try await ACPRegistryBinaryDownloader.downloadAndInstall(
                agentId: "test-agent",
                version: "1.0.0",
                target: target
            )
        }
        downloadTask.cancel()
        do {
            _ = try await downloadTask.value
            XCTFail("Should have thrown CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, but got: \(type(of: error)): \(error)")
        }
    }

    func testAgentPresetVersionCodable() throws {
        // 1. With version
        let presetWithVersion = AgentPreset(
            id: "test-ver",
            name: "Test",
            version: "1.2.3",
            command: "test"
        )
        let data = try JSONEncoder().encode(presetWithVersion)
        let decoded = try JSONDecoder().decode(AgentPreset.self, from: data)
        XCTAssertEqual(decoded.version, "1.2.3")

        // 2. Backward compatibility with legacy JSON without version
        let legacyJSON = """
        {
          "id": "legacy",
          "name": "Legacy Agent",
          "command": "legacy-cmd",
          "arguments": "--flag"
        }
        """.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(AgentPreset.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.id, "legacy")
        XCTAssertNil(legacyDecoded.version)
    }

    func testCoordinatorVersionDetectionAndUpdateAvailable() throws {
        let coordinator = AgentSessionCoordinator()
        let agentId = "antigravity-acp"

        let entryV1 = ACPRegistryAgentEntry(
            id: agentId,
            name: "Google Antigravity",
            version: "1.0.0",
            description: "AI Agent",
            distribution: ACPRegistryDistribution(
                binary: [
                    ACPRegistryAgentEntry.currentPlatformKey: ACPRegistryBinaryTarget(
                        archive: "https://example.com/agy.zip",
                        cmd: "./agy_acp_server.par"
                    )
                ]
            )
        )

        // Before installation
        XCTAssertFalse(coordinator.isAgentInstalled(id: agentId))
        XCTAssertFalse(coordinator.hasUpdateAvailable(for: entryV1))

        // Install v1.0.0
        coordinator.installRegistryAgent(entryV1, binaryPath: "/fake/path/to/agy_acp_server.par")
        XCTAssertTrue(coordinator.isAgentInstalled(id: agentId))
        XCTAssertEqual(coordinator.installedVersion(for: agentId), "1.0.0")
        XCTAssertFalse(coordinator.hasUpdateAvailable(for: entryV1))

        // Registry entry with v1.1.1 released
        let entryV2 = ACPRegistryAgentEntry(
            id: agentId,
            name: "Google Antigravity",
            version: "1.1.1",
            description: "AI Agent",
            distribution: entryV1.distribution
        )

        // Update should be detected!
        XCTAssertTrue(coordinator.hasUpdateAvailable(for: entryV2))

        // Update installed agent to v1.1.1
        coordinator.installRegistryAgent(entryV2, binaryPath: "/fake/path/v1.1.1/agy_acp_server.par")
        XCTAssertEqual(coordinator.installedVersion(for: agentId), "1.1.1")
        XCTAssertFalse(coordinator.hasUpdateAvailable(for: entryV2))

        // Cleanup
        coordinator.uninstallRegistryAgent(id: agentId)
        XCTAssertFalse(coordinator.isAgentInstalled(id: agentId))
    }

    func testCoordinatorPreservesSelectedPresetOnUpdate() {
        let coordinator = AgentSessionCoordinator()
        let agentId = "antigravity-acp"

        let entryV1 = ACPRegistryAgentEntry(
            id: agentId,
            name: "Google Antigravity",
            version: "1.0.0",
            description: "AI Agent",
            distribution: ACPRegistryDistribution(npx: ACPRegistryNpxDistribution(package: "@example/pkg@1.0.0"))
        )

        coordinator.installRegistryAgent(entryV1)
        coordinator.selectedPresetId = agentId
        XCTAssertEqual(coordinator.selectedPresetId, agentId)

        // Reinstalling / updating to v1.1.0 should keep selectedPresetId intact
        let entryV2 = ACPRegistryAgentEntry(
            id: agentId,
            name: "Google Antigravity",
            version: "1.1.0",
            description: "AI Agent",
            distribution: ACPRegistryDistribution(npx: ACPRegistryNpxDistribution(package: "@example/pkg@1.1.0"))
        )
        coordinator.installRegistryAgent(entryV2)
        XCTAssertEqual(coordinator.selectedPresetId, agentId)
        XCTAssertEqual(coordinator.installedVersion(for: agentId), "1.1.0")

        coordinator.uninstallRegistryAgent(id: agentId)
    }

    func testCheckForAgentUpdatesEndToEnd() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let updatedRegistryJSON = """
        {
          "version": "1.0.0",
          "agents": [
            {
              "id": "sample-npx-agent",
              "name": "Sample NPX Agent",
              "version": "1.3.0",
              "description": "An agent running via npx updated",
              "distribution": {
                "npx": {
                  "package": "@example/sample-npx@1.3.0",
                  "args": ["--acp"]
                }
              }
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, updatedRegistryJSON.data(using: .utf8)!)
        }

        let mockRegistryService = ACPRegistryService(
            registryURL: URL(string: "https://example.com/registry.json")!,
            session: session
        )

        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)

        // Initially install old v1.2.3
        let oldEntry = ACPRegistryAgentEntry(
            id: "sample-npx-agent",
            name: "Sample NPX Agent",
            version: "1.2.3",
            description: "Old version",
            distribution: ACPRegistryDistribution(npx: ACPRegistryNpxDistribution(package: "@example/sample-npx@1.2.3"))
        )
        coordinator.installRegistryAgent(oldEntry)
        XCTAssertEqual(coordinator.installedVersion(for: "sample-npx-agent"), "1.2.3")

        // Run check for updates
        let updatedIds = await coordinator.checkForAgentUpdates(registryService: mockRegistryService, forceRefresh: true)
        XCTAssertEqual(updatedIds, ["sample-npx-agent"])
        XCTAssertEqual(coordinator.installedVersion(for: "sample-npx-agent"), "1.3.0")

        coordinator.uninstallRegistryAgent(id: "sample-npx-agent")
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
