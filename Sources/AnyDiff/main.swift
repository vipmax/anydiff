import SwiftUI
import AppKit
import AnyDiffUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let mainWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        mainWindow.center()
        mainWindow.title = "AnyDiff"
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.toolbarStyle = .unified
        mainWindow.isReleasedWhenClosed = false
        mainWindow.minSize = NSSize(width: 900, height: 500)
        let customPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
        mainWindow.contentView = NSHostingView(rootView: MainWindowView(initialPath: customPath))
        mainWindow.makeKeyAndOrderFront(nil)
        self.window = mainWindow

        setupMainMenu()

        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About AnyDiff", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit AnyDiff", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit Menu (Standard Keybindings for Undo, Redo, Cut, Copy, Paste, Select All)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
