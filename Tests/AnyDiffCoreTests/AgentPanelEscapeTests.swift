import XCTest
import AppKit
@testable import AnyDiffCore
@testable import AnyDiffUI

@MainActor
final class AgentPanelEscapeTests: XCTestCase {

    private func makeEscapeEvent(
        for window: NSWindow,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
    }

    private func makeOtherKeyEvent(
        for window: NSWindow,
        keyCode: UInt16 = 0,
        character: String = "a"
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func createTestHarness() -> (NSWindow, AgentPanelEscapeHostView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostView = AgentPanelEscapeHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = hostView
        window.makeFirstResponder(hostView)
        return (window, hostView)
    }

    func testCommandEscapeReturnsToStartScreen() throws {
        let (window, hostView) = createTestHarness()

        var returnedToStartScreen = false
        var stoppedAgent = false

        hostView.onReturnToStartScreen = { returnedToStartScreen = true }
        hostView.onStopAgent = { stoppedAgent = true }

        let cmdEsc = try makeEscapeEvent(for: window, modifierFlags: [.command])
        let result = hostView.handleKeyEvent(cmdEsc)

        XCTAssertNil(result, "Command+Esc should be swallowed")
        XCTAssertTrue(returnedToStartScreen, "Command+Esc must trigger onReturnToStartScreen")
        XCTAssertFalse(stoppedAgent, "Command+Esc must NOT trigger onStopAgent")
        XCTAssertNil(hostView.lastEscapeUptime, "lastEscapeUptime must be reset")
    }

    func testSingleEscapeClearsSelectionsAndStoresUptime() throws {
        let (window, hostView) = createTestHarness()

        var returnedToStartScreen = false
        var stoppedAgent = false

        hostView.onReturnToStartScreen = { returnedToStartScreen = true }
        hostView.onStopAgent = { stoppedAgent = true }

        let singleEsc = try makeEscapeEvent(for: window)
        let result = hostView.handleKeyEvent(singleEsc)

        XCTAssertNil(result, "Single Esc should be swallowed")
        XCTAssertFalse(returnedToStartScreen, "Single Esc must NOT return to start screen")
        XCTAssertFalse(stoppedAgent, "Single Esc must NOT stop agent")
        XCTAssertNotNil(hostView.lastEscapeUptime, "Single Esc must store lastEscapeUptime")
    }

    func testDoubleEscapeWithinThresholdStopsAgent() throws {
        let (window, hostView) = createTestHarness()

        var returnedToStartScreen = false
        var stoppedAgentCount = 0

        hostView.onReturnToStartScreen = { returnedToStartScreen = true }
        hostView.onStopAgent = { stoppedAgentCount += 1 }

        let firstEsc = try makeEscapeEvent(for: window)
        _ = hostView.handleKeyEvent(firstEsc)
        XCTAssertEqual(stoppedAgentCount, 0)

        let secondEsc = try makeEscapeEvent(for: window)
        let secondResult = hostView.handleKeyEvent(secondEsc)

        XCTAssertNil(secondResult, "Second Esc within threshold should be swallowed")
        XCTAssertEqual(stoppedAgentCount, 1, "Double Esc must trigger onStopAgent exactly once")
        XCTAssertFalse(returnedToStartScreen, "Double Esc must NOT return to start screen")
        XCTAssertNil(hostView.lastEscapeUptime, "Double Esc must reset lastEscapeUptime")
    }

    func testDoubleEscapeAfterThresholdDoesNotStopAgent() throws {
        let (window, hostView) = createTestHarness()

        var stoppedAgentCount = 0
        hostView.onStopAgent = { stoppedAgentCount += 1 }

        // Simulate an old escape press past the threshold
        hostView.lastEscapeUptime = ProcessInfo.processInfo.systemUptime - 1.5

        let secondEsc = try makeEscapeEvent(for: window)
        _ = hostView.handleKeyEvent(secondEsc)

        XCTAssertEqual(stoppedAgentCount, 0, "Escape after threshold expired must not trigger stop")
        XCTAssertNotNil(hostView.lastEscapeUptime, "A new escape timestamp must be stored")
    }

    func testOtherKeyResetsEscapeChain() throws {
        let (window, hostView) = createTestHarness()

        hostView.lastEscapeUptime = ProcessInfo.processInfo.systemUptime

        let otherKey = try makeOtherKeyEvent(for: window)
        let result = hostView.handleKeyEvent(otherKey)

        XCTAssertNotNil(result, "Non-escape key should pass through")
        XCTAssertNil(hostView.lastEscapeUptime, "Non-escape key must reset lastEscapeUptime")
    }

    func testKeyIgnoredWhenModalPresented() throws {
        let (window, hostView) = createTestHarness()
        hostView.isModalPresented = true

        var returnedToStartScreen = false
        hostView.onReturnToStartScreen = { returnedToStartScreen = true }

        let cmdEsc = try makeEscapeEvent(for: window, modifierFlags: [.command])
        let result = hostView.handleKeyEvent(cmdEsc)

        XCTAssertNotNil(result, "Should not handle key when modal is presented")
        XCTAssertFalse(returnedToStartScreen)
    }
}
