import XCTest
@testable import AnyDiffCore

final class AgentSessionCoordinatorTests: XCTestCase {
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
}
