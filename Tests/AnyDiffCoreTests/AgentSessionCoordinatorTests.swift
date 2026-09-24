import XCTest
@testable import AnyDiffCore

final class AgentSessionCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AgentSessionCoordinator.isRightPanelOpenKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentSessionCoordinator.isRightPanelOpenKey)
        super.tearDown()
    }

#if DEBUG
    func testCoordinatorInitialStateWithoutAutoCreate() {
        let coordinator = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: false)
        XCTAssertEqual(coordinator.sessions.count, 0)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertNil(coordinator.activeSessionId)
    }

    func testCoordinatorInitialState() {
        let coordinator = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: true)
        XCTAssertEqual(coordinator.sessions.count, 1)
        XCTAssertEqual(coordinator.activeSession?.id, coordinator.activeSessionId)
        XCTAssertTrue(coordinator.isMockAgent)
        XCTAssertTrue(coordinator.isPanelOpen)
        XCTAssertEqual(coordinator.activeSession?.title, "Mock Session")
        XCTAssertEqual(coordinator.activeSession?.displaySessionId, "mock-1")
        XCTAssertEqual(coordinator.activeSession?.shortSessionId, "mock-1")
    }

    func testSessionItemSessionIdTracking() {
        let manager = AgentSessionManager()
        let session = AgentSessionItem(manager: manager, isMock: false)
        XCTAssertNil(session.displaySessionId)
        XCTAssertNil(session.shortSessionId)

        manager.currentSessionId = "0853a6d5-8baa-4c94-9ee6-f876a6e37c17"
        XCTAssertEqual(session.displaySessionId, "0853a6d5-8baa-4c94-9ee6-f876a6e37c17")
        XCTAssertEqual(session.shortSessionId, "0853a6d5")
    }
#endif

    func testCreateNewSessionPreservesPreviousSessionState() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let firstSession = coordinator.activeSession!

        // Send prompt in first session
        firstSession.manager.sendPrompt("Explain Myers diff", workingDirectory: "/tmp")
        XCTAssertFalse(firstSession.manager.messages.isEmpty)
        XCTAssertEqual(firstSession.manager.messages[0].content, "Explain Myers diff")

        // Create new session
        let secondSession = coordinator.createNewSession(workingDirectory: "/tmp")
        XCTAssertEqual(coordinator.sessions.count, 2)
        XCTAssertEqual(coordinator.activeSessionId, secondSession.id)

        // First session still exists and has its messages
        XCTAssertEqual(firstSession.manager.messages.count, coordinator.sessions[0].manager.messages.count)
        XCTAssertEqual(firstSession.manager.messages[0].content, "Explain Myers diff")

        // Second session is clean
        XCTAssertTrue(secondSession.manager.messages.isEmpty)
    }

    func testAutoTitleFromFirstUserMessage() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let session = coordinator.activeSession!

        XCTAssertEqual(session.title, "Session 1")

        // User sends a message
        session.manager.sendPrompt("Review these changes carefully for bugs", workingDirectory: "/tmp")

        let exp = expectation(description: "Title updates on main queue")
        DispatchQueue.main.async {
            XCTAssertEqual(session.title, "Review these changes carefully f…")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    #if DEBUG
    func testLiveAndMockGroupingAndCleanEmpty() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let live1 = coordinator.activeSession!
        live1.manager.sendPrompt("Live prompt", workingDirectory: "/tmp")

        let mock1 = coordinator.createNewSession(workingDirectory: "/tmp", preset: .mock)
        mock1.manager.sendPrompt("Mock prompt", workingDirectory: "/tmp")

        _ = coordinator.createNewSession(workingDirectory: "/tmp", preset: .codex)

        XCTAssertEqual(coordinator.liveSessions.count, 2)
        XCTAssertEqual(coordinator.mockSessions.count, 1)

        coordinator.selectSession(id: live1.id)
        XCTAssertFalse(coordinator.isMockAgent)

        // Clean empty sessions -> emptyLive should be removed
        coordinator.cleanEmptySessions()
        XCTAssertEqual(coordinator.liveSessions.count, 1)
        XCTAssertEqual(coordinator.mockSessions.count, 1)
    }
    #endif

    func testSelectPresetSwitchesActiveAgent() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        coordinator.selectPreset(.agy, workingDirectory: "/tmp")
        XCTAssertEqual(coordinator.selectedPresetId, "agy")
        XCTAssertEqual(coordinator.activeManager?.agentTitle, AgentPreset.agy.name)

        coordinator.selectPreset(.claude, workingDirectory: "/tmp")
        XCTAssertEqual(coordinator.selectedPresetId, "claude")
        XCTAssertEqual(coordinator.activeManager?.agentTitle, AgentPreset.claude.name)

        #if DEBUG
        coordinator.selectPreset(.mock, workingDirectory: "/tmp")
        XCTAssertTrue(coordinator.isMockAgent)
        #endif
    }

    func testSelectAndCloseSession() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let session1 = coordinator.activeSession!
        let session2 = coordinator.createNewSession(workingDirectory: "/tmp")
        let session3 = coordinator.createNewSession(workingDirectory: "/tmp")

        XCTAssertEqual(coordinator.sessions.count, 3)
        XCTAssertEqual(coordinator.activeSessionId, session3.id)

        // Switch to session 1
        coordinator.selectSession(id: session1.id)
        XCTAssertEqual(coordinator.activeSessionId, session1.id)

        // Close session 1 -> active should fallback to last remaining session
        coordinator.closeSession(id: session1.id)
        XCTAssertEqual(coordinator.sessions.count, 2)
        XCTAssertEqual(coordinator.activeSessionId, session3.id)

        // Close session 3
        coordinator.closeSession(id: session3.id)
        XCTAssertEqual(coordinator.sessions.count, 1)
        XCTAssertEqual(coordinator.activeSessionId, session2.id)

        // Close the only remaining session -> sets activeSessionId to nil (returns to start screen)
        coordinator.closeSession(id: session2.id)
        XCTAssertEqual(coordinator.sessions.count, 0)
        XCTAssertNil(coordinator.activeSessionId)
    }

    #if DEBUG
    func testToggleMockModeAndPanel() {
        let coordinator = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: true)
        XCTAssertTrue(coordinator.isMockAgent)

        coordinator.toggleMockMode(workingDirectory: "/tmp")
        XCTAssertFalse(coordinator.isMockAgent)

        XCTAssertTrue(coordinator.isPanelOpen)
        coordinator.togglePanel()
        XCTAssertFalse(coordinator.isPanelOpen)
    }

    func testPanelOpenStatePersistence() {
        UserDefaults.standard.removeObject(forKey: AgentSessionCoordinator.isPanelOpenKey)
        defer { UserDefaults.standard.removeObject(forKey: AgentSessionCoordinator.isPanelOpenKey) }

        // Initial default should be true
        let c1 = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: false)
        XCTAssertTrue(c1.isPanelOpen)

        // Toggle to false and verify persistence
        c1.togglePanel()
        XCTAssertFalse(c1.isPanelOpen)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: AgentSessionCoordinator.isPanelOpenKey), false)

        // New instance must restore false
        let c2 = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: false)
        XCTAssertFalse(c2.isPanelOpen)
        XCTAssertFalse(c2.isRightPanelOpen)

        // Toggle back to true
        c2.togglePanel()
        XCTAssertTrue(c2.isPanelOpen)
        XCTAssertTrue(c2.isRightPanelOpen)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: AgentSessionCoordinator.isRightPanelOpenKey), true)

        let c3 = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: false)
        XCTAssertTrue(c3.isPanelOpen)
        XCTAssertTrue(c3.isRightPanelOpen)
    }
    #endif

    func testBackgroundUnreadUpdatesTracking() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let session1 = coordinator.activeSession!
        session1.manager.sendPrompt("Prompt in session 1", workingDirectory: "/tmp")

        // Switch to session 2
        let session2 = coordinator.createNewSession(workingDirectory: "/tmp", preset: .codex)
        XCTAssertEqual(coordinator.activeSessionId, session2.id)
        XCTAssertFalse(session1.hasUnreadUpdates)
        XCTAssertFalse(coordinator.hasUnreadUpdates)

        // Session 1 receives assistant response in background
        session1.manager.messages.append(AgentMessage(role: .assistant, content: "Finished response from background"))

        let exp = expectation(description: "Unread update propagates")
        DispatchQueue.main.async {
            XCTAssertTrue(session1.hasUnreadUpdates)
            XCTAssertTrue(coordinator.hasUnreadUpdates)

            // Switch back to session 1 -> unread should clear
            coordinator.selectSession(id: session1.id)
            XCTAssertFalse(session1.hasUnreadUpdates)
            XCTAssertFalse(coordinator.hasUnreadUpdates)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testStartAndExitReviewMode() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        XCTAssertNil(coordinator.activeReviewSummary)

        let summary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
            AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10)
        ])

        coordinator.startReview(summary: summary)
        XCTAssertEqual(coordinator.activeReviewSummary, summary)
        XCTAssertEqual(coordinator.activeReviewSummary?.totalAdditions, 21)
        XCTAssertEqual(coordinator.activeReviewSummary?.totalDeletions, 14)
        XCTAssertEqual(coordinator.activeReviewSummary?.filePaths, [
            "Sources/AnyDiffUI/Agent/AgentInputView.swift",
            "Sources/AnyDiffUI/Agent/AgentPanelView.swift"
        ])

        coordinator.exitReview()
        XCTAssertNil(coordinator.activeReviewSummary)
    }

    func testAgentEditedFilesSummaryCalculations() {
        let item1 = AgentEditedFileItem(path: "Sources/AnyDiffCore/Syntax/Theme.swift", additions: 10, deletions: 2)
        XCTAssertEqual(item1.directory, "Sources/AnyDiffCore/Syntax/")
        XCTAssertEqual(item1.filename, "Theme.swift")

        let item2 = AgentEditedFileItem(path: "Package.swift", additions: 5, deletions: 0)
        XCTAssertEqual(item2.directory, "")
        XCTAssertEqual(item2.filename, "Package.swift")

        let summary = AgentEditedFilesSummary(files: [item1, item2])
        XCTAssertEqual(summary.totalAdditions, 15)
        XCTAssertEqual(summary.totalDeletions, 2)
        XCTAssertEqual(summary.displayTitle, "Edited 2 files")

        let singleSummary = AgentEditedFilesSummary(files: [item1])
        XCTAssertEqual(singleSummary.displayTitle, "Edited 1 file")
    }

    func testActiveReviewSnapshotIsIsolatedFromLiveEdits() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        let session = coordinator.activeSession!

        let initialSummary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "File1.swift", additions: 10, deletions: 2)
        ])

        // User enters review mode
        coordinator.startReview(summary: initialSummary)
        XCTAssertEqual(coordinator.activeReviewSummary?.files.count, 1)

        // Agent modifies another file during live streaming
        let updatedSummary = AgentEditedFilesSummary(files: [
            AgentEditedFileItem(path: "File1.swift", additions: 10, deletions: 2),
            AgentEditedFileItem(path: "File2.swift", additions: 5, deletions: 1)
        ])

        let exp = expectation(description: "activeReviewSummary remains isolated")
        session.manager.liveEditedSummary = updatedSummary

        DispatchQueue.main.async {
            // The review snapshot must NOT be modified by background live edits
            XCTAssertEqual(coordinator.activeReviewSummary?.files.count, 1)
            XCTAssertEqual(coordinator.activeReviewSummary?.totalAdditions, 10)
            XCTAssertEqual(coordinator.activeReviewSummary?.totalDeletions, 2)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testSnapshotTurnDiffCalculation() throws {
        try requireIntegrationTestsEnabled()

        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: "/tmp")
        XCTAssertNotNil(snapshot)

        let summaryWithHash = AgentEditedFilesSummary(
            files: [AgentEditedFileItem(path: "Sources/AnyDiff/App.swift", additions: 5, deletions: 1)],
            baseCommitHash: "abc1234",
            rawDiffData: Data("diff --git a/App.swift b/App.swift".utf8)
        )
        XCTAssertEqual(summaryWithHash.baseCommitHash, "abc1234")
        XCTAssertNotNil(summaryWithHash.rawDiffData)
        XCTAssertEqual(summaryWithHash.totalAdditions, 5)
        XCTAssertEqual(summaryWithHash.totalDeletions, 1)

        // If no files changed, computeTurnSummary returns nil
        let (turnSum, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: "/tmp", snapshot: snapshot)
        XCTAssertNil(turnSum)
    }

    func testPreExistingDirtyWorkingTreeDoesNotAttributeToTurn() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anydiff-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func runProcess(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }

        runProcess(["init"])
        runProcess(["config", "user.name", "Test"])
        runProcess(["config", "user.email", "test@example.com"])

        let file1URL = tempDir.appendingPathComponent("existing_file.txt")
        try "initial content\n".write(to: file1URL, atomically: true, encoding: .utf8)
        runProcess(["add", "existing_file.txt"])
        runProcess(["commit", "-m", "Initial commit"])

        // Simulate 10 pre-existing modified files in the working directory before turn starts
        for i in 1...10 {
            let fileURL = tempDir.appendingPathComponent("dirty_\(i).txt")
            try "staged content \(i)\n".write(to: fileURL, atomically: true, encoding: .utf8)
            runProcess(["add", "dirty_\(i).txt"])
        }

        // 1. Capture snapshot before turn
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: tempDir.path)
        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertNotNil(snapshot.baseCommitHash)

        // 2. Turn 1: Agent does not edit any files (e.g. only runs read-only commands)
        let (turn1Summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snapshot)
        // MUST BE NIL — pre-existing 10 files should NOT be attributed to the agent!
        XCTAssertNil(turn1Summary)

        // 3. Turn 2: Agent edits ONLY 1 file (turn_edit.txt)
        let agentFileURL = tempDir.appendingPathComponent("turn_edit.txt")
        try "agent line 1\nagent line 2\n".write(to: agentFileURL, atomically: true, encoding: .utf8)

        let (turn2Summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snapshot)
        XCTAssertNotNil(turn2Summary)
        // MUST ONLY contain turn_edit.txt, NOT the 10 pre-existing dirty files!
        XCTAssertEqual(turn2Summary?.files.count, 1)
        XCTAssertEqual(turn2Summary?.files.first?.path, "turn_edit.txt")
        XCTAssertEqual(turn2Summary?.displayTitle, "Edited 1 file")
    }

    func testPreExistingUntrackedFileCommittedDuringTurnDoesNotAttributeToTurn() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anydiff-git-untracked-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func runProcess(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", tempDir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }

        runProcess(["init"])
        runProcess(["config", "user.name", "Test"])
        runProcess(["config", "user.email", "test@example.com"])

        let file1URL = tempDir.appendingPathComponent("existing_file.txt")
        try "initial content\n".write(to: file1URL, atomically: true, encoding: .utf8)
        runProcess(["add", "existing_file.txt"])
        runProcess(["commit", "-m", "Initial commit"])

        // 1. Simulate pre-existing dirty tracked file and pre-existing untracked file
        try "modified existing content\n".write(to: file1URL, atomically: true, encoding: .utf8)
        runProcess(["add", "existing_file.txt"])

        let untrackedURL = tempDir.appendingPathComponent("AgentMarkdownParserTests.swift")
        try "class AgentMarkdownParserTests {}\n".write(to: untrackedURL, atomically: true, encoding: .utf8)

        // 2. Capture snapshot before turn
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: tempDir.path)
        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertTrue(snapshot.untrackedFiles.contains("AgentMarkdownParserTests.swift"))

        // 3. Turn 1: Agent commits the untracked file without modifying its contents
        runProcess(["add", "AgentMarkdownParserTests.swift"])
        runProcess(["commit", "-m", "Commit pre-existing untracked file"])

        let (turn1Summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snapshot)
        // MUST BE NIL — committing a pre-existing untracked file should NOT be attributed to the turn!
        XCTAssertNil(turn1Summary)

        // 4. Turn 2: Agent edits an actual file during this turn
        let agentFileURL = tempDir.appendingPathComponent("turn_edit.txt")
        try "agent line 1\nagent line 2\n".write(to: agentFileURL, atomically: true, encoding: .utf8)

        let (turn2Summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snapshot)
        XCTAssertNotNil(turn2Summary)
        // MUST ONLY contain turn_edit.txt, NOT AgentMarkdownParserTests.swift or existing_file.txt!
        XCTAssertEqual(turn2Summary?.files.count, 1)
        XCTAssertEqual(turn2Summary?.files.first?.path, "turn_edit.txt")
        XCTAssertEqual(turn2Summary?.displayTitle, "Edited 1 file")
    }

    func testPreExistingUntrackedFileModifiedDuringTurnProducesExactDiffAndRevertsCleanly() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("anydiff_untracked_turn_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func runProcess(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.currentDirectoryURL = tempDir
            p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@test.com"] + args
            try? p.run()
            p.waitUntilExit()
        }

        runProcess(["init"])
        let trackedURL = tempDir.appendingPathComponent("tracked.txt")
        try "initial tracked\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        runProcess(["add", "tracked.txt"])
        runProcess(["commit", "-m", "Initial commit"])

        // 1. Create a 100-line pre-existing untracked file
        let untrackedURL = tempDir.appendingPathComponent("untracked.txt")
        var originalLines: [String] = []
        for i in 1...100 {
            originalLines.append("Original Line \(i)")
        }
        let originalContent = originalLines.joined(separator: "\n") + "\n"
        try originalContent.write(to: untrackedURL, atomically: true, encoding: .utf8)

        // 2. Capture snapshot before turn starts
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: tempDir.path)
        XCTAssertTrue(snapshot.isGitRepository)
        XCTAssertTrue(snapshot.untrackedFiles.contains("untracked.txt"))
        XCTAssertNotNil(snapshot.untrackedBlobHashes["untracked.txt"])

        // 3. During turn: Agent modifies line 50 and adds 2 lines (3 additions, 1 deletion)
        Thread.sleep(forTimeInterval: 0.6)
        var modifiedLines = originalLines
        modifiedLines[49] = "Modified Line 50 by Agent"
        modifiedLines.insert("New Line A", at: 50)
        modifiedLines.insert("New Line B", at: 51)
        let modifiedContent = modifiedLines.joined(separator: "\n") + "\n"
        try modifiedContent.write(to: untrackedURL, atomically: true, encoding: .utf8)

        // 4. Compute turn summary
        let (turnSummary, rawDiffData) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snapshot)
        XCTAssertNotNil(turnSummary)
        guard var summary = turnSummary else { return }

        // Must show EXACT diff stats, NOT the entire file length (102 lines)!
        XCTAssertEqual(summary.files.count, 1)
        XCTAssertEqual(summary.files.first?.path, "untracked.txt")
        XCTAssertEqual(summary.files.first?.additions, 3)
        XCTAssertEqual(summary.files.first?.deletions, 1)

        // Raw unified diff must be generated for MultiBuffer
        XCTAssertNotNil(rawDiffData)
        let diffStr = String(data: rawDiffData ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(diffStr.contains("diff --git a/untracked.txt b/untracked.txt"))
        XCTAssertTrue(diffStr.contains("+Modified Line 50 by Agent"))

        // 5. Test Revert: Untracked file must be restored back to exact original content
        let revertSuccess = AgentTurnRollbackService.revertTurn(workingDirectory: tempDir.path, summary: &summary)
        XCTAssertTrue(revertSuccess)
        let revertedContent = try String(contentsOf: untrackedURL, encoding: .utf8)
        XCTAssertEqual(revertedContent, originalContent)

        // 6. Test Restore (Redo): Untracked file must be restored back to modified content
        let restoreSuccess = AgentTurnRollbackService.restoreTurn(workingDirectory: tempDir.path, summary: summary)
        XCTAssertTrue(restoreSuccess)
        let restoredContent = try String(contentsOf: untrackedURL, encoding: .utf8)
        XCTAssertEqual(restoredContent, modifiedContent)
    }

    func testMultiTurnUntrackedFileModificationsUndoRedoSequence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("anydiff_multiturn_untracked_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func runProcess(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.currentDirectoryURL = tempDir
            p.arguments = ["-c", "user.name=Test", "-c", "user.email=test@test.com"] + args
            try? p.run()
            p.waitUntilExit()
        }

        runProcess(["init"])
        let trackedURL = tempDir.appendingPathComponent("tracked.txt")
        try "initial\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        runProcess(["add", "tracked.txt"])
        runProcess(["commit", "-m", "Initial commit"])

        let untrackedURL = tempDir.appendingPathComponent("untracked.swift")
        let v0Content = "// Version 0: original untracked content\nlet initial = true\n"
        try v0Content.write(to: untrackedURL, atomically: true, encoding: .utf8)

        // --- Turn 1 ---
        let snap1 = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: tempDir.path)
        XCTAssertEqual(snap1.untrackedFiles, ["untracked.swift"])

        Thread.sleep(forTimeInterval: 0.6)
        let v1Content = "// Version 1: after Turn 1\nlet initial = true\nfunc turnOneFeature() {}\n"
        try v1Content.write(to: untrackedURL, atomically: true, encoding: .utf8)

        let (t1Sum, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snap1)
        XCTAssertNotNil(t1Sum)
        guard var summary1 = t1Sum else { return }
        XCTAssertEqual(summary1.files.first?.path, "untracked.swift")

        // --- Turn 2 ---
        let snap2 = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: tempDir.path)
        XCTAssertEqual(snap2.untrackedFiles, ["untracked.swift"])

        Thread.sleep(forTimeInterval: 0.6)
        let v2Content = "// Version 2: after Turn 2\nlet initial = true\nfunc turnOneFeature() {}\nfunc turnTwoFeature() {}\n"
        try v2Content.write(to: untrackedURL, atomically: true, encoding: .utf8)

        let (t2Sum, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: tempDir.path, snapshot: snap2)
        XCTAssertNotNil(t2Sum)
        guard var summary2 = t2Sum else { return }
        XCTAssertEqual(summary2.files.first?.path, "untracked.swift")

        // Verify current state on disk is V2
        XCTAssertEqual(try String(contentsOf: untrackedURL, encoding: .utf8), v2Content)

        // 1. Revert Turn 2 -> Must restore intermediate state V1!
        let rev2 = AgentTurnRollbackService.revertTurn(workingDirectory: tempDir.path, summary: &summary2)
        XCTAssertTrue(rev2)
        XCTAssertEqual(try String(contentsOf: untrackedURL, encoding: .utf8), v1Content)

        // 2. Revert Turn 1 -> Must restore initial state V0!
        let rev1 = AgentTurnRollbackService.revertTurn(workingDirectory: tempDir.path, summary: &summary1)
        XCTAssertTrue(rev1)
        XCTAssertEqual(try String(contentsOf: untrackedURL, encoding: .utf8), v0Content)

        // 3. Restore (Redo) Turn 1 -> Must restore state V1!
        let rest1 = AgentTurnRollbackService.restoreTurn(workingDirectory: tempDir.path, summary: summary1)
        XCTAssertTrue(rest1)
        XCTAssertEqual(try String(contentsOf: untrackedURL, encoding: .utf8), v1Content)

        // 4. Restore (Redo) Turn 2 -> Must restore state V2!
        let rest2 = AgentTurnRollbackService.restoreTurn(workingDirectory: tempDir.path, summary: summary2)
        XCTAssertTrue(rest2)
        XCTAssertEqual(try String(contentsOf: untrackedURL, encoding: .utf8), v2Content)
    }

    func testToolCallItemCreateEditedFilesSummary() {
        let editTool = ToolCallItem(
            toolName: "replace_file_content",
            path: "Sources/AnyDiff/App.swift",
            oldContent: "let a = 1\nlet b = 2",
            newContent: "let a = 10\nlet b = 20\nlet c = 30",
            status: .completed
        )

        let summary = editTool.createEditedFilesSummary()
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.files.count, 1)
        XCTAssertEqual(summary?.files.first?.path, "Sources/AnyDiff/App.swift")
        XCTAssertEqual(summary?.totalAdditions, 3)
        XCTAssertEqual(summary?.totalDeletions, 2)
        XCTAssertNotNil(summary?.rawDiffData)
        let diffText = String(data: summary!.rawDiffData!, encoding: .utf8)!
        XCTAssertTrue(diffText.contains("diff --git a/Sources/AnyDiff/App.swift b/Sources/AnyDiff/App.swift"))
        XCTAssertTrue(diffText.contains("+let c = 30"))
    }

    func testCapturePreTurnSnapshotAsyncNonGit() async {
        let snapshot = await AgentGitChangesDetector.capturePreTurnSnapshotAsync(workingDirectory: "/nonexistent/path")
        XCTAssertFalse(snapshot.isGitRepository)

        let (summary, rawData) = await AgentGitChangesDetector.computeTurnSummaryAsync(workingDirectory: "/nonexistent/path", snapshot: snapshot)
        XCTAssertNil(summary)
        XCTAssertNil(rawData)
    }

    func testDraftPromptAndAttachmentsPreservedAcrossSessionSwitchesAndStartScreen() {
        let coordinator = AgentSessionCoordinator(isMockAgent: false, autoCreateSession: true)
        guard let session1 = coordinator.activeSession else {
            XCTFail("Expected initial active session")
            return
        }

        // Initially empty
        XCTAssertEqual(session1.draftPrompt, "")
        XCTAssertEqual(session1.draftAttachments.count, 0)

        // User writes draft in session 1
        session1.draftPrompt = "Hello from agent 1 draft"
        let attachment1 = AgentImageAttachment(id: UUID(), mimeType: "image/png", filename: "screenshot1.png")
        session1.draftAttachments = [attachment1]

        // User opens start screen ("Choose agents")
        coordinator.openStartScreen()
        XCTAssertTrue(coordinator.showStartScreen)
        XCTAssertEqual(coordinator.activeSession?.draftPrompt, "Hello from agent 1 draft")
        XCTAssertEqual(coordinator.activeSession?.draftAttachments.count, 1)

        // User creates/selects session 2
        let session2 = coordinator.createNewSession(workingDirectory: "/tmp")
        coordinator.selectSession(id: session2.id)
        XCTAssertFalse(coordinator.showStartScreen)
        XCTAssertEqual(coordinator.activeSessionId, session2.id)

        // Session 2 has its own empty draft
        XCTAssertEqual(session2.draftPrompt, "")
        XCTAssertEqual(session2.draftAttachments.count, 0)

        // User writes draft in session 2
        session2.draftPrompt = "Draft for agent 2"

        // User switches back to session 1 ("Back to chat" or selecting session 1)
        coordinator.selectSession(id: session1.id)
        XCTAssertEqual(coordinator.activeSessionId, session1.id)
        XCTAssertEqual(coordinator.activeSession?.draftPrompt, "Hello from agent 1 draft")
        XCTAssertEqual(coordinator.activeSession?.draftAttachments.first?.filename, "screenshot1.png")

        // Switching back to session 2 restores session 2 draft
        coordinator.selectSession(id: session2.id)
        XCTAssertEqual(coordinator.activeSession?.draftPrompt, "Draft for agent 2")
        XCTAssertEqual(coordinator.activeSession?.draftAttachments.count, 0)

        // Clearing session 1 resets its draft
        session1.manager.clearSession()
        XCTAssertEqual(session1.draftPrompt, "")
        XCTAssertEqual(session1.draftAttachments.count, 0)
        // Session 2 draft is untouched
        XCTAssertEqual(session2.draftPrompt, "Draft for agent 2")
    }
}

