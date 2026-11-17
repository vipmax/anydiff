import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class AgentCompactModeTests: XCTestCase {
    func testAgentDisplayPreferencesCompactModePersistence() {
        let defaults = UserDefaults.standard
        let hadPreviousValue = defaults.object(forKey: AgentDisplayPreferences.isCompactModeKey) != nil
        let previousValue = defaults.bool(forKey: AgentDisplayPreferences.isCompactModeKey)
        defer {
            if hadPreviousValue {
                defaults.set(previousValue, forKey: AgentDisplayPreferences.isCompactModeKey)
            } else {
                defaults.removeObject(forKey: AgentDisplayPreferences.isCompactModeKey)
            }
        }

        defaults.removeObject(forKey: AgentDisplayPreferences.isCompactModeKey)
        XCTAssertFalse(AgentDisplayPreferences.isCompactMode)

        defaults.set(true, forKey: AgentDisplayPreferences.isCompactModeKey)
        XCTAssertTrue(AgentDisplayPreferences.isCompactMode)

        defaults.set(false, forKey: AgentDisplayPreferences.isCompactModeKey)
        XCTAssertFalse(AgentDisplayPreferences.isCompactMode)
    }

    @MainActor
    func testToolCardViewHeightInRegularAndCompactMode() {
        let message = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallItem(id: "t1", toolName: "run_command", command: "git status", status: .completed)
            ]
        )
        let cell = AgentMessageCell(message: message, theme: .zedDark, isCompactMode: false)

        let regularCard = AgentToolCardView(
            item: message.toolCalls[0],
            theme: .zedDark,
            index: 0,
            parentCell: cell,
            toolcallColorMode: .full,
            isCompactMode: false
        )
        let compactCard = AgentToolCardView(
            item: message.toolCalls[0],
            theme: .zedDark,
            index: 0,
            parentCell: cell,
            toolcallColorMode: .full,
            isCompactMode: true
        )

        XCTAssertEqual(regularCard.measureHeight(width: 420), 34, accuracy: 0.01)
        XCTAssertEqual(compactCard.measureHeight(width: 420), 24, accuracy: 0.01)
        XCTAssertLessThan(compactCard.layer?.cornerRadius ?? 99, regularCard.layer?.cornerRadius ?? 0)
    }

    @MainActor
    func testToolGroupViewExpandedHeightAndSpacingInCompactMode() {
        let tools = [
            ToolCallItem(id: "t1", toolName: "fs/read_text_file", path: "A.swift", status: .completed),
            ToolCallItem(id: "t2", toolName: "fs/read_text_file", path: "B.swift", status: .completed),
            ToolCallItem(id: "t3", toolName: "run_command", command: "swift test", status: .completed)
        ]
        let message = AgentMessage(role: .assistant, content: "", toolCalls: tools)
        let cell = AgentMessageCell(message: message, theme: .zedDark)

        let regularCards = tools.enumerated().map { idx, item in
            AgentToolCardView(item: item, theme: .zedDark, index: idx, parentCell: cell, isCompactMode: false)
        }
        let regularGroup = AgentToolGroupView(
            groupKey: "g",
            toolViews: regularCards,
            theme: .zedDark,
            isExpanded: false,
            isCompactMode: false
        )
        XCTAssertEqual(regularGroup.measureHeight(width: 420), 22, accuracy: 0.01)

        regularGroup.toggle()
        regularGroup.applyLayout(width: 420, animated: false)
        // 22 header + 6 headerSpacing + (3 * 34) + (2 * 6 itemSpacing) = 142
        XCTAssertEqual(regularGroup.measureHeight(width: 420), 142, accuracy: 0.01)
        XCTAssertEqual(regularCards[1].frame.minY - regularCards[0].frame.maxY, 6, accuracy: 0.01)

        let compactCards = tools.enumerated().map { idx, item in
            AgentToolCardView(item: item, theme: .zedDark, index: idx, parentCell: cell, isCompactMode: true)
        }
        let compactGroup = AgentToolGroupView(
            groupKey: "g",
            toolViews: compactCards,
            theme: .zedDark,
            isExpanded: false,
            isCompactMode: true
        )
        XCTAssertEqual(compactGroup.measureHeight(width: 420), 20, accuracy: 0.01)

        compactGroup.toggle()
        compactGroup.applyLayout(width: 420, animated: false)
        // 20 header + 3 headerSpacing + (3 * 24) + (2 * 2 itemSpacing) = 99
        XCTAssertEqual(compactGroup.measureHeight(width: 420), 99, accuracy: 0.01)
        XCTAssertEqual(compactCards[1].frame.minY - compactCards[0].frame.maxY, 2, accuracy: 0.01)
    }

    @MainActor
    func testAgentMessageCellAndScrollViewLiveToggleToCompactMode() {
        var message = AgentMessage(id: UUID(), role: .assistant)
        message.appendText("Checking repository:")
        message.appendToolCall(ToolCallItem(id: "t1", toolName: "fs/read_text_file", path: "Package.swift", status: .completed))
        message.appendToolCall(ToolCallItem(id: "t2", toolName: "run_command", command: "git status", status: .completed))
        message.appendText("All set.")

        // 1. Direct cell reconfiguration
        let cell = AgentMessageCell(message: message, theme: .zedDark, isCompactMode: false)
        if let groupView = cell.subviews.compactMap({ $0 as? AgentToolGroupView }).first {
            groupView.toggle()
        } else {
            XCTFail("Expected an AgentToolGroupView for consecutive tool calls")
        }
        let regularHeight = cell.layout(for: 440)

        cell.configure(message: message, theme: .zedDark, isCompactMode: true)
        let compactHeight = cell.layout(for: 440)

        let updatedGroup = cell.subviews.compactMap { $0 as? AgentToolGroupView }.first
        XCTAssertEqual(updatedGroup?.isCompactMode, true)
        XCTAssertEqual(updatedGroup?.isExpanded, true)
        XCTAssertLessThan(compactHeight, regularHeight - 25)

        // 2. ScrollView live update from regular to compact mode
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        scrollView.update(messages: [message], theme: .zedDark, isCompactMode: false, animated: false)
        scrollView.layoutSubtreeIfNeeded()
        guard let docView = scrollView.documentView as? AgentChatDocumentView,
              let renderedCell = docView.subviews.compactMap({ $0 as? AgentMessageCell }).first else {
            XCTFail("Expected rendered AgentMessageCell in documentView")
            return
        }
        renderedCell.subviews.compactMap { $0 as? AgentToolGroupView }.first?.toggle()
        let scrollRegularCellHeight = renderedCell.layout(for: 460)

        scrollView.update(messages: [message], theme: .zedDark, isCompactMode: true, animated: false)
        scrollView.layoutSubtreeIfNeeded()
        let scrollCompactCellHeight = renderedCell.bounds.height

        XCTAssertTrue(renderedCell.isCompactMode)
        XCTAssertLessThan(scrollCompactCellHeight, scrollRegularCellHeight - 25)
    }

    @MainActor
    func testEditedFilesCardShowsLiveDuringStreamingWithoutUndoThenRevealsUndoWhenComplete() {
        let summary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
            AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10)
        ])

        var streamingMessage = AgentMessage(
            id: UUID(),
            role: .assistant,
            content: "Applying edits...",
            toolCalls: [
                ToolCallItem(id: "t1", toolName: "edit_file", path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", status: .completed)
            ],
            isStreaming: true
        )

        let liveApplied = AgentPanelView.applyingLiveEditedSummary(
            summary,
            isBusyOrStreaming: true,
            to: [streamingMessage]
        )
        XCTAssertEqual(liveApplied[0].editedFilesSummary, summary)

        // Does not attach when not busy/streaming
        XCTAssertNil(
            AgentPanelView.applyingLiveEditedSummary(summary, isBusyOrStreaming: false, to: [streamingMessage])[0].editedFilesSummary
        )

        let cell = AgentMessageCell(message: liveApplied[0], theme: .zedDark)
        _ = cell.layout(for: 460)
        guard let card = cell.editedFilesCardView as? AgentEditedFilesCardView else {
            XCTFail("Expected AgentEditedFilesCardView while streaming with liveEditedSummary")
            return
        }
        let streamingButtons = card.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(streamingButtons.map { $0.attributedTitle.string }, ["Review"])

        streamingMessage.isStreaming = false
        streamingMessage.editedFilesSummary = summary
        cell.configure(message: streamingMessage, theme: .zedDark)
        _ = cell.layout(for: 460)

        let completedButtons = card.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(Set(completedButtons.map { $0.attributedTitle.string }), Set(["Undo", "Review"]))

        var revertedSummary = summary
        revertedSummary.isReverted = true
        streamingMessage.editedFilesSummary = revertedSummary
        cell.configure(message: streamingMessage, theme: .zedDark)
        _ = cell.layout(for: 460)

        let revertedButtons = card.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        XCTAssertEqual(Set(revertedButtons.map { $0.attributedTitle.string }), Set(["Redo", "Review"]))
    }

    @MainActor
    func testScrollCoordinatorDetectsLiveEditedSummaryWithoutContentCountChange() {
        let coordinator = AgentChatScrollRepresentable.Coordinator()
        var msg = AgentMessage(
            id: UUID(),
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallItem(id: "t1", toolName: "fs/write_text_file", path: "AGENTS.md", status: .completed)
            ],
            isStreaming: true
        )

        XCTAssertTrue(coordinator.needsUpdate(
            messages: [msg],
            theme: .zedDark,
            accentColor: .accentColor,
            agentIcon: "sparkles",
            toolcallColorMode: .full,
            isCompactMode: false,
            trigger: 0
        ))
        XCTAssertFalse(coordinator.needsUpdate(
            messages: [msg],
            theme: .zedDark,
            accentColor: .accentColor,
            agentIcon: "sparkles",
            toolcallColorMode: .full,
            isCompactMode: false,
            trigger: 0
        ))

        // Live summary arrives while content.count and toolCalls.count stay unchanged
        msg.editedFilesSummary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "AGENTS.md", additions: 2, deletions: 0)
        ])
        XCTAssertTrue(coordinator.needsUpdate(
            messages: [msg],
            theme: .zedDark,
            accentColor: .accentColor,
            agentIcon: "sparkles",
            toolcallColorMode: .full,
            isCompactMode: false,
            trigger: 0
        ))
    }
}
