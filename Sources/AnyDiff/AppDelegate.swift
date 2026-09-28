import SwiftUI
import AppKit
import AnyDiffCore
import AnyDiffUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow?
    private let iconLoader = AppIconLoader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSAppSleepDisabled": true])
        NSApp.setActivationPolicy(.regular)

        if let icon = loadAppIcon() {
            NSApp.applicationIconImage = icon
        }

        let screen = NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1260, height: 800)
        let windowWidth = min(1260, visibleFrame.width * 0.95)
        let windowHeight = min(800, visibleFrame.height * 0.92)
        let originX = visibleFrame.origin.x + (visibleFrame.width - windowWidth) / 2
        let originY = visibleFrame.origin.y + (visibleFrame.height - windowHeight) / 2

        let mainWindow = NSWindow(
            contentRect: NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainWindow.minSize = NSSize(width: 860, height: 520)
        mainWindow.setFrameAutosaveName("AnyDiffMainWindow")
        var currentFrame = mainWindow.frame
        currentFrame.size.width = min(currentFrame.size.width, visibleFrame.width * 0.96)
        currentFrame.size.height = min(currentFrame.size.height, visibleFrame.height * 0.92)
        if currentFrame.minX < visibleFrame.minX { currentFrame.origin.x = visibleFrame.minX }
        if currentFrame.maxX > visibleFrame.maxX { currentFrame.origin.x = visibleFrame.maxX - currentFrame.width }
        if currentFrame.minY < visibleFrame.minY { currentFrame.origin.y = visibleFrame.minY }
        if currentFrame.maxY > visibleFrame.maxY { currentFrame.origin.y = visibleFrame.maxY - currentFrame.height }
        mainWindow.setFrame(currentFrame, display: true)
        mainWindow.title = "AnyDiff"
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titlebarSeparatorStyle = .none
        mainWindow.backgroundColor = initialTheme().background
        mainWindow.toolbarStyle = .unified
        let windowToolbar = NSToolbar(identifier: "AnyDiffWindowToolbar")
        windowToolbar.allowsUserCustomization = false
        windowToolbar.autosavesConfiguration = false
        mainWindow.toolbar = windowToolbar
        mainWindow.isReleasedWhenClosed = false

        let customPath = initialPath(from: CommandLine.arguments)
        mainWindow.contentView = NSHostingView(rootView: MainWindowView(initialPath: customPath))
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        self.window = mainWindow

        setupMainMenu()

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    func loadAppIcon() -> NSImage? {
        iconLoader.load()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func initialTheme() -> Theme {
        let storedThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? "system"
        if storedThemeId == "system" {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .vesper : .macOSLight
        } else if let theme = Theme.allThemes.first(where: { $0.id == storedThemeId }) {
            return theme
        }
        return .vesper
    }
}
