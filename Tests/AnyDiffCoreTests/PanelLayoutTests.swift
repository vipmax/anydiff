import XCTest
import SwiftUI
@testable import AnyDiffCore
@testable import AnyDiffUI

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

    func testSplitViewDividersAndToolbarAlignment() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        let windowToolbar = NSToolbar(identifier: "AnyDiffWindowToolbar")
        windowToolbar.allowsUserCustomization = false
        windowToolbar.autosavesConfiguration = false
        window.toolbar = windowToolbar

        let hosting = NSHostingView(rootView: MainWindowView(initialPath: nil))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        alignSidebarToggleLeading(in: window)
        updateSplitViewDividers(in: window)

        guard let tb = window.toolbar else {
            XCTFail("Window must have a toolbar")
            return
        }

        // Verify sidebar toggle button is at index 0
        XCTAssertTrue(tb.items.first?.itemIdentifier.rawValue.contains("toggleSidebar") == true, "Sidebar toggle must be the first toolbar item")

        // Verify tracking separator is present
        let trackingItem = tb.items.first(where: { $0 is NSTrackingSeparatorToolbarItem })
        XCTAssertNotNil(trackingItem, "Tracking separator toolbar item must be present")

        // Verify split dividers exist and have separator layers configured
        var dividerCount = 0
        func checkDividers(in view: NSView) {
            if String(describing: type(of: view)).contains("Divider") {
                dividerCount += 1
                let hasSeparatorLayer = view.layer?.sublayers?.contains(where: {
                    $0.backgroundColor != nil && $0.opacity > 0 && !$0.isHidden
                }) == true
                XCTAssertTrue(hasSeparatorLayer, "Divider view must have an active visible separator layer")
            }
            for sub in view.subviews { checkDividers(in: sub) }
        }
        if let cv = window.contentView {
            checkDividers(in: cv)
        }
        XCTAssertEqual(dividerCount, 2, "Both left and right split dividers must be present")
    }

    func testThemePanelDividerColor() {
        // Vesper should have custom coal black separator
        XCTAssertEqual(Theme.vesper.panelDivider, NSColor.black)

        // Other themes without explicit panelDivider fall back to NSColor.separatorColor
        XCTAssertEqual(Theme.githubDark.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.tokyoNight.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.macOSLight.panelDivider, NSColor.separatorColor)
    }
}
