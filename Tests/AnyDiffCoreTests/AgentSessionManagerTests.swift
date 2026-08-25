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
        let cell = AgentNativeMessageCell(message: message, theme: .zedDark)

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
            cell.subviews.contains { $0 is AgentNativeCodeBlockView } == false,
            "Code blocks are temporarily disabled in the native agent chat"
        )
    }

    func testToolCallsUseExpandableColoredCardsWhenSimpleModeIsDisabled() {
        let message = MockAgentSessionManager().messages[11]
        let cell = AgentNativeMessageCell(message: message, theme: .zedDark)

        _ = cell.layout(for: 420)

        XCTAssertEqual(
            cell.subviews.compactMap { $0 as? AgentNativeToolCardView }.count,
            message.toolCalls.count
        )
        XCTAssertFalse(cell.subviews.contains { $0 is AgentNativeSimpleToolCallView })
    }

    func testStandardChatScrollViewUsesNativeDocumentView() {
        let manager = MockAgentSessionManager()
        let scrollView = AgentNativeStandardChatScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scrollView.update(messages: manager.messages, theme: .zedDark, animated: false)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertTrue(scrollView.documentView is AgentNativeStandardChatDocumentView)
        XCTAssertGreaterThan(scrollView.documentView?.bounds.height ?? 0, 0)
    }
    #endif

    func testStreamingMessageUsesOneIncrementalTextViewUntilCompletion() {
        let id = UUID()
        let content = (1...13).map { "- streamed line \($0)" }.joined(separator: "\n")
        let streaming = AgentMessage(id: id, role: .assistant, content: content, isStreaming: true)
        let cell = AgentNativeMessageCell(message: streaming, theme: .zedDark)

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
}
