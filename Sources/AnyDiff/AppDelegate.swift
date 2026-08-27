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

        let mainWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainWindow.center()
        mainWindow.title = "AnyDiff"
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titlebarSeparatorStyle = .none
        mainWindow.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
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
}
