import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class AgentAvatarTests: XCTestCase {

    func testAvatarSettingsDefaultInitialization() {
        let settings = AvatarSettings()
        XCTAssertFalse(settings.useCustom)
        XCTAssertEqual(settings.zoom, 1.0)
        XCTAssertEqual(settings.userAvatarSize, 24)
        XCTAssertFalse(settings.useCustomAgent)
        XCTAssertEqual(settings.agentAvatarSize, 24)
        XCTAssertTrue(settings.agentConfigs.isEmpty)
    }

    func testAvatarSettingsIsolationBetweenAgentsAndProfiles() {
        var settings = AvatarSettings(
            agentAvatarSize: 28,
            showAgentCircle: true
        )

        // 1. Without specific config, an agent has useCustom == false so it never leaks from another
        let unconfigured = settings.config(for: "gemini")
        XCTAssertFalse(unconfigured.useCustom)
        XCTAssertEqual(unconfigured.zoom, 1.0)
        XCTAssertEqual(unconfigured.avatarSize, 28)
        XCTAssertTrue(unconfigured.showCircle)

        // 2. Set specific config for agent "claude"
        settings.agentConfigs["claude"] = AgentAvatarItemConfig(
            useCustom: true,
            zoom: 2.0,
            offsetX: 10,
            offsetY: -5,
            avatarSize: 32,
            showCircle: false
        )

        let claudeConfig = settings.config(for: "claude")
        XCTAssertTrue(claudeConfig.useCustom)
        XCTAssertEqual(claudeConfig.zoom, 2.0)
        XCTAssertEqual(claudeConfig.offsetX, 10)
        XCTAssertEqual(claudeConfig.offsetY, -5)
        XCTAssertEqual(claudeConfig.avatarSize, 32)
        XCTAssertFalse(claudeConfig.showCircle)

        // 3. Different profile "claude-work" remains unconfigured and isolated
        let claudeWorkConfig = settings.config(for: "claude-work")
        XCTAssertFalse(claudeWorkConfig.useCustom, "Profiles must be strictly isolated and not inherit custom state")
        XCTAssertEqual(claudeWorkConfig.avatarSize, 28)

        // 4. Set specific profile for "claude-work"
        settings.agentConfigs["claude-work"] = AgentAvatarItemConfig(
            useCustom: true,
            zoom: 1.2,
            offsetX: 0,
            offsetY: 0,
            avatarSize: 20,
            showCircle: true
        )

        let specificWorkConfig = settings.config(for: "claude-work")
        XCTAssertTrue(specificWorkConfig.useCustom)
        XCTAssertEqual(specificWorkConfig.avatarSize, 20)
        XCTAssertEqual(specificWorkConfig.zoom, 1.2)
        XCTAssertTrue(specificWorkConfig.showCircle)
    }

    func testAvatarSettingsBackwardCompatibilityDecoding() throws {
        let legacyJson = """
        {
            "useCustom": true,
            "zoom": 1.4,
            "offsetX": 5.0,
            "offsetY": -3.0,
            "userAvatarSize": 26.0,
            "useCustomAgent": true,
            "agentZoom": 1.8,
            "agentOffsetX": 0.0,
            "agentOffsetY": 0.0,
            "agentAvatarSize": 30.0,
            "showAgentCircle": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AvatarSettings.self, from: legacyJson)
        XCTAssertTrue(decoded.useCustom)
        XCTAssertEqual(decoded.zoom, 1.4)
        XCTAssertEqual(decoded.userAvatarSize, 26)
        XCTAssertTrue(decoded.useCustomAgent)
        XCTAssertEqual(decoded.agentAvatarSize, 30)
        XCTAssertTrue(decoded.agentConfigs.isEmpty)

        // Unconfigured agent has isolated default
        let config = decoded.config(for: "antigravity-acp-djvipmax")
        XCTAssertFalse(config.useCustom)
        XCTAssertEqual(config.avatarSize, 30)
    }

    func testSanitizedFileKey() {
        XCTAssertEqual(AgentAvatarProvider.sanitizedFileKey("claude"), "claude")
        XCTAssertEqual(AgentAvatarProvider.sanitizedFileKey("antigravity-acp-djvipmax"), "antigravity-acp-djvipmax")
        XCTAssertEqual(AgentAvatarProvider.sanitizedFileKey("Custom Agent (Work)!"), "custom-agent--work")
        XCTAssertEqual(AgentAvatarProvider.sanitizedFileKey(""), "default")
    }

    func testAgentFileURLGeneration() {
        let defaultOriginal = AgentAvatarProvider.agentOriginalImageURL(for: nil)
        XCTAssertTrue(defaultOriginal.lastPathComponent.hasPrefix("agent_avatar_original"))

        let specificOriginal = AgentAvatarProvider.agentOriginalImageURL(for: "claude-work")
        XCTAssertEqual(specificOriginal.lastPathComponent, "agent_avatar_original_claude-work.png")

        let specificRendered = AgentAvatarProvider.agentRenderedAvatarURL(for: "antigravity-acp-djvipmax")
        XCTAssertEqual(specificRendered.lastPathComponent, "agent_avatar_antigravity-acp-djvipmax.png")
    }

    func testDiscoveredAgentProfilesIncludesSelectedId() {
        let options = AgentAvatarProvider.discoveredAgentProfiles(selectedId: "unique-agent-profile-99")
        XCTAssertTrue(options.contains(where: { $0.id == "unique-agent-profile-99" }))
        XCTAssertTrue(options.contains(where: { $0.id == "claude" }))
        XCTAssertTrue(options.contains(where: { $0.id == "antigravity-acp" }))
    }
}
