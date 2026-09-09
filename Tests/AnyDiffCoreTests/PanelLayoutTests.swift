import XCTest
@testable import AnyDiffCore

@MainActor
final class PanelLayoutTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test_anydiff_panel_layout_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultLayout() {
        let manager = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        XCTAssertEqual(manager.leftContent, .changes)
        XCTAssertEqual(manager.centerContent, .editor)
        XCTAssertEqual(manager.rightContent, .agent)
        XCTAssertTrue(manager.isRightPanelOpen)
    }

    func testAssignMovesContentFromPreviousSlot() {
        let manager = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        XCTAssertEqual(manager.slot(for: .editor), .center)

        // Assign editor to left slot
        manager.assign(.editor, to: .left)

        // Left now has editor, center was vacated
        XCTAssertEqual(manager.leftContent, .editor)
        XCTAssertNil(manager.centerContent)
        XCTAssertEqual(manager.rightContent, .agent)
        XCTAssertEqual(manager.slot(for: .editor), .left)
    }

    func testClearSlot() {
        let manager = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        XCTAssertEqual(manager.leftContent, .changes)

        manager.clear(.left)
        XCTAssertNil(manager.leftContent)
        XCTAssertEqual(manager.centerContent, .editor)
        XCTAssertEqual(manager.rightContent, .agent)
    }

    func testResetToDefaults() {
        let manager = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        manager.clear(.left)
        manager.clear(.center)
        manager.clear(.right)
        manager.isRightPanelOpen = false

        XCTAssertNil(manager.leftContent)
        XCTAssertNil(manager.centerContent)
        XCTAssertNil(manager.rightContent)
        XCTAssertFalse(manager.isRightPanelOpen)

        manager.resetToDefaults()
        XCTAssertEqual(manager.leftContent, .changes)
        XCTAssertEqual(manager.centerContent, .editor)
        XCTAssertEqual(manager.rightContent, .agent)
        XCTAssertTrue(manager.isRightPanelOpen)
    }

    func testPersistence() {
        let manager1 = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        manager1.assign(.agent, to: .left)
        manager1.clear(.right)
        manager1.isRightPanelOpen = false

        // Load into a new manager using the same defaults
        let manager2 = PanelLayoutManager(defaults: testDefaults, loadPersisted: true)
        XCTAssertEqual(manager2.leftContent, .agent)
        XCTAssertEqual(manager2.centerContent, .editor)
        XCTAssertNil(manager2.rightContent)
        XCTAssertFalse(manager2.isRightPanelOpen)
    }

    func testRightPanelOpenAndToggle() {
        let manager = PanelLayoutManager(defaults: testDefaults, loadPersisted: false)
        XCTAssertTrue(manager.isRightPanelOpen)

        manager.toggleRightPanel()
        XCTAssertFalse(manager.isRightPanelOpen)

        manager.toggleRightPanel()
        XCTAssertTrue(manager.isRightPanelOpen)
    }
}
