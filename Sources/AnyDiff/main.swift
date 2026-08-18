//
//  main.swift
//  AnyDiff — High Performance MultiBuffer Git Diff Viewer & Review Tool

//  Created for macOS with native FSEvents Watch Mode & Zero-Copy SIMD parsing.
//  Copyright © 2026 AnyDiff. All rights reserved.

import SwiftUI
import AppKit
import AnyDiffUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        mainWindow.minSize = NSSize(width: 900, height: 500)
        let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
        let customPath = (arg?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? arg : nil
        mainWindow.contentView = NSHostingView(rootView: MainWindowView(initialPath: customPath))
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.orderFrontRegardless()
        self.window = mainWindow

        setupMainMenu()

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu (Standard Application metadata & quit)
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
        fileMenu.addItem(NSMenuItem(title: "Open Project...", action: #selector(openProjectAction(_:)), keyEquivalent: "o"))
        let openURLItem = NSMenuItem(title: "Open GitHub PR / URL...", action: #selector(openURLAction(_:)), keyEquivalent: "O")
        openURLItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openURLItem)
        let openBrowserItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowserAction(_:)), keyEquivalent: "B")
        openBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openBrowserItem)
        let openTerminalItem = NSMenuItem(title: "Open in Terminal", action: #selector(openInTerminalAction(_:)), keyEquivalent: "T")
        openTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openTerminalItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Reload Diff", action: #selector(reloadDiffAction(_:)), keyEquivalent: "r"))
        let watchItem = NSMenuItem(title: "Toggle Watch Mode", action: #selector(toggleWatchModeAction(_:)), keyEquivalent: "w")
        watchItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(watchItem)
        fileMenu.addItem(NSMenuItem.separator())
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
        let copyDiffItem = NSMenuItem(title: "Copy Raw Git Diff", action: #selector(copyRawDiffAction(_:)), keyEquivalent: "C")
        copyDiffItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(copyDiffItem)
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(zoomInAction(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size (Reset Zoom)", action: #selector(resetZoomAction(_:)), keyEquivalent: "0"))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func openProjectAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffOpenProject"), object: nil)
    }

    @objc func openURLAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffOpenURL"), object: nil)
    }

    @objc func openInBrowserAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffOpenInBrowser"), object: nil)
    }

    @objc func openInTerminalAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffOpenInTerminal"), object: nil)
    }

    @objc func reloadDiffAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffReloadDiff"), object: nil)
    }

    @objc func toggleWatchModeAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffToggleWatchMode"), object: nil)
    }

    @objc func copyRawDiffAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffCopyRawDiff"), object: nil)
    }

    @objc func zoomInAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffZoomIn"), object: nil)
    }

    @objc func zoomOutAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffZoomOut"), object: nil)
    }

    @objc func resetZoomAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffResetZoom"), object: nil)
    }

    private var cachedIcon: NSImage?
    public func loadAppIcon() -> NSImage? {
        if let cached = cachedIcon { return cached }

        // 1. Standard bundle resource (when running inside AnyDiff.app)
        if let img = Bundle.main.image(forResource: "AppIcon") {
            cachedIcon = img
            return img
        }
        if let resourceURL = Bundle.main.resourceURL {
            let pngURL = resourceURL.appendingPathComponent("AppIcon.png")
            if let img = NSImage(contentsOf: pngURL) {
                cachedIcon = img
                return img
            }
            let icnsURL = resourceURL.appendingPathComponent("AppIcon.icns")
            if let img = NSImage(contentsOf: icnsURL) {
                cachedIcon = img
                return img
            }
        }

        // 2. Development mode (swift run / just release / just dev) via #filePath
        let sourceURL = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceURL
            .deletingLastPathComponent() // AnyDiff
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Project root
        let devIconURL = projectRoot.appendingPathComponent("Resources/AppIcon.png")
        if let img = NSImage(contentsOf: devIconURL) {
            cachedIcon = img
            return img
        }

        // 3. Fallback to current working directory
        let cwdIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.png")
        if let img = NSImage(contentsOf: cwdIconURL) {
            cachedIcon = img
            return img
        }

        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
if let icon = delegate.loadAppIcon() {
    app.applicationIconImage = icon
}
app.run()
