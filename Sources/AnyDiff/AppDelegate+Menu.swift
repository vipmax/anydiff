import AppKit
import AnyDiffCore
import AnyDiffUI

extension AppDelegate {
    func setupMainMenu() {
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
        // Use responder-chain actions. UndoManager.undo/redo are zero-argument
        // methods and do not reach custom editors implementing undo(_:)/redo(_:).
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(CustomMultiBufferEditorView.undo(_:)), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: #selector(CustomMultiBufferEditorView.redo(_:)), keyEquivalent: "Z")
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
        viewMenu.addItem(NSMenuItem.separator())
        let agentMenuItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu(title: "Agent")
        agentMenu.delegate = self
        let agentItem = NSMenuItem(title: "Toggle Agent Panel", action: #selector(toggleAgentPanelAction(_:)), keyEquivalent: "a")
        agentItem.keyEquivalentModifierMask = [.command, .option]
        agentMenu.addItem(agentItem)
        agentMenu.addItem(NSMenuItem.separator())
        let colorsMenuItem = NSMenuItem(title: "Toolcall Colors", action: nil, keyEquivalent: "")
        let colorsMenu = NSMenu(title: "Toolcall Colors")
        colorsMenu.delegate = self
        for mode in ToolcallColorMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectToolcallColorModeAction(_:)),
                keyEquivalent: ""
            )
            item.representedObject = mode.rawValue
            colorsMenu.addItem(item)
        }
        colorsMenuItem.submenu = colorsMenu
        agentMenu.addItem(colorsMenuItem)
        agentMenuItem.submenu = agentMenu
        viewMenu.addItem(agentMenuItem)
        viewMenu.addItem(NSMenuItem.separator())

        // Theme Submenu
        let themeMenuItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        themeMenu.delegate = self

        let systemItem = NSMenuItem(title: "System (Auto Light/Dark)", action: #selector(selectThemeAction(_:)), keyEquivalent: "")
        systemItem.representedObject = "system"
        themeMenu.addItem(systemItem)
        themeMenu.addItem(NSMenuItem.separator())

        for theme in Theme.allThemes {
            let item = NSMenuItem(title: theme.name, action: #selector(selectThemeAction(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            themeMenu.addItem(item)
        }
        themeMenuItem.submenu = themeMenu
        viewMenu.addItem(themeMenuItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Theme" {
            let currentThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? "system"
            for item in menu.items {
                if let id = item.representedObject as? String {
                    item.state = (id == currentThemeId) ? .on : .off
                }
            }
        } else if menu.title == "Toolcall Colors" {
            let selectedMode = AgentDisplayPreferences.toolcallColorMode.rawValue
            for item in menu.items {
                item.state = (item.representedObject as? String) == selectedMode ? .on : .off
            }
        }
    }

    @objc func selectThemeAction(_ sender: NSMenuItem) {
        guard let themeId = sender.representedObject as? String else { return }
        UserDefaults.standard.set(themeId, forKey: "selectedThemeId")
        NotificationCenter.default.post(
            name: Notification.Name("anyDiffSelectTheme"),
            object: nil,
            userInfo: ["themeId": themeId]
        )
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

    @objc func toggleAgentPanelAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffToggleAgent"), object: nil)
    }

    @objc func selectToolcallColorModeAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = ToolcallColorMode(rawValue: rawValue) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: AgentDisplayPreferences.toolcallColorModeKey)
        NotificationCenter.default.post(name: AgentDisplayPreferences.didChangeNotification, object: nil)
    }
}
