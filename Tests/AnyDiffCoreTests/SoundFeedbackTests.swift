import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class SoundFeedbackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SoundFeedback.soundEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SoundFeedback.soundEnabledKey)
        super.tearDown()
    }

    func testSoundFeedbackDefaultEnabled() {
        XCTAssertTrue(SoundFeedback.isEnabled)
    }

    func testSoundFeedbackToggle() {
        SoundFeedback.isEnabled = false
        XCTAssertFalse(SoundFeedback.isEnabled)

        SoundFeedback.isEnabled = true
        XCTAssertTrue(SoundFeedback.isEnabled)
    }

    func testSoundFeedbackPlayDoesNotCrash() {
        SoundFeedback.play(.completion)
        SoundFeedback.play(.error)
        SoundFeedback.play(.attention)
        SoundFeedback.play(.custom("Tink"))

        SoundFeedback.isEnabled = false
        SoundFeedback.play(.completion)
        SoundFeedback.play(.error)
    }

    func testSessionNotificationDefaultDisabledAndToggle() {
        let manager = ACPAgentSessionManager()
        let session = AgentSessionItem(manager: manager, isMock: false)

        // Default is disabled
        XCTAssertFalse(manager.isNotificationsEnabled)
        XCTAssertFalse(session.isNotificationsEnabled)

        // Toggle via session item
        session.isNotificationsEnabled = true
        XCTAssertTrue(manager.isNotificationsEnabled)
        XCTAssertTrue(session.isNotificationsEnabled)

        // Toggle via manager
        manager.isNotificationsEnabled = false
        XCTAssertFalse(session.isNotificationsEnabled)
        XCTAssertFalse(manager.isNotificationsEnabled)
    }

    func testSessionNotificationTurnCompletedEvent() {
        let manager = ACPAgentSessionManager()
        let session = AgentSessionItem(manager: manager, isMock: false)
        session.isNotificationsEnabled = true

        let expectation = expectation(description: "anyDiffAgentSessionTurnCompleted should fire")
        var receivedIsError: Bool?

        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("anyDiffAgentSessionTurnCompleted"),
            object: session,
            queue: .main
        ) { notification in
            receivedIsError = notification.userInfo?["isError"] as? Bool
            expectation.fulfill()
        }

        // Simulate agent turn: busy -> idle
        manager.status = .busy
        manager.status = .idle

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedIsError, false)
        NotificationCenter.default.removeObserver(observer)
    }

    func testSessionNotificationPermissionRequestedEvent() {
        let manager = ACPAgentSessionManager()
        let session = AgentSessionItem(manager: manager, isMock: false)
        session.isNotificationsEnabled = true

        let expectation = expectation(description: "anyDiffAgentPermissionRequested should fire")
        var receivedTitle: String?

        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("anyDiffAgentPermissionRequested"),
            object: session,
            queue: .main
        ) { notification in
            receivedTitle = notification.userInfo?["title"] as? String
            expectation.fulfill()
        }

        manager.pendingPermission = AgentPermissionRequest(
            requestId: .integer(1),
            sessionId: "session-1",
            toolCallId: "tool-1",
            title: "Execute bash command: git status",
            options: []
        )

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedTitle, "Execute bash command: git status")
        XCTAssertEqual(session.statusDescription, "Permission required")
        NotificationCenter.default.removeObserver(observer)
    }
}
