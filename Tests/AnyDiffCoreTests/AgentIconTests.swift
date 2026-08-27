import XCTest
import AppKit
@testable import AnyDiffCore
@testable import AnyDiffUI

final class AgentIconTests: XCTestCase {
    func testDefaultPresetsHaveProperIconNames() {
        XCTAssertEqual(AgentPreset.codex.iconName, "openai")
        XCTAssertEqual(AgentPreset.agy.iconName, "googlegemini")
        XCTAssertEqual(AgentPreset.claude.iconName, "claude")
    }

    func testCustomPresetIconNamePreservation() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)
        let preset = coordinator.addCustomPreset(
            name: "My Ollama",
            command: "ollama run llama3",
            iconName: "ollama"
        )
        XCTAssertEqual(preset.iconName, "ollama")
        XCTAssertEqual(preset.name, "My Ollama")
    }

    func testAgentIconLoaderLoadsOpenAISVGFallback() {
        let exp = expectation(description: "Loads OpenAI icon")
        AgentIconLoader.shared.load("openai") { image in
            XCTAssertNotNil(image)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testAgentIconLoaderLoadsSimpleIconsAsync() {
        let exp = expectation(description: "Loads SVG from simple-icons")
        AgentIconLoader.shared.load("claude") { image in
            XCTAssertNotNil(image)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    func testAgentIconLoaderCachesInMemory() {
        let exp = expectation(description: "Second call returns cached NSImage immediately")
        AgentIconLoader.shared.load("claude") { image1 in
            XCTAssertNotNil(image1)
            AgentIconLoader.shared.load("claude") { image2 in
                XCTAssertNotNil(image2)
                XCTAssertEqual(image1, image2)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5.0)
    }

    func testCustomPresetPersistsAcrossCoordinatorReloads() {
        let coordinator1 = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)
        let preset = coordinator1.addCustomPreset(
            name: "Persistent Agent",
            command: "npx -y custom-agent",
            arguments: "--verbose",
            colorName: "purple",
            iconName: "deepseek"
        )
        XCTAssertTrue(coordinator1.customPresets.contains(where: { $0.name == "Persistent Agent" }))

        // Simulate app restart by initializing a brand new coordinator
        let coordinator2 = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)
        let loaded = coordinator2.customPresets.first(where: { $0.id == preset.id })
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Persistent Agent")
        XCTAssertEqual(loaded?.command, "npx -y custom-agent")
        XCTAssertEqual(loaded?.arguments, "--verbose")
        XCTAssertEqual(loaded?.colorName, "purple")
        XCTAssertEqual(loaded?.iconName, "deepseek")

        // Cleanup
        coordinator2.deleteCustomPreset(id: preset.id)
        let coordinator3 = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: false)
        XCTAssertFalse(coordinator3.customPresets.contains(where: { $0.id == preset.id }))
    }
}
