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
}
