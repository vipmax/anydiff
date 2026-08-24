import XCTest
@testable import AnyDiffUI

final class HapticFeedbackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: HapticFeedback.hapticsEnabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HapticFeedback.hapticsEnabledKey)
        super.tearDown()
    }

    func testHapticFeedbackDefaultEnabled() {
        XCTAssertTrue(HapticFeedback.isEnabled)
    }

    func testHapticFeedbackToggle() {
        HapticFeedback.isEnabled = false
        XCTAssertFalse(HapticFeedback.isEnabled)

        HapticFeedback.isEnabled = true
        XCTAssertTrue(HapticFeedback.isEnabled)
    }

    func testHapticFeedbackPerformDoesNotCrash() {
        // Calling perform with any pattern should succeed safely even in headless/test environments
        HapticFeedback.perform(.generic)
        HapticFeedback.perform(.alignment)
        HapticFeedback.perform(.levelChange)

        HapticFeedback.isEnabled = false
        HapticFeedback.perform(.generic)
        HapticFeedback.perform(.alignment)
        HapticFeedback.perform(.levelChange)
    }
}
