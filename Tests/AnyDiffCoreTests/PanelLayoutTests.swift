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

        updateSplitViewDividers(in: window)

        guard let tb = window.toolbar else {
            XCTFail("Window must have a toolbar")
            return
        }

        // Verify sidebar toggle button is present
        XCTAssertTrue(tb.items.contains(where: { $0.itemIdentifier.rawValue.contains("toggleSidebar") }), "Sidebar toggle item must be present in the toolbar")

        // Verify tracking separator is present
        let trackingItem = tb.items.first(where: { $0 is NSTrackingSeparatorToolbarItem })
        XCTAssertNotNil(trackingItem, "Tracking separator toolbar item must be present")

        // Verify split dividers exist and have separator layers configured
        var dividerCount = 0
        func checkDividers(in view: NSView) {
            let name = String(describing: type(of: view))
            let isSplitDivider = name.contains("SplitDivider") || (view.superview is NSSplitView && name.contains("Divider"))
            if isSplitDivider {
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
        XCTAssertGreaterThanOrEqual(dividerCount, 2, "Both left and right split dividers must be present")
    }

    func testTerminalPanelHeaderPositionInMainWindowView() {
        let testDefaults = UserDefaults(suiteName: "testTerminalPosition_\(UUID().uuidString)")!
        testDefaults.set("terminal", forKey: PanelLayoutManager.centerSlotKey)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        let windowToolbar = NSToolbar(identifier: "AnyDiffWindowToolbar")
        window.toolbar = windowToolbar

        let hosting = NSHostingView(rootView: MainWindowView(initialPath: nil))
        window.contentView = hosting
        window.layoutIfNeeded()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        // Find TerminalNSView inside window content
        func findTerminalView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("TerminalNSView") {
                return view
            }
            for sub in view.subviews {
                if let found = findTerminalView(in: sub) { return found }
            }
            return nil
        }

        // Print window hierarchy
        print("Looking for TerminalNSView...")
        if let termView = findTerminalView(in: hosting) {
            let pt = termView.convert(NSPoint.zero, to: nil)
            print("TerminalNSView window point:", pt, "height:", termView.frame.height)
            // In AppKit, y=0 is bottom, so top of terminal is pt.y + frame.height.
            // Window is 700 tall. If top padding 52 + header 28 is present,
            // top of terminal is 700 - 52 - 28 = 620.
            let topOfTerminal = pt.y + termView.frame.height
            print("Top of Terminal in window:", topOfTerminal)
            XCTAssertLessThanOrEqual(topOfTerminal, 630.0, "Terminal view must start below window toolbar and panel header")
        }
    }

    func testThemePanelDividerColor() {
        // Vesper should have custom coal black separator
        XCTAssertEqual(Theme.vesper.panelDivider, NSColor.black)

        // Other themes without explicit panelDivider fall back to NSColor.separatorColor
        XCTAssertEqual(Theme.githubDark.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.githubLight.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.tokyoNight.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.macOSLight.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.vscodeDarkPlus.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.vscodeLightModern.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.oneDarkPro.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.jetbrainsDarcula.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.intellijLight.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.xcodeDark.panelDivider, NSColor.separatorColor)
        XCTAssertEqual(Theme.xcodeLight.panelDivider, NSColor.separatorColor)
    }

    func testVSCodeThemesPaletteAndRegistration() {
        let ids = Set(Theme.allThemes.map(\.id))
        let expectedIds: [String] = [
            "github-light",
            "vscode-dark-plus",
            "vscode-light-modern",
            "one-dark-pro",
            "jetbrains-darcula",
            "intellij-light",
            "xcode-dark",
            "xcode-light",
            "catppuccin-mocha",
            "catppuccin-latte",
            "dracula",
            "monokai-pro",
            "nord",
            "gruvbox-dark",
            "gruvbox-light",
            "solarized-dark",
            "solarized-light",
            "rose-pine",
            "ayu-dark",
            "night-owl",
            "everforest-dark",
            "everforest-light",
            "matrix"
        ]
        for expectedId in expectedIds {
            XCTAssertTrue(ids.contains(expectedId), "Missing theme \(expectedId)")
        }
        XCTAssertFalse(ids.contains("vscode-dark-modern"))

        XCTAssertFalse(Theme.githubLight.isDark)
        XCTAssertTrue(Theme.vscodeDarkPlus.isDark)
        XCTAssertFalse(Theme.vscodeLightModern.isDark)
        XCTAssertTrue(Theme.oneDarkPro.isDark)
        XCTAssertTrue(Theme.jetbrainsDarcula.isDark)
        XCTAssertFalse(Theme.intellijLight.isDark)
        XCTAssertTrue(Theme.xcodeDark.isDark)
        XCTAssertFalse(Theme.xcodeLight.isDark)
        XCTAssertTrue(Theme.catppuccinMocha.isDark)
        XCTAssertFalse(Theme.catppuccinLatte.isDark)
        XCTAssertTrue(Theme.dracula.isDark)
        XCTAssertTrue(Theme.monokaiPro.isDark)
        XCTAssertTrue(Theme.nord.isDark)
        XCTAssertTrue(Theme.gruvboxDark.isDark)
        XCTAssertFalse(Theme.gruvboxLight.isDark)
        XCTAssertTrue(Theme.solarizedDark.isDark)
        XCTAssertFalse(Theme.solarizedLight.isDark)
        XCTAssertTrue(Theme.rosePine.isDark)
        XCTAssertTrue(Theme.ayuDark.isDark)
        XCTAssertTrue(Theme.nightOwl.isDark)
        XCTAssertTrue(Theme.everforestDark.isDark)
        XCTAssertFalse(Theme.everforestLight.isDark)
        XCTAssertTrue(Theme.matrix.isDark)

        for theme in Theme.allThemes {
            XCTAssertEqual(theme.focusColor, theme.accentColor, "Theme \(theme.id) focusColor should match accentColor")
        }
        XCTAssertEqual(Theme.zedDark.accentColor, Theme.zedDark.function)
        XCTAssertEqual(Theme.vesper.accentColor, Theme.vesper.function)
        XCTAssertEqual(Theme.matrix.accentColor, Theme.matrix.function)
        XCTAssertEqual(Theme.githubLight.accentColor, Theme.githubLight.diffModifiedGutter)
        XCTAssertEqual(Theme.vscodeDarkPlus.accentColor, Theme.vscodeDarkPlus.diffModifiedGutter)
        XCTAssertEqual(Theme.vscodeLightModern.accentColor, Theme.vscodeLightModern.diffModifiedGutter)
        XCTAssertEqual(Theme.oneDarkPro.accentColor, Theme.oneDarkPro.function)
        XCTAssertEqual(Theme.jetbrainsDarcula.accentColor, Theme.jetbrainsDarcula.diffModifiedGutter)
        XCTAssertEqual(Theme.intellijLight.accentColor, Theme.intellijLight.diffModifiedGutter)
        XCTAssertEqual(Theme.xcodeDark.accentColor, Theme.xcodeDark.diffModifiedGutter)
        XCTAssertEqual(Theme.xcodeLight.accentColor, Theme.xcodeLight.diffModifiedGutter)
        XCTAssertEqual(Theme.dracula.accentColor, Theme.dracula.diffModifiedGutter)
        XCTAssertEqual(Theme.rosePine.accentColor, Theme.rosePine.diffModifiedGutter)
        XCTAssertEqual(Theme.githubLight.inputBackground, .white)
        XCTAssertEqual(Theme.vscodeLightModern.inputBackground, .white)
        XCTAssertEqual(Theme.intellijLight.inputBackground, .white)
        XCTAssertEqual(Theme.xcodeLight.inputBackground, .white)
        XCTAssertEqual(Theme.catppuccinLatte.inputBackground, .white)
        XCTAssertEqual(Theme.gruvboxLight.inputBackground, .white)
        XCTAssertEqual(Theme.solarizedLight.inputBackground, .white)
        XCTAssertEqual(Theme.everforestLight.inputBackground, .white)

        let names = Theme.allThemes.map(\.name)
        let sortedNames = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(names, sortedNames, "Theme.allThemes should be sorted alphabetically by display name")
    }
}
