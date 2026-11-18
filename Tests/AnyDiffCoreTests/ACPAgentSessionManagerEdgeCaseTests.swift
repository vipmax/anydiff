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
}
