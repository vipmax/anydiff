import XCTest
@testable import AnyDiffCore

final class ACPAgentSessionManagerEdgeCaseTests: XCTestCase {
    func testFSWriteToolNamePreservedAcrossWriteToFileUpdateAndKeepsShortDiffStats() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Update file", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "write_1",
            toolName: "fs/write_text_file",
            toolInput: [
                "path": AnyCodableSendable("/repo/App.swift")
            ],
            status: "running"
        ), sessionId: "sess-1")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "write_1",
            toolName: "write_to_file",
            toolInput: [
                "path": AnyCodableSendable("/repo/App.swift"),
                "old_content": AnyCodableSendable("line1\nline2\nline3"),
                "new_content": AnyCodableSendable("line1\nchanged\nline3")
            ],
            status: "completed"
        ), sessionId: "sess-1")

        let exp = expectation(description: "fs/write_text_file preserved across write_to_file update")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].toolName, "fs/write_text_file")
            XCTAssertEqual(calls[0].shortToolName, "Edit")
            XCTAssertEqual(calls[0].diffStats?.additions, 1)
            XCTAssertEqual(calls[0].diffStats?.deletions, 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRelativePathDoesNotMatchNestedPathWhenWorkingDirectoryEmpty() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Update README", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "edit_root_readme",
            toolName: "write_to_file",
            toolInput: [
                "path": AnyCodableSendable("README.md"),
                "StartLine": AnyCodableSendable(1),
                "EndLine": AnyCodableSendable(3)
            ],
            status: "running"
        ), sessionId: "sess-1")

        manager.client(
            client,
            didExecuteFSWrite: "/repo/docs/README.md",
            oldContent: "old",
            newContent: "new"
        )

        let exp = expectation(description: "Relative README.md does not falsely match /repo/docs/README.md")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls[0].id, "edit_root_readme")
            XCTAssertEqual(calls[0].path, "README.md")
            XCTAssertEqual(calls[0].startLine, 1)
            XCTAssertEqual(calls[0].endLine, 3)
            XCTAssertEqual(calls[1].path, "/repo/docs/README.md")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testToolCallUpdateResetsLineRangeWhenPathChanges() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Inspect files", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            toolCallId: "read_1",
            toolName: "view_file",
            toolInput: [
                "AbsolutePath": AnyCodableSendable("/repo/A.swift"),
                "StartLine": AnyCodableSendable(10),
                "EndLine": AnyCodableSendable(20)
            ],
            status: "running"
        ), sessionId: "sess-1")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "read_1",
            toolName: "view_file",
            toolInput: [
                "AbsolutePath": AnyCodableSendable("/repo/B.swift")
            ],
            status: "completed"
        ), sessionId: "sess-1")

        let exp = expectation(description: "Line range reset when path changes")
        DispatchQueue.main.async {
            let calls = manager.messages[1].toolCalls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].path, "/repo/B.swift")
            XCTAssertEqual(calls[0].displayTitle, "B.swift")
            XCTAssertNil(calls[0].startLine)
            XCTAssertNil(calls[0].endLine)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testCancelMidTurnFinalizesEditedFilesSummaryFromGitAndAllowsRevert() async throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_cancel_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let fileURL = repoDir.appendingPathComponent("App.swift")
        try "let v = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        func runGit(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repoDir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
        }

        try runGit(["init"])
        try runGit(["add", "."])
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Init"])

        let snapshot = await AgentGitChangesDetector.capturePreTurnSnapshotAsync(workingDirectory: repoDir.path)

        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let assistantId = UUID()
        manager.currentSessionId = "sess-cancel-1"
        manager.currentWorkingDirectory = repoDir.path
        manager.activeTurnWorkingDirectory = repoDir.path
        manager.preTurnSnapshot = snapshot
        manager.currentStreamMessageId = assistantId
        manager.status = .busy
        manager.messages = [
            AgentMessage(role: .user, content: "Update App.swift"),
            AgentMessage(
                id: assistantId,
                role: .assistant,
                content: "Editing...",
                toolCalls: [
                    ToolCallItem(id: "t1", toolName: "fs/write_text_file", path: fileURL.path, status: .running)
                ],
                isStreaming: true
            )
        ]

        // Simulate file edit made before user pressed Stop (even before liveEditedSummary updated)
        try "let v = 2\n".write(to: fileURL, atomically: true, encoding: .utf8)

        manager.cancel()

        // Wait for cancel Task + computeTurnSummaryAsync to attach summary
        let deadline = Date().addingTimeInterval(3.0)
        while manager.messages[1].editedFilesSummary == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(manager.status, .idle)
        XCTAssertNil(manager.liveEditedSummary)
        XCTAssertFalse(manager.messages[1].isStreaming)
        XCTAssertEqual(manager.messages[1].toolCalls.first?.status, .completed)

        let summary = try XCTUnwrap(manager.messages[1].editedFilesSummary)
        XCTAssertEqual(summary.files.map(\.path), ["App.swift"])

        let reverted = manager.revertTurn(summary: summary, workingDirectory: repoDir.path)
        XCTAssertTrue(reverted)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "let v = 1\n")
        XCTAssertEqual(manager.messages[1].editedFilesSummary?.isReverted, true)
    }

    @MainActor
    func testCancelPreservesLiveEditedSummaryImmediatelyOnMessage() async throws {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let assistantId = UUID()
        let liveSummary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "Sources/Foo.swift", additions: 3, deletions: 1)
        ])

        manager.currentSessionId = "sess-cancel-2"
        manager.currentWorkingDirectory = NSTemporaryDirectory()
        manager.currentStreamMessageId = assistantId
        manager.status = .busy
        manager.liveEditedSummary = liveSummary
        manager.messages = [
            AgentMessage(role: .user, content: "Edit Foo"),
            AgentMessage(
                id: assistantId,
                role: .assistant,
                content: "Working...",
                toolCalls: [
                    ToolCallItem(id: "t1", toolName: "edit_file", path: "Sources/Foo.swift", status: .running)
                ],
                isStreaming: true
            )
        ]

        manager.cancel()

        let deadline = Date().addingTimeInterval(1.0)
        while manager.status == .busy && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(manager.status, .idle)
        XCTAssertNil(manager.liveEditedSummary)
        XCTAssertFalse(manager.messages[1].isStreaming)
        XCTAssertEqual(manager.messages[1].editedFilesSummary, liveSummary)
    }

    @MainActor
    func testNotifyFileSystemChangedUpdatesLiveEditedSummaryDuringActiveTurn() async throws {
        let repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_watcher_live_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        let scriptURL = repoDir.appendingPathComponent("script.py")
        try "print('v1')\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        func runGit(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repoDir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
        }

        try runGit(["init"])
        try runGit(["add", "."])
        try runGit(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Init"])

        let snapshot = await AgentGitChangesDetector.capturePreTurnSnapshotAsync(workingDirectory: repoDir.path)

        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let assistantId = UUID()
        manager.currentSessionId = "sess-watch-1"
        manager.currentWorkingDirectory = repoDir.path
        manager.activeTurnWorkingDirectory = repoDir.path
        manager.preTurnSnapshot = snapshot
        manager.currentStreamMessageId = assistantId
        manager.status = .busy
        manager.messages = [
            AgentMessage(role: .user, content: "Edit script.py via python"),
            AgentMessage(
                id: assistantId,
                role: .assistant,
                content: "Running python...",
                toolCalls: [
                    ToolCallItem(id: "t1", toolName: "run_command", command: "python3 update.py", status: .running)
                ],
                isStreaming: true
            )
        ]

        // Simulate external modification on disk (e.g., via python script) without fs/write_text_file
        try "print('v2')\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        manager.notifyFileSystemChanged()

        let deadline = Date().addingTimeInterval(3.0)
        while manager.liveEditedSummary == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let liveSummary = try XCTUnwrap(manager.liveEditedSummary)
        XCTAssertEqual(liveSummary.files.map(\.path), ["script.py"])
        XCTAssertEqual(liveSummary.totalAdditions, 1)
        XCTAssertEqual(liveSummary.totalDeletions, 1)
    }

    func testFSWriteArrivingBeforeToolCallNotificationRebindsWithoutDuplicating() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Fix image copy", workingDirectory: NSTemporaryDirectory())

        manager.client(
            client,
            didExecuteFSWrite: "/repo/AgentZoomableImageView.swift",
            oldContent: "old",
            newContent: "new"
        )

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            kind: "edit",
            title: "Editing AgentZoomableImageView.swift",
            toolCallId: "call_8624246229449817513",
            toolName: "edit",
            toolInput: [
                "path": AnyCodableSendable("/repo/AgentZoomableImageView.swift"),
                "old_content": AnyCodableSendable("old"),
                "new_content": AnyCodableSendable("new")
            ],
            status: "in_progress",
            locations: [ACPToolCallLocation(path: "/repo/AgentZoomableImageView.swift", line: nil)]
        ), sessionId: "sess-1")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "call_8624246229449817513",
            status: "completed"
        ), sessionId: "sess-1")

        let exp = expectation(description: "Out-of-order fs/write_text_file and tool_call produce a single Edit card")
        DispatchQueue.main.async {
            let assistant = manager.messages[1]
            let calls = assistant.toolCalls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].id, "call_8624246229449817513")
            XCTAssertEqual(calls[0].toolName, "fs/write_text_file")
            XCTAssertEqual(calls[0].shortToolName, "Edit")
            XCTAssertEqual(calls[0].status, .completed)
            XCTAssertEqual(calls[0].oldContent, "old")
            XCTAssertEqual(calls[0].newContent, "new")
            XCTAssertEqual(assistant.orderedParts, [.toolCall("call_8624246229449817513")])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testConsecutiveFSWritesArrivingBeforeToolCallsRebindSeparatelyWithoutDuplicatingOrMerging() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Edit twice", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didExecuteFSWrite: "/repo/README.md", oldContent: "v1", newContent: "v2")
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            kind: "edit",
            toolCallId: "call_1",
            toolName: "edit",
            toolInput: [
                "path": AnyCodableSendable("/repo/README.md"),
                "old_content": AnyCodableSendable("v1"),
                "new_content": AnyCodableSendable("v2")
            ],
            status: "in_progress"
        ), sessionId: "sess-1")
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "call_1",
            status: "completed"
        ), sessionId: "sess-1")

        manager.client(client, didExecuteFSWrite: "/repo/README.md", oldContent: "v2", newContent: "v3")
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            kind: "edit",
            toolCallId: "call_2",
            toolName: "edit",
            toolInput: [
                "path": AnyCodableSendable("/repo/README.md"),
                "old_content": AnyCodableSendable("v2"),
                "new_content": AnyCodableSendable("v3")
            ],
            status: "in_progress"
        ), sessionId: "sess-1")
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "call_2",
            status: "completed"
        ), sessionId: "sess-1")

        let exp = expectation(description: "Consecutive out-of-order writes produce two distinct Edit items")
        DispatchQueue.main.async {
            let assistant = manager.messages[1]
            let calls = assistant.toolCalls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls.map(\.id), ["call_1", "call_2"])
            XCTAssertEqual(calls[0].oldContent, "v1")
            XCTAssertEqual(calls[0].newContent, "v2")
            XCTAssertEqual(calls[1].oldContent, "v2")
            XCTAssertEqual(calls[1].newContent, "v3")
            XCTAssertEqual(assistant.orderedParts, [.toolCall("call_1"), .toolCall("call_2")])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testFSReadArrivingBeforeToolCallNotificationRebindsWithoutDuplicating() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Inspect App.swift", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didExecuteTool: "fs/read_text_file", path: "/repo/App.swift", details: "Read 50 chars")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            kind: "read",
            toolCallId: "read_call_1",
            toolName: "read",
            toolInput: [
                "path": AnyCodableSendable("/repo/App.swift"),
                "StartLine": AnyCodableSendable(10),
                "EndLine": AnyCodableSendable(25)
            ],
            status: "in_progress",
            locations: [ACPToolCallLocation(path: "/repo/App.swift", line: 10)]
        ), sessionId: "sess-1")

        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call_update",
            toolCallId: "read_call_1",
            status: "completed"
        ), sessionId: "sess-1")

        let exp = expectation(description: "Out-of-order fs/read_text_file and tool_call produce a single Read card")
        DispatchQueue.main.async {
            let assistant = manager.messages[1]
            let calls = assistant.toolCalls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].id, "read_call_1")
            XCTAssertEqual(calls[0].shortToolName, "Read")
            XCTAssertEqual(calls[0].status, .completed)
            XCTAssertEqual(calls[0].startLine, 10)
            XCTAssertEqual(calls[0].endLine, 25)
            XCTAssertEqual(assistant.orderedParts, [.toolCall("read_call_1")])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testFSWriteForNewFileWithNilOldContentRebindsWhenToolCallSendsEmptyOldContent() {
        let cpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_edge_cp1_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cpDir) }
        let manager = ACPAgentSessionManager()
        manager.checkpointStore = AgentCheckpointStore(customDirectory: cpDir)
        let client = ACPClient()

        manager.sendPrompt("Create NewFile.swift", workingDirectory: NSTemporaryDirectory())

        manager.client(client, didExecuteFSWrite: "/repo/NewFile.swift", oldContent: nil, newContent: "print(1)\n")
        manager.client(client, didReceiveUpdate: ACPSessionUpdateContent(
            type: "tool_call",
            kind: "edit",
            toolCallId: "call_new",
            toolName: "edit",
            toolInput: [
                "path": AnyCodableSendable("/repo/NewFile.swift"),
                "old_content": AnyCodableSendable(""),
                "new_content": AnyCodableSendable("print(1)\n")
            ],
            status: "in_progress"
        ), sessionId: "sess-1")

        let exp = expectation(description: "New file synthetic write rebinds when tool_call sends empty old_content")
        DispatchQueue.main.async {
            let assistant = manager.messages[1]
            let calls = assistant.toolCalls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].id, "call_new")
            XCTAssertEqual(calls[0].newContent, "print(1)\n")
            XCTAssertEqual(assistant.orderedParts, [.toolCall("call_new")])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
