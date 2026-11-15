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

    func testThemeAgentAuraColorsAlwaysProvidesFourColorsAcrossAllThemes() {
        for theme in Theme.allThemes {
            let auraColors = theme.agentAuraColors
            XCTAssertEqual(auraColors.count, 4, "Theme \(theme.id) should provide 4 aura colors")
            for color in auraColors {
                XCTAssertNotNil(color.usingColorSpace(.sRGB))
            }
        }

        // Colorful themes should produce multiple distinct hues rather than repeating one color
        let zedAura = Theme.zedDark.agentAuraColors
        let uniqueComponents = Set(zedAura.map {
            "\(Int(($0.redComponent * 255).rounded()))-\(Int(($0.greenComponent * 255).rounded()))-\(Int(($0.blueComponent * 255).rounded()))"
        })
        XCTAssertEqual(uniqueComponents.count, 4)
    }

    @MainActor
    func testAgentMessageCellUsesAuraInsteadOfDimmingAvatarWhenStreaming() {
        let streamingMsg = AgentMessage(role: .assistant, content: "Working…", isStreaming: true)
        let cell = AgentMessageCell(message: streamingMsg, theme: .tokyoNight)

        XCTAssertTrue(cell.avatarAuraView.isAnimating)
        XCTAssertFalse(cell.avatarAuraView.isHidden)
        XCTAssertNil(cell.roleIconView.layer?.animation(forKey: "agentRolePulse"))
        XCTAssertEqual(cell.roleIconView.layer?.opacity ?? 0, 1.0, accuracy: 0.001)

        // Layout places aura concentrically around roleIconView
        _ = cell.layout(for: 400)
        XCTAssertEqual(cell.avatarAuraView.frame.midX, cell.roleIconView.frame.midX, accuracy: 0.5)
        XCTAssertEqual(cell.avatarAuraView.frame.midY, cell.roleIconView.frame.midY, accuracy: 0.5)
        XCTAssertGreaterThan(cell.avatarAuraView.frame.width, cell.roleIconView.frame.width)

        // Finishing streaming stops the aura animation
        let finishedMsg = AgentMessage(id: streamingMsg.id, role: .assistant, content: "Done.", isStreaming: false)
        cell.configure(message: finishedMsg, theme: .tokyoNight)
        XCTAssertFalse(cell.avatarAuraView.isAnimating)
        XCTAssertEqual(cell.roleIconView.layer?.opacity ?? 0, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testAvatarCenteredOnFirstLineForSingleAndMultiLineMessages() {
        func firstLineMidY(in textView: NSTextView, relativeTo cell: NSView) -> CGFloat {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else {
                XCTFail("Missing TextKit layout state")
                return 0
            }
            lm.ensureLayout(for: tc)
            var glyphRange = NSRange(location: 0, length: 0)
            var used = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &glyphRange)
            let hasTrailingLine = NSMaxRange(glyphRange) < lm.numberOfGlyphs || lm.extraLineFragmentTextContainer != nil
            if hasTrailingLine, let ts = textView.textStorage, ts.length > 0 {
                let charIdx = min(lm.characterIndexForGlyph(at: 0), ts.length - 1)
                if let ps = ts.attribute(.paragraphStyle, at: charIdx, effectiveRange: nil) as? NSParagraphStyle,
                   ps.lineSpacing > 0 {
                    used.size.height = max(1, used.size.height - ps.lineSpacing)
                }
            }
            let localRect = NSRect(
                x: used.origin.x + textView.textContainerInset.width,
                y: used.origin.y + textView.textContainerInset.height,
                width: used.width,
                height: used.height
            )
            return textView.convert(localRect, to: cell).midY
        }

        // 1. User single-line
        let userSingle = AgentMessage(role: .user, content: "бро")
        let userSingleCell = AgentMessageCell(message: userSingle, theme: .zedDark)
        _ = userSingleCell.layout(for: 500)
        guard let userSingleTV = userSingleCell.userContentViews.first as? AgentSelectableTextView else {
            XCTFail("Expected user text view")
            return
        }
        XCTAssertEqual(
            userSingleCell.roleIconView.frame.midY,
            firstLineMidY(in: userSingleTV, relativeTo: userSingleCell),
            accuracy: 0.5,
            "User avatar must be vertically centered on the first line"
        )

        // 2. User multi-line: avatar and first line stay locked while extra lines grow downward
        let userMulti = AgentMessage(role: .user, content: "бро\nбро\nбро\nбро")
        let userMultiCell = AgentMessageCell(message: userMulti, theme: .zedDark)
        let userMultiHeight = userMultiCell.layout(for: 500)
        guard let userMultiTV = userMultiCell.userContentViews.first as? AgentSelectableTextView else {
            XCTFail("Expected multi-line user text view")
            return
        }
        XCTAssertEqual(
            userMultiCell.roleIconView.frame.midY,
            firstLineMidY(in: userMultiTV, relativeTo: userMultiCell),
            accuracy: 0.5,
            "Multi-line user avatar must stay centered on the first line"
        )
        XCTAssertEqual(
            userMultiCell.roleIconView.frame.origin.y,
            userSingleCell.roleIconView.frame.origin.y,
            accuracy: 0.5
        )
        XCTAssertEqual(
            userMultiTV.convert(userMultiTV.bounds, to: userMultiCell).origin.y,
            userSingleTV.convert(userSingleTV.bounds, to: userSingleCell).origin.y,
            accuracy: 0.5,
            "Multi-line user text first line must not shift relative to single-line text"
        )
        XCTAssertGreaterThan(userMultiHeight, userSingleCell.frame.height)

        // 3. Assistant single-line
        let assistantSingle = AgentMessage(role: .assistant, content: "Привет! Чем могу помочь?")
        let assistantSingleCell = AgentMessageCell(message: assistantSingle, theme: .zedDark)
        _ = assistantSingleCell.layout(for: 500)
        guard let assistantSingleTV = assistantSingleCell.orderedAssistantViews.first as? AgentSelectableTextView else {
            XCTFail("Expected assistant text view")
            return
        }
        XCTAssertEqual(
            assistantSingleCell.roleIconView.frame.midY,
            firstLineMidY(in: assistantSingleTV, relativeTo: assistantSingleCell),
            accuracy: 0.5,
            "Assistant avatar must be vertically centered on the first line"
        )

        // 4. Assistant multi-line (with soft line breaks inside one paragraph)
        let assistantMulti = AgentMessage(role: .assistant, content: "Строка 1\nСтрока 2\nСтрока 3")
        let assistantMultiCell = AgentMessageCell(message: assistantMulti, theme: .zedDark)
        _ = assistantMultiCell.layout(for: 500)
        guard let assistantMultiTV = assistantMultiCell.orderedAssistantViews.first as? AgentSelectableTextView else {
            XCTFail("Expected multi-line assistant text view")
            return
        }
        XCTAssertEqual(
            assistantMultiCell.roleIconView.frame.midY,
            firstLineMidY(in: assistantMultiTV, relativeTo: assistantMultiCell),
            accuracy: 0.5,
            "Multi-line assistant avatar must stay centered on the first line"
        )
        XCTAssertEqual(
            assistantMultiCell.roleIconView.frame.origin.y,
            assistantSingleCell.roleIconView.frame.origin.y,
            accuracy: 0.5
        )
        XCTAssertEqual(
            assistantMultiTV.frame.origin.y,
            assistantSingleTV.frame.origin.y,
            accuracy: 0.5,
            "Multi-line assistant text first line must not shift relative to single-line text"
        )
    }

    @MainActor
    func testSentMessageLayoutMatchesEmptyComposerAndWelcomePositions() {
        let userText = "кукукукукукукукукукукукук\nкукукукукукукукук"
        let userMsg = AgentMessage(role: .user, content: userText)
        let assistantWaitingMsg = AgentMessage(role: .assistant, content: "", isStreaming: true)

        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scrollView.update(messages: [userMsg, assistantWaitingMsg], theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        guard let docView = scrollView.documentView as? AgentChatDocumentView else {
            XCTFail("Expected AgentChatDocumentView")
            return
        }
        let cells = docView.subviews.compactMap { $0 as? AgentMessageCell }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(cells.count, 2)
        let userCell = cells[0]
        let assistantCell = cells[1]

        // Empty-state composer geometry:
        // AgentPanelView top padding (10) + AgentInputView top padding (2) = 12pt user avatar top
        let userAvatarSize = AgentMessageCell.userAvatarSize
        let firstLineH = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13, weight: .regular)))
        let inputAvatarOffset = max(0, firstLineH / 2 - userAvatarSize / 2)
        let inputContentOffset = max(0, userAvatarSize / 2 - firstLineH / 2)
        let expectedUserAvatarTop = 10 + 2 + inputAvatarOffset
        let expectedUserTextTop = 10 + 2 + inputContentOffset

        let actualUserAvatarTop = userCell.convert(userCell.roleIconView.frame, to: docView).minY
        XCTAssertEqual(actualUserAvatarTop, expectedUserAvatarTop, accuracy: 0.5)

        guard let userTV = userCell.userContentViews.first as? AgentSelectableTextView else {
            XCTFail("Expected user text view")
            return
        }
        let actualUserTextTop = userTV.convert(userTV.bounds, to: docView).minY
        XCTAssertEqual(actualUserTextTop, expectedUserTextTop, accuracy: 0.5)

        // Empty-state welcome geometry below input:
        // input height = 2 + max(avatarOffset + userAvatarSize, contentOffset + textHeight) + 6
        // welcomeStateView top padding = 16 -> agent avatar top = 10 + inputHeight + 16
        let textHeight = ceil(userTV.layoutManager!.usedRect(for: userTV.textContainer!).height)
        let expectedInputHeight = 2 + max(inputAvatarOffset + userAvatarSize, inputContentOffset + max(18, textHeight)) + 6
        let expectedAgentAvatarTop = 10 + expectedInputHeight + 16
        let actualAgentAvatarTop = assistantCell.convert(assistantCell.roleIconView.frame, to: docView).minY
        XCTAssertEqual(actualAgentAvatarTop, expectedAgentAvatarTop, accuracy: 0.5)
    }
}
