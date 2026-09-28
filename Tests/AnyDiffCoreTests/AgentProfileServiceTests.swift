import XCTest
@testable import AnyDiffCore

final class AgentProfileServiceTests: XCTestCase {

    func testBaseProfilesDirectory() {
        let dir = AgentProfileService.baseProfilesDirectory
        XCTAssertTrue(dir.path.hasSuffix("/.anydiff/profiles"))
    }

    func testSanitizeSlug() {
        XCTAssertEqual(AgentProfileService.sanitizeSlug("Work"), "work")
        XCTAssertEqual(AgentProfileService.sanitizeSlug("Personal Account!"), "personal-account")
        XCTAssertEqual(AgentProfileService.sanitizeSlug("dj_vip-max"), "dj-vip-max")
        XCTAssertEqual(AgentProfileService.sanitizeSlug("   "), "profile")
    }

    func testRootAgentId() {
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "agy"), "agy")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "agy-work", profile: "work"), "agy")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "antigravity-personal"), "antigravity")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "gemini-research"), "gemini")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "claude-code-acp-work"), "claude-code-acp")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "codex-test"), "codex")
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "my-custom-agent-profile"), "my-custom-agent")

        // Custom agents created with UUIDs should not be chopped at hyphens
        let customUUID = "64088147-B097-4C0E-9A03-EF6EDBF20B69"
        XCTAssertEqual(AgentProfileService.rootAgentId(for: customUUID), customUUID)
        XCTAssertEqual(AgentProfileService.rootAgentId(for: "\(customUUID)-work", profile: "work"), customUUID)
    }

    func testProfileEnvironmentAntigravity() {
        let env = AgentProfileService.profileEnvironment(for: "agy", profileId: "agy-work")
        XCTAssertEqual(env["GEMINI_HOME"], "~/.anydiff/profiles/agy-work")
        XCTAssertEqual(env["AGY_ACP_FORCE_FILE_STORAGE"], "1")
    }

    func testProfileEnvironmentClaude() {
        let env = AgentProfileService.profileEnvironment(for: "claude", profileId: "claude-personal")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "~/.anydiff/profiles/claude-personal")
    }

    func testProfileEnvironmentCodex() {
        let env = AgentProfileService.profileEnvironment(for: "codex", profileId: "codex-dev")
        XCTAssertEqual(env["CODEX_HOME"], "~/.anydiff/profiles/codex-dev")
    }

    func testProfileEnvironmentGenericFallback() {
        let env = AgentProfileService.profileEnvironment(for: "unregistered-tool", profileId: "unregistered-tool-demo")
        XCTAssertEqual(env["ANYDIFF_PROFILE_DIR"], "~/.anydiff/profiles/unregistered-tool-demo")
    }

    func testResolveEnvironmentExpandsHomeAndCreatesDirectory() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_test_\(UUID().uuidString)")
        let testDir = tempBase.appendingPathComponent("custom_dir").path

        let rawEnv = [
            "REGULAR_VAR": "simple_value",
            "TEST_HOME": testDir
        ]

        let resolved = AgentProfileService.resolveEnvironment(rawEnv)
        XCTAssertEqual(resolved["REGULAR_VAR"], "simple_value")
        XCTAssertEqual(resolved["TEST_HOME"], testDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir))

        try? FileManager.default.removeItem(at: tempBase)
    }

    func testParseDisplayName() {
        let parsedWithProfile = AgentProfileService.parseDisplayName("Antigravity (Work)")
        XCTAssertEqual(parsedWithProfile.baseName, "Antigravity")
        XCTAssertEqual(parsedWithProfile.profileName, "Work")

        let parsedWithoutProfile = AgentProfileService.parseDisplayName("Claude Code")
        XCTAssertEqual(parsedWithoutProfile.baseName, "Claude Code")
        XCTAssertNil(parsedWithoutProfile.profileName)

        let parsedEmptyParens = AgentProfileService.parseDisplayName("Agent ()")
        XCTAssertEqual(parsedEmptyParens.baseName, "Agent ()")
        XCTAssertNil(parsedEmptyParens.profileName)
    }

    func testPresetDuplicatingWithProfile() {
        let base = AgentPreset.agy
        let duplicated = base.duplicating(withProfile: "Work")

        XCTAssertEqual(duplicated.id, "agy-work")
        XCTAssertEqual(duplicated.name, "Antigravity")
        XCTAssertEqual(duplicated.profile, "Work")
        XCTAssertEqual(duplicated.displayName, "Antigravity (Work)")
        XCTAssertEqual(duplicated.profileDisplayName, "Work")
        XCTAssertEqual(duplicated.environment?["GEMINI_HOME"], "~/.anydiff/profiles/agy-work")
        XCTAssertEqual(duplicated.environment?["AGY_ACP_FORCE_FILE_STORAGE"], "1")
        XCTAssertTrue(duplicated.isCustom)
        XCTAssertEqual(duplicated.summary, base.summary)
    }

    func testPresetCodablePreservesProfileAndEnvironment() throws {
        let preset = AgentPreset(
            id: "agy-personal",
            name: "Antigravity",
            command: "agy --acp",
            profile: "Personal",
            environment: ["GEMINI_HOME": "~/.anydiff/profiles/agy-personal"]
        )

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(AgentPreset.self, from: data)

        XCTAssertEqual(decoded.id, "agy-personal")
        XCTAssertEqual(decoded.profile, "Personal")
        XCTAssertEqual(decoded.environment?["GEMINI_HOME"], "~/.anydiff/profiles/agy-personal")
        XCTAssertEqual(decoded.displayName, "Antigravity (Personal)")
    }

    func testCoordinatorDuplicatePreset() {
        let suiteName = "AgentProfileServiceTests_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AgentSessionCoordinator(userDefaults: testDefaults)
        let duplicated = coordinator.duplicatePreset(.agy, profileName: "Work")

        XCTAssertEqual(duplicated.id, "agy-work")
        XCTAssertEqual(duplicated.profile, "Work")
        XCTAssertTrue(coordinator.customPresets.contains(where: { $0.id == "agy-work" }))

        // Verify persistence
        let reloaded = AgentSessionCoordinator(userDefaults: testDefaults)
        XCTAssertTrue(reloaded.customPresets.contains(where: { $0.id == "agy-work" }))
    }

    func testAgentGroupsConsolidationAndProfileSelection() {
        let suiteName = "AgentGroupsTests_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AgentSessionCoordinator(userDefaults: testDefaults)

        // Duplicate multiple profiles for Antigravity (e.g. 10 accounts)
        _ = coordinator.duplicatePreset(.agy, profileName: "djvipmax")
        _ = coordinator.duplicatePreset(.agy, profileName: "Work")
        _ = coordinator.duplicatePreset(.agy, profileName: "ClientA")

        // Still EXACTLY 1 card/group for Antigravity!
        let groupsAfter = coordinator.agentGroups.filter { $0.id == "agy" }
        XCTAssertEqual(groupsAfter.count, 1)

        guard let agyGroup = groupsAfter.first else {
            XCTFail("Missing agy group")
            return
        }

        // 4 profiles in the single group
        XCTAssertEqual(agyGroup.profiles.count, 4)
        XCTAssertEqual(agyGroup.selectedPreset.profile, "ClientA")

        // Switch profile to Work
        if let workPreset = agyGroup.profiles.first(where: { $0.profile == "Work" }) {
            coordinator.selectProfile(preset: workPreset, forBaseId: agyGroup.id)
            let updatedGroup = coordinator.agentGroups.first(where: { $0.id == "agy" })
            XCTAssertEqual(updatedGroup?.selectedPreset.profile, "Work")
        }

        // Delete profile
        if let clientPreset = agyGroup.profiles.first(where: { $0.profile == "ClientA" }) {
            coordinator.deleteProfile(clientPreset)
            let remainingGroup = coordinator.agentGroups.first(where: { $0.id == "agy" })
            XCTAssertEqual(remainingGroup?.profiles.count, 3)
            XCTAssertFalse(remainingGroup?.profiles.contains(where: { $0.profile == "ClientA" }) ?? true)
        }
    }

    func testUninstallRegistryAgentCascadesProfilesAndPersists() {
        let suiteName = "AgentUninstallTests_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let coordinator = AgentSessionCoordinator(userDefaults: testDefaults)

        // Add custom agent
        let custom = coordinator.addCustomPreset(name: "TestTool", command: "testtool --acp")
        _ = coordinator.duplicatePreset(custom, profileName: "TeamA")
        _ = coordinator.duplicatePreset(custom, profileName: "TeamB")

        XCTAssertTrue(coordinator.customPresets.contains(where: { $0.id == custom.id }))
        XCTAssertEqual(coordinator.customPresets.filter { $0.effectiveBaseId == custom.id }.count, 3)

        // Uninstall the base agent
        coordinator.uninstallRegistryAgent(id: custom.id)

        // Base and all child profiles should be removed
        XCTAssertFalse(coordinator.customPresets.contains(where: { $0.id == custom.id }))
        XCTAssertEqual(coordinator.customPresets.filter { $0.effectiveBaseId == custom.id }.count, 0)

        // Verify persistence across coordinator instances
        let reloaded = AgentSessionCoordinator(userDefaults: testDefaults)
        XCTAssertFalse(reloaded.customPresets.contains(where: { $0.id == custom.id }))
        XCTAssertEqual(reloaded.customPresets.filter { $0.effectiveBaseId == custom.id }.count, 0)
    }
}
