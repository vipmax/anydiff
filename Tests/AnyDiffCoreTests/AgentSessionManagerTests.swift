import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class AgentSessionManagerTests: XCTestCase {
    func testAgentMessageDataStructures() {
        let tool = ToolCallItem(toolName: "fs/write_text_file", path: "main.swift", summary: "Wrote 24 bytes", status: .completed)
        XCTAssertEqual(tool.toolName, "fs/write_text_file")
        XCTAssertEqual(tool.status, .completed)

        let msg = AgentMessage(role: .assistant, content: "Done editing", thought: "Refactored main.swift", toolCalls: [tool])
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Done editing")
        XCTAssertEqual(msg.thought, "Refactored main.swift")
        XCTAssertEqual(msg.toolCalls.count, 1)
    }

    func testToolDisplayTitleCompactsStreamedOutput() {
        let tool = ToolCallItem(
            toolName: "tool",
            summary: "first output line\n" + String(repeating: "x", count: 2_000)
        )

        XCTAssertEqual(tool.displayTitle, "first output line")
        XCTAssertLessThanOrEqual(tool.displayTitle.count, 160)
    }

    func testAgentMessageKeepsArrivalOrderWhenToolDetailsUpdate() {
        let tool = ToolCallItem(id: "tool-1", toolName: "run_command")
        var message = AgentMessage(id: UUID(), role: .assistant)

        message.appendText("before")
        message.appendToolCall(tool)
        message.appendText("after")

        XCTAssertEqual(message.orderedParts, [
            .text("before"),
            .toolCall("tool-1"),
            .text("after")
        ])

        _ = message.updateToolCall(id: "tool-1") { item in
            item.status = .completed
            item.output = "done"
        }

        XCTAssertEqual(message.orderedParts, [
            .text("before"),
            .toolCall("tool-1"),
            .text("after")
        ])
        XCTAssertEqual(message.toolCalls.first?.status, .completed)
        XCTAssertEqual(message.toolCalls.first?.output, "done")
    }

    func testAgentMessageKeepsThoughtsInArrivalOrder() {
        var message = AgentMessage(id: UUID(), role: .assistant)

        message.appendThought("plan")
        message.appendToolCall(ToolCallItem(id: "tool-1", toolName: "run_command"))
        message.appendText("result")
        message.appendThought("follow-up")

        XCTAssertEqual(message.orderedParts, [
            .thought("plan"),
            .toolCall("tool-1"),
            .text("result"),
            .thought("follow-up")
        ])
        XCTAssertEqual(message.thought, "planfollow-up")
    }

    func testManagerInitialStateAndClearSession() {
        let manager = ACPAgentSessionManager()
        XCTAssertEqual(manager.status, .disconnected)
        XCTAssertEqual(manager.initializationState, .notStarted)
        XCTAssertTrue(manager.messages.isEmpty)
        XCTAssertTrue(manager.isPanelOpen)

        manager.togglePanel()
        XCTAssertFalse(manager.isPanelOpen)

        manager.clearSession()
        XCTAssertTrue(manager.messages.isEmpty)
    }

    #if DEBUG
    func testMockAgentSessionManager() {
        let mockManager = MockAgentSessionManager()
        XCTAssertEqual(mockManager.status, .idle)
        XCTAssertEqual(mockManager.initializationState, .ready)
        XCTAssertEqual(mockManager.messages.count, 14)
        XCTAssertEqual(mockManager.messages[0].role, .user)
        XCTAssertEqual(mockManager.messages[1].role, .assistant)
        XCTAssertEqual(mockManager.messages[12].images.count, 2)
        XCTAssertEqual(mockManager.contextUsagePercentage, 72)
        XCTAssertGreaterThan(mockManager.messages[11].content.count, 10_000)
        XCTAssertEqual(mockManager.messages[11].toolCalls.count, 6)
        XCTAssertGreaterThan(mockManager.messages[11].toolCalls[2].output?.count ?? 0, 10_000)
        XCTAssertEqual(
            mockManager.messages[11].toolCalls[3].oldContent?.split(separator: "\n", omittingEmptySubsequences: false).count,
            100
        )
        XCTAssertEqual(
            mockManager.messages[11].toolCalls[3].newContent?.split(separator: "\n", omittingEmptySubsequences: false).count,
            100
        )

        mockManager.clearSession()
        XCTAssertEqual(mockManager.messages.count, 14)
    }

    func testHeavyMockMessageKeepsRichTextLayersBounded() {
        let mockManager = MockAgentSessionManager()
        let message = mockManager.messages[11]
        let cell = AgentMessageCell(message: message, theme: .zedDark)

        _ = cell.layout(for: 420)

        let markdownTextViews = cell.allSelectableTextViews().filter {
            $0.tvKey.hasPrefix("md_")
        }
        XCTAssertGreaterThan(markdownTextViews.count, 2)
        XCTAssertLessThanOrEqual(
            markdownTextViews.map(\.frame.height).max() ?? .greatestFiniteMagnitude,
            500,
            "A tall layer causes a visible rasterization spike when it enters the scroll viewport"
        )
        XCTAssertTrue(
            cell.subviews.contains { $0 is AgentCodeBlockView } == false,
            "Code blocks are temporarily disabled in the native agent chat"
        )
    }

    func testToolCallsUseExpandableColoredCardsWhenSimpleModeIsDisabled() {
        var singleToolOnly = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                ToolCallItem(
                    id: "t1",
                    toolName: "run_command",
                    command: "git status -s && git diff",
                    status: .completed
                )
            ]
        )
        let singleCell = AgentMessageCell(message: singleToolOnly, theme: .zedDark)
        _ = singleCell.layout(for: 420)
        XCTAssertEqual(
            singleCell.subviews.compactMap { $0 as? AgentToolCardView }.count,
            1,
            "A single tool call without thought should be rendered directly as an AgentToolCardView without grouping"
        )
        XCTAssertFalse(singleCell.subviews.contains { $0 is AgentToolGroupView })

        // When a second tool call arrives via streaming, the first card must be detached from cell.subviews
        // so it does not overlap with the collapsed AgentToolGroupView header!
        singleToolOnly.appendToolCall(
            ToolCallItem(
                id: "t2",
                toolName: "run_command",
                command: "git log -1",
                status: .running
            )
        )
        singleCell.configure(message: singleToolOnly, theme: .zedDark)
        _ = singleCell.layout(for: 420)
        XCTAssertTrue(
            singleCell.subviews.compactMap { $0 as? AgentToolCardView }.isEmpty,
            "Once grouped into a collapsed AgentToolGroupView, individual tool cards must not remain in cell.subviews"
        )
        XCTAssertEqual(singleCell.subviews.compactMap { $0 as? AgentToolGroupView }.count, 1)

        let multiToolMessage = MockAgentSessionManager().messages[11]
        let multiCell = AgentMessageCell(message: multiToolMessage, theme: .zedDark)
        _ = multiCell.layout(for: 420)

        let groupViews = multiCell.subviews.compactMap { $0 as? AgentToolGroupView }
        XCTAssertEqual(groupViews.count, 1, "Consecutive thoughts and tool calls (>= 2) should be grouped into AgentToolGroupView")
        guard let groupView = groupViews.first else { return }
        XCTAssertFalse(groupView.isExpanded, "Tool group should be collapsed by default")
        XCTAssertEqual(groupView.toolViews.count, multiToolMessage.toolCalls.count + 1)
        let headerTitle = groupView.headerButton.attributedTitle.string
        XCTAssertTrue(headerTitle.contains("worked (1 thought,"), "Unexpected header title: \(headerTitle)")
        XCTAssertTrue(headerTitle.contains("edits"), "Unexpected header title: \(headerTitle)")
        XCTAssertTrue(headerTitle.contains("shell"), "Unexpected header title: \(headerTitle)")
        XCTAssertTrue(groupView.subviews.compactMap { $0 as? AgentToolCardView }.isEmpty, "Collapsed group should not mount child tool cards")

        // Expanding the group mounts the AgentThoughtBlockView and AgentToolCardView items
        groupView.toggle()
        _ = multiCell.layout(for: 420)
        XCTAssertTrue(groupView.isExpanded)
        XCTAssertEqual(
            groupView.subviews.compactMap { $0 as? AgentToolCardView }.count,
            multiToolMessage.toolCalls.count
        )
        XCTAssertEqual(
            groupView.subviews.compactMap { $0 as? AgentThoughtBlockView }.count,
            1
        )
    }

    func testAssistantAvatarPulsesThroughoutStreamingWithoutTypingDots() {
        var streaming = AgentMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        )
        let cell = AgentMessageCell(message: streaming, theme: .zedDark)
        _ = cell.layout(for: 420)

        XCTAssertTrue(cell.typingIndicatorView.isHidden, "Moving '...' typing indicator dots must remain hidden")
        XCTAssertNil(
            cell.roleIconView.layer?.animation(forKey: "agentRolePulse"),
            "Avatar itself must not dim/pulse while waiting for response"
        )
        XCTAssertTrue(cell.avatarAuraView.isAnimating, "Aura should animate while waiting for response")
        XCTAssertFalse(cell.avatarAuraView.isHidden, "Aura should be visible while waiting for response")

        // Even after thought, tool call, and text arrive, the aura must keep animating while isStreaming == true
        streaming.appendThought("Inspecting codebase")
        streaming.appendToolCall(ToolCallItem(id: "t1", toolName: "run_command", command: "git status", status: .running))
        streaming.appendText("Working on it...")
        cell.configure(message: streaming, theme: .zedDark)
        _ = cell.layout(for: 420)

        XCTAssertTrue(cell.typingIndicatorView.isHidden)
        XCTAssertNil(cell.roleIconView.layer?.animation(forKey: "agentRolePulse"))
        XCTAssertTrue(cell.avatarAuraView.isAnimating, "Aura should keep animating for the entire streaming turn")

        // Once streaming finishes, the aura animation stops
        streaming.isStreaming = false
        cell.configure(message: streaming, theme: .zedDark)
        XCTAssertFalse(cell.avatarAuraView.isAnimating, "Aura should stop once streaming finishes")
    }

    func testStandardChatScrollViewUsesNativeDocumentView() {
        let manager = MockAgentSessionManager()
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scrollView.update(messages: manager.messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertTrue(scrollView.documentView is AgentChatDocumentView)
        XCTAssertGreaterThan(scrollView.documentView?.bounds.height ?? 0, 0)
    }

    func testShortChatDoesNotScrollUpWhenScrollViewHeightShrinks() {
        let messages = [
            AgentMessage(role: .user, content: "здрасте"),
            AgentMessage(role: .assistant, content: "Здравствуйте! Чем могу помочь вам сегодня?")
        ]
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)

        // When the input view expands (e.g. image attached + multiple newlines entered),
        // the chat scroll view frame shrinks in height (e.g. from 600 to 400).
        scrollView.setFrameSize(NSSize(width: 400, height: 400))
        scrollView.scrollToBottom(animated: false)

        // Content height is smaller than viewport height (400), so origin.y MUST remain 0
        // and messages must NOT scroll up out of view.
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
    }

    func testLongChatFollowsBottomWhenScrollViewHeightShrinks() {
        let messages = (1...20).map { idx in
            AgentMessage(role: .user, content: "Message line \(idx) details")
        }
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        let initialDocHeight = scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(initialDocHeight, 600)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, initialDocHeight - 600)

        // Shrink scroll view height
        scrollView.setFrameSize(NSSize(width: 400, height: 400))

        // When following bottom, new scroll position must pin to bottom of document
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, initialDocHeight - 400)
    }

    func testLongChatVirtualizesOffscreenCellsInDocumentView() {
        let messages = (1...60).map { idx in
            AgentMessage(
                role: idx.isMultiple(of: 2) ? .assistant : .user,
                content: "Message line \(idx) with details\nSecond line of message \(idx)\nThird line of message \(idx)"
            )
        }
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        guard let docView = scrollView.documentView as? AgentChatDocumentView else {
            XCTFail("Expected AgentChatDocumentView")
            return
        }

        let mountedAtBottom = docView.subviews.compactMap { $0 as? AgentMessageCell }.filter { !$0.isHidden }
        XCTAssertLessThan(mountedAtBottom.count, messages.count, "Offscreen cells far above viewport should be hidden/virtualized")
        XCTAssertTrue(mountedAtBottom.contains { $0.message.id == messages.last?.id })

        // Scroll to the very top and verify top cells become visible while bottom cells hide,
        // and verify that offscreen user messages have alphaValue == 1 on their content bubble!
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let mountedAtTop = docView.subviews.compactMap { $0 as? AgentMessageCell }.filter { !$0.isHidden }
        XCTAssertLessThan(mountedAtTop.count, messages.count)
        XCTAssertTrue(mountedAtTop.contains { $0.message.id == messages.first?.id })
        XCTAssertFalse(mountedAtTop.contains { $0.message.id == messages.last?.id })

        let firstUserCell = mountedAtTop.first { $0.message.role == .user }
        XCTAssertNotNil(firstUserCell)
        if let firstUserCell {
            let visibleUserSubtree = firstUserCell.subviews.filter { !$0.isHidden && $0.alphaValue < 0.99 }
            XCTAssertTrue(visibleUserSubtree.isEmpty, "User message bubble must not stay at alpha 0 when scrolled into view")
        }
    }

    func testStreamingLargeGrowthAndBottomInsetKeepAutoScrollPinned() {
        let streamingID = UUID()
        var messages: [AgentMessage] = (1...14).map { idx in
            AgentMessage(
                role: idx.isMultiple(of: 2) ? .assistant : .user,
                content: "Message \(idx) line 1\nMessage \(idx) line 2"
            )
        }
        messages.append(AgentMessage(id: streamingID, role: .assistant, content: "Starting...", isStreaming: true))

        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        let initialDocHeight = scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(initialDocHeight, 400)
        XCTAssertEqual(scrollView.contentView.bounds.maxY, initialDocHeight, accuracy: 1.0)
        XCTAssertTrue(scrollView.isNearBottom)

        // Grow streaming message by >100pt (exceeding the 70pt near-bottom threshold) in one update.
        let largeChunk = (1...14).map { "Streamed line \($0) with enough text to wrap cleanly" }.joined(separator: "\n")
        messages[messages.count - 1].content = largeChunk
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        let afterChunkHeight = scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(afterChunkHeight - initialDocHeight, 100)
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            afterChunkHeight,
            accuracy: 1.0,
            "Auto-scroll must stay pinned to bottom even when one streaming update grows height by >70pt"
        )
        XCTAssertTrue(scrollView.isNearBottom)

        // Spawning a tool call + increasing bottomInset should also keep bottom pinned.
        messages[messages.count - 1].appendToolCall(
            ToolCallItem(id: "tc-1", toolName: "read_file", path: "Sources/App.swift", status: .running)
        )
        scrollView.update(messages: messages, theme: .zedDark, animated: false, bottomInset: 80)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        let afterToolHeight = scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(afterToolHeight, afterChunkHeight)
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            afterToolHeight,
            accuracy: 1.0,
            "Auto-scroll must stay pinned after tool call spawn and bottomInset change"
        )

        // If the user explicitly scrolls up, subsequent streaming updates must NOT yank them back down.
        let scrolledUpY = max(0, afterToolHeight - 400 - 200)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrolledUpY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertFalse(scrollView.isNearBottom)

        messages[messages.count - 1].content += "\nMore streamed lines\nEven more streamed lines"
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, scrolledUpY, accuracy: 1.0)
        XCTAssertFalse(scrollView.isNearBottom)
    }

    func testConcurrentToolCallSpawnsWhileScrollingStaySmoothAndStable() {
        let streamingID = UUID()
        var messages: [AgentMessage] = (1...12).map { idx in
            AgentMessage(
                role: idx.isMultiple(of: 2) ? .assistant : .user,
                content: "Turn \(idx) line 1\nTurn \(idx) line 2\nTurn \(idx) line 3"
            )
        }
        messages.append(AgentMessage(id: streamingID, role: .assistant, content: "Inspecting...", isStreaming: true))
        messages.append(AgentMessage(role: .user, content: "Queued follow-up", isQueued: true, queuePosition: 1, queueTotal: 1))

        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        scrollView.layoutSubtreeIfNeeded()

        let activeIdx = messages.count - 2

        // 1. Pinned at bottom: spawn tool calls + grouped tool calls + interleaved text
        // while a queued message is present. Bottom must stay locked with no animated scroll-fights.
        messages[activeIdx].appendToolCall(
            ToolCallItem(id: "tc-1", toolName: "fs/read_text_file", path: "Sources/A.swift", status: .running)
        )
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            scrollView.documentView?.bounds.height ?? 0,
            accuracy: 1.0,
            "First tool call spawn must remain pinned at bottom"
        )
        XCTAssertTrue(scrollView.contentView.layer?.animationKeys()?.isEmpty ?? true, "Streaming updates must not start scroll animations")

        // Second consecutive tool call triggers grouping into AgentToolGroupView
        messages[activeIdx].appendToolCall(
            ToolCallItem(id: "tc-2", toolName: "run_command", command: "git status", status: .running)
        )
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            scrollView.documentView?.bounds.height ?? 0,
            accuracy: 1.0,
            "Grouping consecutive tool calls must keep bottom pinned without losing auto-scroll"
        )

        // Interleaved text after tool calls + third tool call
        messages[activeIdx].appendText("\nFound the issue, running tests now.\n")
        messages[activeIdx].appendToolCall(
            ToolCallItem(id: "tc-3", toolName: "run_command", command: "just test", output: "604 passed", status: .completed)
        )
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            scrollView.documentView?.bounds.height ?? 0,
            accuracy: 1.0,
            "Interleaved text and subsequent tool calls must keep bottom pinned"
        )
        XCTAssertTrue(scrollView.contentView.layer?.animationKeys()?.isEmpty ?? true)

        // 2. Concurrent manual scrolling while tool calls continue spawning below:
        // origin.y must track ONLY the user's manual scroll deltas with zero jumping or yanking.
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        var manualY = max(0, docHeight - 420 - 200)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: manualY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertFalse(scrollView.isNearBottom)

        for step in 4...5 {
            manualY = max(0, manualY - 35)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: manualY))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            messages[activeIdx].appendToolCall(
                ToolCallItem(id: "tc-\(step)", toolName: "fs/read_text_file", path: "Sources/File\(step).swift", status: .running)
            )
            messages[activeIdx].appendText("\nStep \(step) streamed output.")
            scrollView.update(messages: messages, theme: .zedDark, animated: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))

            XCTAssertEqual(
                scrollView.contentView.bounds.origin.y,
                manualY,
                accuracy: 0.5,
                "Manual scroll position must not jump when tool calls spawn during scroll (step \(step))"
            )
            XCTAssertTrue(scrollView.contentView.layer?.animationKeys()?.isEmpty ?? true)
        }
    }

    func testStreamingScrollPreservesResponsiveScrollingAndEliminatesRubberBandAndNearBottomJitter() {
        XCTAssertTrue(
            AgentChatScrollView.isCompatibleWithResponsiveScrolling,
            "AgentChatScrollView must remain compatible with macOS asynchronous responsive scrolling"
        )
        XCTAssertTrue(FlippedClipView.isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(AgentChatDocumentView.isCompatibleWithResponsiveScrolling)

        let streamingID = UUID()
        var messages: [AgentMessage] = (1...14).map { idx in
            AgentMessage(
                role: idx.isMultiple(of: 2) ? .assistant : .user,
                content: "History \(idx) line 1\nHistory \(idx) line 2\nHistory \(idx) line 3"
            )
        }
        messages.append(AgentMessage(id: streamingID, role: .assistant, content: "Done. I inspected the", isStreaming: true))

        let viewportHeight: CGFloat = 420
        let scrollView = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: viewportHeight))
        scrollView.update(messages: messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        let activeIdx = messages.count - 1
        let initialDocHeight = scrollView.documentView?.bounds.height ?? 0
        let initialMaxY = max(0, initialDocHeight - viewportHeight)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, initialMaxY, accuracy: 0.5)

        // 1. Small upward scroll (18pt, well within the 70pt isNearBottom hysteresis zone):
        // Streaming updates MUST NOT yank the user back to bottom.
        let subtleUpwardY = initialMaxY - 18
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: subtleUpwardY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertTrue(scrollView.isNearBottom, "18pt from bottom is still within the button's near-bottom hysteresis")

        messages[activeIdx].appendText(" project workspace and verified the context.\n\n## Verified Items")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            subtleUpwardY,
            accuracy: 0.5,
            "Upward scroll inside the 70pt hysteresis zone must not be yanked back to bottom on stream tick"
        )

        // 2. Downward scroll entering the <=35pt zone (e.g. 20pt from bottom):
        // Must NOT teleport the remaining 20pt before the user's scroll actually reaches the bottom.
        let docHeight2 = scrollView.documentView?.bounds.height ?? 0
        let nearBottomY = max(0, docHeight2 - viewportHeight - 20)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: nearBottomY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        messages[activeIdx].appendText("\n- Layout stability and smooth scrolling.")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            nearBottomY,
            accuracy: 0.5,
            "Approaching bottom (20pt away) during downward scroll must not snap-teleport to bottom"
        )

        // 3. Downward swipe overscrolling past bottom into rubber-band (+53pt overscroll):
        // Streaming updates (both multi-line growth and same-line token appends) must preserve
        // the current overscroll offset instead of snapping origin.y down to maxScrollY.
        let flippedClip = scrollView.contentView as? FlippedClipView
        XCTAssertNotNil(flippedClip)
        func simulateElasticScroll(to y: CGFloat) {
            flippedClip?.allowsVerticalOverscroll = true
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            flippedClip?.allowsVerticalOverscroll = false
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let docHeight3 = scrollView.documentView?.bounds.height ?? 0
        let maxScrollY3 = max(0, docHeight3 - viewportHeight)
        let overscrollAmount: CGFloat = 90
        let preGrowthOverscrollOriginY = maxScrollY3 + overscrollAmount
        simulateElasticScroll(to: preGrowthOverscrollOriginY)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, preGrowthOverscrollOriginY, accuracy: 0.5)

        // 3a. Multi-line streaming update while rubber-band overscrolled (+90pt):
        // New content fills into the overscrolled space without clamping origin.y down to maxScrollY4
        // AND without sawtooth-yanking origin.y upward by +dH.
        messages[activeIdx].appendText("\n- Real-time Markdown formatting\n- Tool call timeline integration")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        let docHeight4 = scrollView.documentView?.bounds.height ?? 0
        let maxScrollY4 = max(0, docHeight4 - viewportHeight)
        XCTAssertGreaterThan(docHeight4, docHeight3)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            maxScrollY4 + overscrollAmount,
            accuracy: 0.5,
            "Bottom rubber-band overscroll must stay in phase with AppKit VBL rubber-band curve (maxScrollY4 + overscrollAmount)"
        )

        // 3b. Same-line streaming update while rubber-band spring relaxes to +35pt
        let relaxedOverscroll: CGFloat = 35
        simulateElasticScroll(to: maxScrollY4 + relaxedOverscroll)

        messages[activeIdx].appendText(".")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        let docHeight5 = scrollView.documentView?.bounds.height ?? 0
        let maxScrollY5 = max(0, docHeight5 - viewportHeight)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            maxScrollY5 + relaxedOverscroll,
            accuracy: 0.5,
            "Same-line streaming update must not snap rubber-band overscroll to 0"
        )

        // 3c. Live-scroll bottom rubber-band relaxation when docHeight grows mid-bounce:
        // AppKit's spring relaxing back to pre-growth maxScrollY5 must NOT falsely flip followsBottom to false,
        // and didEndLiveScrollNotification must cleanly pin to the new bottom.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        simulateElasticScroll(to: maxScrollY5 + 10)
        messages[activeIdx].appendText("\n\nReady for the next instructions!\nExtra line during bounce")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        // Simulate AppKit's rubber-band spring relaxing back to the pre-growth maxScrollY5
        simulateElasticScroll(to: maxScrollY5)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)

        let docHeight6 = scrollView.documentView?.bounds.height ?? 0
        XCTAssertEqual(
            scrollView.contentView.bounds.maxY,
            docHeight6,
            accuracy: 0.5,
            "Once rubber-band live scroll ends at bottom, auto-scroll must remain pinned to the new document bottom"
        )

        // 4. Top rubber-band overscroll (origin.y < 0) must not be clamped to 0 by streaming updates
        simulateElasticScroll(to: -32)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, -32, accuracy: 0.5)

        messages[activeIdx].appendText("\nTrailing line 1\nTrailing line 2")
        scrollView.update(messages: messages, theme: .zedDark, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            -32,
            accuracy: 0.5,
            "Top rubber-band overscroll must not be clamped to 0 when streaming grows document at bottom"
        )
    }
    #endif

    func testStreamingMessageUsesOneIncrementalTextViewUntilCompletion() {
        let id = UUID()
        let content = (1...13).map { "- streamed line \($0)" }.joined(separator: "\n")
        let streaming = AgentMessage(id: id, role: .assistant, content: content, isStreaming: true)
        let cell = AgentMessageCell(message: streaming, theme: .zedDark)

        _ = cell.layout(for: 420)
        XCTAssertEqual(cell.allSelectableTextViews().count, 1)
        XCTAssertTrue(cell.allSelectableTextViews()[0].string.contains("streamed line 1"))
        XCTAssertTrue(cell.allSelectableTextViews()[0].string.contains("streamed line 13"))

        let completed = AgentMessage(id: id, role: .assistant, content: content, isStreaming: false)
        cell.configure(message: completed, theme: .zedDark)
        _ = cell.layout(for: 420)

        XCTAssertGreaterThan(cell.allSelectableTextViews().count, 1)
    }

    func testManagerReceiveUpdateStreaming() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()

        manager.sendPrompt("Hello", workingDirectory: tempDir)
        XCTAssertEqual(manager.messages.count, 2)
        XCTAssertEqual(manager.messages[0].role, .user)
        XCTAssertEqual(manager.messages[0].content, "Hello")
        XCTAssertEqual(manager.messages[1].role, .assistant)
        XCTAssertTrue(manager.messages[1].isStreaming)

        let updateContent = ACPSessionUpdateContent(
            type: "message_chunk",
            content: " World",
            delta: " World",
            toolCallId: nil,
            toolName: nil,
            toolInput: nil,
            toolResult: nil,
            isError: nil
        )

        let client = ACPClient()
        manager.client(client, didReceiveUpdate: updateContent, sessionId: "sess-1")

        let exp = expectation(description: "UI updates on Main thread")
        DispatchQueue.main.async {
            XCTAssertTrue(manager.messages[1].content.contains("World"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testUsageUpdateDoesNotCreatePhantomAssistantMessage() {
        let manager = ACPAgentSessionManager()
        XCTAssertTrue(manager.messages.isEmpty)
        XCTAssertFalse(manager.hasVisibleMessages)

        // When ACP connects, it sends usage_update or metadata updates.
        let client = ACPClient()
        let updateContent = ACPSessionUpdateContent(
            type: "usage_update",
            content: nil,
            delta: nil,
            toolCallId: nil,
            toolName: nil,
            toolInput: nil,
            toolResult: nil,
            isError: nil,
            used: 1500,
            size: 100000
        )
        manager.client(client, didReceiveUpdate: updateContent, sessionId: "sess-init")

        let exp = expectation(description: "Process usage update on Main thread")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.contextUsagePercentage, 2)
            XCTAssertTrue(manager.messages.isEmpty, "usage_update must not create phantom empty assistant messages")
            XCTAssertFalse(manager.hasVisibleMessages)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testManagerReceiveToolExecution() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()

        manager.sendPrompt("Edit file", workingDirectory: tempDir)
        let client = ACPClient()
        manager.client(client, didExecuteTool: "fs/write_text_file", path: "test.swift", details: "Wrote 100 bytes")

        let exp = expectation(description: "Tool execution logged on Main thread")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.messages[1].toolCalls.count, 1)
            XCTAssertEqual(manager.messages[1].toolCalls[0].toolName, "fs/write_text_file")
            XCTAssertEqual(manager.messages[1].toolCalls[0].path, "test.swift")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testManagerKeepsPermissionRequestPendingUntilUserDecision() {
        let manager = ACPAgentSessionManager()
        let request = ACPRequestPermissionParams(
            sessionId: "sess-1",
            toolCall: ACPPermissionToolCall(
                toolCallId: "call-1",
                title: "Run Swift tests",
                kind: "execute",
                rawInput: ["command": AnyCodableSendable("swift test")]
            ),
            options: [
                ACPPermissionOption(optionId: "allow-once", name: "Allow once", kind: "allow_once"),
                ACPPermissionOption(optionId: "reject-once", name: "Reject", kind: "reject_once")
            ]
        )

        manager.client(ACPClient(), didRequestPermission: request, requestId: .integer(42))

        let exp = expectation(description: "Permission request appears on the main thread")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.pendingPermission?.requestId, .integer(42))
            XCTAssertEqual(manager.pendingPermission?.title, "Run Swift tests")
            XCTAssertEqual(manager.pendingPermission?.command, "swift test")
            XCTAssertEqual(manager.pendingPermission?.options.count, 2)
            XCTAssertEqual(manager.statusMessage, "Waiting for permission...")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testToolCallRunningToCompletedTransition() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()

        manager.sendPrompt("Check diff", workingDirectory: tempDir)
        let client = ACPClient()

        // 1. Tool call started
        let toolStart = ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "call_1",
            toolName: "run_command",
            toolInput: ["CommandLine": AnyCodableSendable("git diff")],
            status: "running"
        )
        manager.client(client, didReceiveUpdate: toolStart, sessionId: "sess-1")

        let exp1 = expectation(description: "Tool call added")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.messages[1].toolCalls.count, 1)
            XCTAssertEqual(manager.messages[1].toolCalls[0].status, .running)
            XCTAssertEqual(manager.messages[1].toolCalls[0].shortToolName, "Run")
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        // 2. Subsequent message text received -> tool call automatically marked completed
        let textUpdate = ACPSessionUpdateContent(
            type: "message_chunk",
            content: "Here is the diff output"
        )
        manager.client(client, didReceiveUpdate: textUpdate, sessionId: "sess-1")

        let exp2 = expectation(description: "Tool call completed on message chunk")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.messages[1].toolCalls[0].status, .completed)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testSendPromptWithImages() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()

        let dummyData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let img1 = AgentImageAttachment(data: dummyData, filename: "img1.png")
        let img2 = AgentImageAttachment(data: dummyData, filename: "img2.png")

        manager.sendPrompt("Inspect these 2 mock screenshots", images: [img1, img2], workingDirectory: tempDir)

        XCTAssertEqual(manager.messages.count, 2)
        XCTAssertEqual(manager.messages[0].role, .user)
        XCTAssertEqual(manager.messages[0].content, "Inspect these 2 mock screenshots")
        XCTAssertEqual(manager.messages[0].images.count, 2)
        XCTAssertEqual(manager.messages[0].images[0].filename, "img1.png")
        XCTAssertEqual(manager.messages[0].images[1].filename, "img2.png")
    }

    func testUserMessageEchoDoesNotDuplicateDuringActiveStream() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()

        manager.sendPrompt("hey bro", workingDirectory: tempDir)
        XCTAssertEqual(manager.messages.count, 2)
        XCTAssertEqual(manager.messages[0].role, .user)
        XCTAssertEqual(manager.messages[0].content, "hey bro")
        XCTAssertEqual(manager.messages[1].role, .assistant)
        XCTAssertTrue(manager.messages[1].isStreaming)

        // Agent echoes the user prompt back via session/update notification (e.g. OpenCode/SourceCraft)
        let echoUpdate = ACPSessionUpdateContent(
            type: "user_message_chunk",
            content: "hey bro",
            delta: "hey bro"
        )
        let client = ACPClient()
        manager.client(client, didReceiveUpdate: echoUpdate, sessionId: "sess-1")

        let exp = expectation(description: "UI updates on Main thread")
        DispatchQueue.main.async {
            // Must still have only 2 messages: 1 user + 1 assistant
            XCTAssertEqual(manager.messages.count, 2)
            XCTAssertEqual(manager.messages[0].role, .user)
            XCTAssertEqual(manager.messages[0].content, "hey bro")
            XCTAssertEqual(manager.messages[1].role, .assistant)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testAgentConfigOptionPersistenceAcrossSessions() {
        let suiteName = "test.anydiff.config.persistence.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let agyManager1 = ACPAgentSessionManager()
        agyManager1.presetId = "agy"
        agyManager1.userDefaults = testDefaults

        agyManager1.configOptions = [
            ACPConfigOption(
                id: ACPConfigOptionID.model,
                name: "Model",
                currentValue: "gemini-3.7-flash-high",
                options: [
                    ACPConfigOption.OptionValue(value: "gemini-3.7-flash-high", name: "Gemini 3.7 Flash (High)"),
                    ACPConfigOption.OptionValue(value: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)")
                ]
            ),
            ACPConfigOption(
                id: ACPConfigOptionID.mode,
                name: "Session Mode",
                currentValue: "default",
                options: [
                    ACPConfigOption.OptionValue(value: "default", name: "Default"),
                    ACPConfigOption.OptionValue(value: "architect", name: "Architect")
                ]
            )
        ]

        // Select Gemini 3.8 and architect mode
        agyManager1.selectConfigOption(id: ACPConfigOptionID.model, value: "gemini-3.8-flash-high")
        agyManager1.selectConfigOption(id: ACPConfigOptionID.mode, value: "architect")

        XCTAssertEqual(agyManager1.selectedModel, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(agyManager1.selectedModelValue, "gemini-3.8-flash-high")
        XCTAssertEqual(agyManager1.selectedAgentMode, "Architect")
        XCTAssertEqual(agyManager1.selectedAgentModeValue, "architect")

        // Create a completely new manager for agy with the same UserDefaults
        let agyManager2 = ACPAgentSessionManager()
        agyManager2.presetId = "agy"
        agyManager2.userDefaults = testDefaults

        let saved = agyManager2.savedConfigOptions()
        XCTAssertEqual(saved[ACPConfigOptionID.model], "gemini-3.8-flash-high")
        XCTAssertEqual(saved[ACPConfigOptionID.mode], "architect")

        // Claude manager should NOT have agy's saved options
        let claudeManager = ACPAgentSessionManager()
        claudeManager.presetId = "claude"
        claudeManager.userDefaults = testDefaults
        XCTAssertTrue(claudeManager.savedConfigOptions().isEmpty)
    }

    func testOptionsWithSavedPreferencesMergedRestoresModelAndFiltersInvalid() {
        let suiteName = "test.anydiff.config.merge.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let manager = ACPAgentSessionManager()
        manager.presetId = "agy"
        manager.userDefaults = testDefaults

        // Save a valid model and an invalid/obsolete mode
        manager.saveConfigOption(id: ACPConfigOptionID.model, value: "gemini-3.8-flash-high")
        manager.saveConfigOption(id: ACPConfigOptionID.mode, value: "nonexistent-obsolete-mode")

        // Server returns default options (3.7)
        let serverOptions = [
            ACPConfigOption(
                id: ACPConfigOptionID.model,
                name: "Model",
                currentValue: "gemini-3.7-flash-high",
                options: [
                    ACPConfigOption.OptionValue(value: "gemini-3.7-flash-high", name: "Gemini 3.7 Flash (High)"),
                    ACPConfigOption.OptionValue(value: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)")
                ]
            ),
            ACPConfigOption(
                id: ACPConfigOptionID.mode,
                name: "Session Mode",
                currentValue: "default",
                options: [
                    ACPConfigOption.OptionValue(value: "default", name: "Default"),
                    ACPConfigOption.OptionValue(value: "ask", name: "Ask")
                ]
            )
        ]

        let (merged, toSync) = manager.optionsWithSavedPreferencesMerged(serverOptions)

        // Valid model is restored to 3.8 and queued for sync
        let restoredModel = merged.first(where: { $0.id == ACPConfigOptionID.model })
        XCTAssertEqual(restoredModel?.currentValue, "gemini-3.8-flash-high")
        XCTAssertEqual(toSync.count, 1)
        XCTAssertEqual(toSync[0].configId, ACPConfigOptionID.model)
        XCTAssertEqual(toSync[0].value, "gemini-3.8-flash-high")

        // Invalid mode was rejected and kept as server default ("default")
        let keptMode = merged.first(where: { $0.id == ACPConfigOptionID.mode })
        XCTAssertEqual(keptMode?.currentValue, "default")

        // Apply merged options to manager
        manager.applyConfigOptions(merged)
        XCTAssertEqual(manager.selectedModel, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(manager.selectedModelValue, "gemini-3.8-flash-high")
        XCTAssertEqual(manager.selectedAgentMode, "Default")
    }

    func testBooleanConfigOptionPersistence() {
        let suiteName = "test.anydiff.config.bool.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let manager = ACPAgentSessionManager()
        manager.presetId = "codex"
        manager.userDefaults = testDefaults

        let boolOpt = ACPConfigOption(
            id: "enable_web_search",
            name: "Web Search",
            type: "boolean",
            currentValue: "false"
        )

        manager.configOptions = [boolOpt]
        manager.selectConfigOption(id: "enable_web_search", value: "true")

        XCTAssertEqual(manager.configOptions[0].currentValue, "true")
        XCTAssertEqual(manager.savedConfigOptions()["enable_web_search"], "true")

        let (merged, toSync) = manager.optionsWithSavedPreferencesMerged([boolOpt])
        XCTAssertEqual(merged[0].currentValue, "true")
        XCTAssertEqual(toSync.count, 1)
        XCTAssertEqual(toSync[0].configId, "enable_web_search")
        XCTAssertEqual(toSync[0].value, "true")
    }

    func testApplyConfigOptionsPopulatesCurrentValueWhenNil() {
        let manager = ACPAgentSessionManager()
        let modelOpt = ACPConfigOption(
            id: ACPConfigOptionID.model,
            name: "Model",
            category: "model",
            type: "select",
            currentValue: nil, // server sent nil
            options: [
                ACPConfigOption.OptionValue(value: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)"),
                ACPConfigOption.OptionValue(value: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash (Medium)")
            ]
        )
        manager.applyConfigOptions([modelOpt])

        XCTAssertEqual(manager.selectedModelValue, "gemini-3.8-flash-high")
        XCTAssertEqual(manager.selectedModel, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(manager.configOptions.first?.currentValue, "gemini-3.8-flash-high", "configOptions must have non-nil currentValue matching the selected default")
    }

    // MARK: - Prompt Queue Tests

    func testEnqueueAndDequeuePrompt() {
        let manager = ACPAgentSessionManager()
        XCTAssertTrue(manager.promptQueue.isEmpty)

        let id1 = manager.enqueuePrompt("First prompt", workingDirectory: "/tmp/repo")
        let id2 = manager.enqueuePrompt("Second prompt", workingDirectory: "/tmp/repo")

        XCTAssertEqual(manager.promptQueue.count, 2)
        XCTAssertEqual(manager.promptQueue[0].id, id1)
        XCTAssertEqual(manager.promptQueue[0].text, "First prompt")
        XCTAssertEqual(manager.promptQueue[0].workingDirectory, "/tmp/repo")
        XCTAssertEqual(manager.promptQueue[1].id, id2)
        XCTAssertEqual(manager.promptQueue[1].text, "Second prompt")

        let dequeued1 = manager.dequeuePrompt()
        XCTAssertEqual(dequeued1?.id, id1)
        XCTAssertEqual(dequeued1?.text, "First prompt")
        XCTAssertEqual(manager.promptQueue.count, 1)

        let dequeued2 = manager.dequeuePrompt()
        XCTAssertEqual(dequeued2?.id, id2)
        XCTAssertTrue(manager.promptQueue.isEmpty)

        let dequeuedEmpty = manager.dequeuePrompt()
        XCTAssertNil(dequeuedEmpty)
    }

    func testUpdateQueuedPrompt() {
        let manager = ACPAgentSessionManager()
        let id = manager.enqueuePrompt("Original text")

        manager.updateQueuedPrompt(id: id, text: "Updated text")
        XCTAssertEqual(manager.promptQueue.first?.text, "Updated text")

        // Updating to whitespace with no images should remove it
        manager.updateQueuedPrompt(id: id, text: "   ")
        XCTAssertTrue(manager.promptQueue.isEmpty)
    }

    func testRemoveQueuedPrompt() {
        let manager = ACPAgentSessionManager()
        let id1 = manager.enqueuePrompt("Prompt 1")
        let id2 = manager.enqueuePrompt("Prompt 2")
        let id3 = manager.enqueuePrompt("Prompt 3")

        manager.removeQueuedPrompt(id: id2)
        XCTAssertEqual(manager.promptQueue.count, 2)
        XCTAssertEqual(manager.promptQueue.map(\.id), [id1, id3])
    }

    func testMoveQueuedPrompt() {
        let manager = ACPAgentSessionManager()
        let id1 = manager.enqueuePrompt("Prompt 1")
        let id2 = manager.enqueuePrompt("Prompt 2")
        let id3 = manager.enqueuePrompt("Prompt 3")

        // Move #2 up -> becomes #1
        manager.moveQueuedPrompt(id: id2, direction: .up)
        XCTAssertEqual(manager.promptQueue.map(\.id), [id2, id1, id3])

        // Move #2 down -> becomes #2 again
        manager.moveQueuedPrompt(id: id2, direction: .down)
        XCTAssertEqual(manager.promptQueue.map(\.id), [id1, id2, id3])

        // Move #1 up when already at top -> no change
        manager.moveQueuedPrompt(id: id1, direction: .up)
        XCTAssertEqual(manager.promptQueue.map(\.id), [id1, id2, id3])

        // Move #3 down when already at bottom -> no change
        manager.moveQueuedPrompt(id: id3, direction: .down)
        XCTAssertEqual(manager.promptQueue.map(\.id), [id1, id2, id3])
    }

    func testClearQueueAndClearSession() {
        let manager = ACPAgentSessionManager()
        _ = manager.enqueuePrompt("Prompt 1")
        _ = manager.enqueuePrompt("Prompt 2")
        XCTAssertEqual(manager.promptQueue.count, 2)

        manager.clearQueue()
        XCTAssertTrue(manager.promptQueue.isEmpty)

        _ = manager.enqueuePrompt("Prompt 3")
        XCTAssertEqual(manager.promptQueue.count, 1)

        manager.clearSession()
        XCTAssertTrue(manager.promptQueue.isEmpty)
    }

    func testCanAcceptPromptAllowsQueuingWhenBusy() {
        let manager = ACPAgentSessionManager()
        XCTAssertTrue(manager.canAcceptPrompt)

        manager.status = .busy
        XCTAssertTrue(manager.canAcceptPrompt)

        manager.pendingPermission = AgentPermissionRequest(
            requestId: .string("req-1"),
            sessionId: "sess-1",
            toolCallId: "tool-1",
            title: "Command execution",
            options: []
        )
        XCTAssertFalse(manager.canAcceptPrompt)

        manager.pendingPermission = nil
        XCTAssertTrue(manager.canAcceptPrompt)
    }

    #if DEBUG
    func testMockAgentSessionManagerAutoDrainsQueue() async throws {
        let manager = MockAgentSessionManager(loadFixtures: false)
        XCTAssertEqual(manager.status, .idle)

        // Send first prompt
        manager.sendPrompt("First prompt", workingDirectory: "/tmp")
        XCTAssertEqual(manager.status, .busy)

        // While busy, send second prompt -> it should be enqueued!
        manager.sendPrompt("Second prompt", workingDirectory: "/tmp")
        XCTAssertEqual(manager.promptQueue.count, 1)
        XCTAssertEqual(manager.promptQueue.first?.text, "Second prompt")

        // Also enqueue third prompt
        manager.sendPrompt("Third prompt", workingDirectory: "/tmp")
        XCTAssertEqual(manager.promptQueue.count, 2)
    }

    func testMockAgentSessionManagerCancelDoesNotDrainQueue() {
        let manager = MockAgentSessionManager(loadFixtures: false)
        manager.sendPrompt("Active prompt", workingDirectory: "/tmp")
        XCTAssertEqual(manager.status, .busy)

        // Queue another prompt
        manager.sendPrompt("Queued prompt", workingDirectory: "/tmp")
        XCTAssertEqual(manager.promptQueue.count, 1)

        // Cancel active turn
        manager.cancel()
        XCTAssertEqual(manager.status, .idle)

        // The queued prompt should remain in queue intact!
        XCTAssertEqual(manager.promptQueue.count, 1)
        XCTAssertEqual(manager.promptQueue.first?.text, "Queued prompt")
    }

    func testQueuedMessageConversionToAgentMessage() {
        let queued = AgentQueuedMessage(
            text: "Hello from queue",
            images: [],
            workingDirectory: "/tmp"
        )
        let agentMsg = queued.asAgentMessage(index: 0, total: 3)
        XCTAssertEqual(agentMsg.id, queued.id)
        XCTAssertEqual(agentMsg.role, .user)
        XCTAssertEqual(agentMsg.content, "Hello from queue")
        XCTAssertTrue(agentMsg.isQueued)
        XCTAssertEqual(agentMsg.queuePosition, 1)
        XCTAssertEqual(agentMsg.queueTotal, 3)
        XCTAssertTrue(agentMsg.hasVisibleContent)
    }

    func testHasVisibleMessagesIncludesPromptQueue() {
        let manager = MockAgentSessionManager(loadFixtures: false)
        XCTAssertFalse(manager.hasVisibleMessages)

        manager.enqueuePrompt("Pending item", workingDirectory: "/tmp")
        XCTAssertTrue(manager.hasVisibleMessages)
    }

    @MainActor
    func testAgentMessageCellQueuedLayoutAndHeader() {
        let queued = AgentQueuedMessage(text: "Queued question", workingDirectory: "/tmp")
        let msg = queued.asAgentMessage(index: 0, total: 2)

        let cell = AgentMessageCell(
            message: msg,
            theme: Theme.vesper,
            accentColor: .accentColor,
            toolcallColorMode: .full,
            nativeTextSelectionEnabled: true,
            agentIconName: "sparkles",
            agentId: "default"
        )

        XCTAssertFalse(cell.queuedHeaderView.isHidden)
        XCTAssertEqual(cell.userBubbleView.alphaValue, 0.94, accuracy: 0.01)

        var deleteCalled = false
        cell.onDeleteQueuedMessage = { id in
            if id == queued.id { deleteCalled = true }
        }
        cell.queuedHeaderView.onDelete?()
        XCTAssertTrue(deleteCalled)

        // Test in-place editing
        XCTAssertFalse(cell.isEditingQueuedMessage)
        cell.queuedHeaderView.onEdit?()
        XCTAssertTrue(cell.isEditingQueuedMessage)
        XCTAssertFalse(cell.queuedEditorView.isHidden)
        XCTAssertEqual(cell.queuedEditorView.currentText, "Queued question")

        var updatedText = ""
        cell.onUpdateQueuedMessage = { id, text in
            if id == queued.id { updatedText = text }
        }
        cell.queuedEditorView.textView.string = "Edited inline question"
        cell.queuedEditorView.textView.onSave?()
        XCTAssertEqual(updatedText, "Edited inline question")
        XCTAssertFalse(cell.isEditingQueuedMessage)
        XCTAssertTrue(cell.queuedEditorView.isHidden)

        // Test cancel
        cell.startEditingQueuedMessage()
        XCTAssertTrue(cell.isEditingQueuedMessage)
        cell.queuedEditorView.textView.onCancel?()
        XCTAssertFalse(cell.isEditingQueuedMessage)
        XCTAssertTrue(cell.queuedEditorView.isHidden)

        let height = cell.layout(for: 600)
        XCTAssertGreaterThan(height, 30)
    }

    func testACPTransportRelaunchDoesNotFireStaleTermination() throws {
        final class Delegate: ACPTransportDelegate, @unchecked Sendable {
            let lock = NSLock()
            var terminateCount = 0
            func transport(_ transport: ACPTransport, didReceiveLine data: Data) {}
            func transport(_ transport: ACPTransport, didLogStderr text: String) {}
            func transport(_ transport: ACPTransport, didTerminateWith exitCode: Int32) {
                lock.lock()
                terminateCount += 1
                lock.unlock()
            }
        }

        let transport = ACPTransport()
        let delegate = Delegate()
        transport.delegate = delegate

        try transport.launch(command: "/bin/sleep 5", workingDirectory: "/tmp")
        XCTAssertTrue(transport.isRunning)

        // Immediately terminate and relaunch (mirrors worktree switch)
        transport.terminate()
        try transport.launch(command: "/bin/sleep 5", workingDirectory: "/tmp")

        Thread.sleep(forTimeInterval: 0.04)
        delegate.lock.lock()
        let count = delegate.terminateCount
        delegate.lock.unlock()

        XCTAssertEqual(count, 0)
        XCTAssertTrue(transport.isRunning)

        transport.terminate()
    }

    @MainActor
    func testSwitchWorkingDirectoryMidTurnDefersReconnectAndCompletesCleanly() async throws {
        let savedCommand = UserDefaults.standard.string(forKey: "anydiff_acp_command")
        defer {
            if let savedCommand {
                UserDefaults.standard.set(savedCommand, forKey: "anydiff_acp_command")
            } else {
                UserDefaults.standard.removeObject(forKey: "anydiff_acp_command")
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_acp_switch_test_\(UUID().uuidString)")
        let dirA = tempRoot.appendingPathComponent("worktree-a")
        let dirB = tempRoot.appendingPathComponent("worktree-b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let scriptURL = tempRoot.appendingPathComponent("mock_acp.py")
        let releaseURL = tempRoot.appendingPathComponent("release_turn1")
        let script = """
        import json, os, sys, time

        cwd_name = os.path.basename(os.getcwd())
        session_id = f"sess-{cwd_name}"
        release_path = \(String(reflecting: releaseURL.path))

        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            method = msg.get("method")
            req_id = msg.get("id")
            if method == "initialize":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": 1,
                        "agentInfo": {"name": "mock-acp", "title": "Mock ACP"}
                    }
                }
                print(json.dumps(resp), flush=True)
            elif method == "session/new":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"sessionId": session_id}
                }
                print(json.dumps(resp), flush=True)
            elif method == "session/prompt":
                if cwd_name == "worktree-a":
                    deadline = time.monotonic() + 5.0
                    while not os.path.exists(release_path) and time.monotonic() < deadline:
                        time.sleep(0.002)
                note = {
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": f"reply-from-{cwd_name}"}
                        }
                    }
                }
                print(json.dumps(note), flush=True)
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"stopReason": "end_turn"}
                }
                print(json.dumps(resp), flush=True)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let manager = ACPAgentSessionManager()
        manager.agentCommand = "/usr/bin/python3 \(scriptURL.path)"
        defer { manager.clearSession() }

        // 1. Start turn 1 in dirA.
        manager.sendPrompt("hello in A", workingDirectory: dirA.path)

        let busyDeadline = Date().addingTimeInterval(5.0)
        while manager.status != .busy && Date() < busyDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(manager.status, .busy)
        XCTAssertEqual(manager.currentSessionId, "sess-worktree-a")

        // 2. Switch worktree while turn 1 is actively running, then unblock turn 1!
        manager.prepareAgent(workingDirectory: dirB.path)
        FileManager.default.createFile(atPath: releaseURL.path, contents: Data())

        // 3. Turn 1 must finish cleanly without "Client stopped" AND then reconnect to dirB.
        let switchDeadline = Date().addingTimeInterval(5.0)
        while (manager.currentSessionId != "sess-worktree-b" || manager.initializationState != .ready) && Date() < switchDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(manager.currentSessionId, "sess-worktree-b")
        XCTAssertEqual(manager.initializationState, .ready)
        XCTAssertFalse(manager.messages.contains { $0.content.contains("Client stopped") })
        XCTAssertTrue(manager.messages.contains { $0.role == .assistant && $0.content.contains("reply-from-worktree-a") })

        // 4. Turn 2 in dirB also completes cleanly.
        manager.sendPrompt("hello in B", workingDirectory: dirB.path)
        let turn2Deadline = Date().addingTimeInterval(5.0)
        while (!manager.messages.contains { $0.role == .assistant && $0.content.contains("reply-from-worktree-b") } || manager.status != .idle) && Date() < turn2Deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.messages.contains { $0.content.contains("Client stopped") })
        XCTAssertTrue(manager.messages.contains { $0.role == .assistant && $0.content.contains("reply-from-worktree-b") })
    }

    @MainActor
    func testRapidWorktreeSwitchDuringStartupDoesNotFailWithClientStopped() async throws {
        let savedCommand = UserDefaults.standard.string(forKey: "anydiff_acp_command")
        defer {
            if let savedCommand {
                UserDefaults.standard.set(savedCommand, forKey: "anydiff_acp_command")
            } else {
                UserDefaults.standard.removeObject(forKey: "anydiff_acp_command")
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_acp_rapid_switch_\(UUID().uuidString)")
        let dirA = tempRoot.appendingPathComponent("worktree-a")
        let dirB = tempRoot.appendingPathComponent("worktree-b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let scriptURL = tempRoot.appendingPathComponent("mock_acp.py")
        let script = """
        import json, os, sys

        cwd_name = os.path.basename(os.getcwd())
        session_id = f"sess-{cwd_name}"

        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            msg = json.loads(raw)
            method = msg.get("method")
            req_id = msg.get("id")
            if method == "initialize":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"protocolVersion": 1, "agentInfo": {"name": "mock-acp"}}
                }), flush=True)
            elif method == "session/new":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"sessionId": session_id}
                }), flush=True)
            elif method == "session/prompt":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": f"ok-{cwd_name}"}
                        }
                    }
                }), flush=True)
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"stopReason": "end_turn"}
                }), flush=True)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let manager = ACPAgentSessionManager()
        manager.agentCommand = "/usr/bin/python3 \(scriptURL.path)"
        defer { manager.clearSession() }

        manager.prepareAgent(workingDirectory: dirA.path)
        manager.prepareAgent(workingDirectory: dirB.path)
        manager.sendPrompt("hi", workingDirectory: dirB.path)

        let deadline = Date().addingTimeInterval(5.0)
        while (!manager.messages.contains { $0.role == .assistant && $0.content.contains("ok-worktree-b") } || manager.status != .idle) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(manager.currentSessionId, "sess-worktree-b")
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.messages.contains { $0.content.contains("Client stopped") })
    }

    func testAgentMessageCellHidesEditedFilesCardWhenNoToolCalls() {
        let summary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentAvatarAuraView.swift", additions: 11, deletions: 3)
        ])

        // Message with NO tool calls
        let messageWithoutTools = AgentMessage(
            role: .assistant,
            content: "Здравствуйте! Чем могу вам помочь?",
            toolCalls: [],
            editedFilesSummary: summary
        )

        let cell = AgentMessageCell(message: messageWithoutTools, theme: .zedDark)

        // Must NOT display the edited files card because there were zero tool calls!
        XCTAssertNil(cell.editedFilesCardView)

        // Message WITH tool calls
        let tool = ToolCallItem(toolName: "fs/write_text_file", path: "AgentAvatarAuraView.swift", status: .completed)
        let messageWithTools = AgentMessage(
            role: .assistant,
            content: "Updated file",
            toolCalls: [tool],
            editedFilesSummary: summary
        )

        cell.configure(message: messageWithTools, theme: .zedDark)
        XCTAssertNotNil(cell.editedFilesCardView)
    }

    func testDidExecuteFSWriteDoesNotHijackRunningReadToolCall() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()
        let client = ACPClient()

        manager.sendPrompt("Update README", workingDirectory: tempDir)

        // 1. A Read tool call with line range is still running
        let readStart = ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "read_theme",
            toolName: "view_file",
            toolInput: [
                "AbsolutePath": AnyCodableSendable("/repo/Sources/Theme.swift"),
                "StartLine": AnyCodableSendable(660),
                "EndLine": AnyCodableSendable(705)
            ],
            status: "running"
        )
        manager.client(client, didReceiveUpdate: readStart, sessionId: "sess-1")

        // 2. An fs/write_text_file executes for a different file (README.md)
        manager.client(
            client,
            didExecuteFSWrite: "/repo/README.md",
            oldContent: "old",
            newContent: "new"
        )

        let exp = expectation(description: "Separate edit created without overwriting Read")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 2)

            XCTAssertEqual(calls[0].id, "read_theme")
            XCTAssertEqual(calls[0].shortToolName, "Read")
            XCTAssertEqual(calls[0].path, "/repo/Sources/Theme.swift")
            XCTAssertEqual(calls[0].displayTitle, "Theme.swift:660-705")

            XCTAssertEqual(calls[1].shortToolName, "Edit")
            XCTAssertEqual(calls[1].path, "/repo/README.md")
            XCTAssertEqual(calls[1].displayTitle, "README.md")
            XCTAssertNil(calls[1].startLine)
            XCTAssertNil(calls[1].endLine)
            XCTAssertEqual(calls[1].oldContent, "old")
            XCTAssertEqual(calls[1].newContent, "new")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testDidExecuteToolMatchesByCategoryAndPathDuringParallelCalls() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()
        let client = ACPClient()

        manager.sendPrompt("Inspect files", workingDirectory: tempDir)

        // 1. Parallel Read and Run calls start
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "read_call",
            toolName: "view_file",
            toolInput: [
                "AbsolutePath": AnyCodableSendable("/repo/Theme.swift"),
                "StartLine": AnyCodableSendable(660),
                "EndLine": AnyCodableSendable(705)
            ],
            status: "running"
        ), sessionId: "sess-1")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "run_call",
            toolName: "run_command",
            toolInput: ["CommandLine": AnyCodableSendable("grep Theme Sources/")],
            status: "running"
        ), sessionId: "sess-1")

        // 2. fs/read_text_file finishes for Theme.swift — must complete read_call, not run_call
        manager.client(client, didExecuteTool: "fs/read_text_file", path: "/repo/Theme.swift", details: "Read 100 chars")

        let exp = expectation(description: "Read completed on matching path")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls[0].id, "read_call")
            XCTAssertEqual(calls[0].status, .completed)
            XCTAssertEqual(calls[0].displayTitle, "Theme.swift:660-705")
            XCTAssertEqual(calls[1].id, "run_call")
            XCTAssertEqual(calls[1].status, .running)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testMultipleFSWritesToSameFileWithoutPrecreatedEditDoNotOverwritePreviousEdit() {
        let manager = ACPAgentSessionManager()
        let tempDir = NSTemporaryDirectory()
        let client = ACPClient()

        manager.sendPrompt("Edit twice", workingDirectory: tempDir)

        manager.client(client, didExecuteFSWrite: "/repo/README.md", oldContent: "v1", newContent: "v2")
        manager.client(client, didExecuteFSWrite: "/repo/README.md", oldContent: "v2", newContent: "v3")

        let exp = expectation(description: "Two edits preserved")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls[0].oldContent, "v1")
            XCTAssertEqual(calls[0].newContent, "v2")
            XCTAssertEqual(calls[1].oldContent, "v2")
            XCTAssertEqual(calls[1].newContent, "v3")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    #endif
}
