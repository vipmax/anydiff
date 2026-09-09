import AppKit
import AnyDiffCore
import AnyDiffUI

extension AppDelegate {
    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu (Standard Application metadata, hide & quit)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About AnyDiff", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())

        let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesMenuItem.submenu = servicesMenu
        appMenu.addItem(servicesMenuItem)
        NSApplication.shared.servicesMenu = servicesMenu

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide AnyDiff", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
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
        editMenu.addItem(NSMenuItem.separator())
        let findItem = NSMenuItem(title: "Find...", action: #selector(findInProjectAction(_:)), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(findItem)
        let findInProjectItem = NSMenuItem(title: "Find in Project...", action: #selector(findInProjectAction(_:)), keyEquivalent: "F")
        findInProjectItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findInProjectItem)
        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(findNextAction(_:)), keyEquivalent: "g")
        editMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(findPreviousAction(_:)), keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findPrevItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(NSMenuItem.separator())
        let toggleLeftPanelItem = NSMenuItem(title: "Toggle Left Panel", action: #selector(toggleLeftPanelAction(_:)), keyEquivalent: "s")
        toggleLeftPanelItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleLeftPanelItem)
        let toggleRightPanelItem = NSMenuItem(title: "Toggle Right Panel", action: #selector(toggleRightPanelAction(_:)), keyEquivalent: "a")
        toggleRightPanelItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleRightPanelItem)
        viewMenu.addItem(NSMenuItem(title: "Reset Panels to Default", action: #selector(resetPanelsLayoutAction(_:)), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(zoomInAction(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(zoomOutAction(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size (Reset Zoom)", action: #selector(resetZoomAction(_:)), keyEquivalent: "0"))
        viewMenu.addItem(NSMenuItem.separator())
        let agentMenuItem = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let agentMenu = NSMenu(title: "Agent")
        agentMenu.delegate = self
        let agentItem = NSMenuItem(title: "Toggle Right Panel", action: #selector(toggleRightPanelAction(_:)), keyEquivalent: "")
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

        // Diff Layout Submenu
        let layoutMenuItem = NSMenuItem(title: "Diff Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Diff Layout")
        layoutMenu.delegate = self

        let unifiedItem = NSMenuItem(title: "Unified", action: #selector(selectDiffLayoutAction(_:)), keyEquivalent: "")
        unifiedItem.representedObject = DiffLayoutMode.unified.rawValue
        layoutMenu.addItem(unifiedItem)

        let splitItem = NSMenuItem(title: "Side-by-Side (Split)", action: #selector(selectDiffLayoutAction(_:)), keyEquivalent: "")
        splitItem.representedObject = DiffLayoutMode.sideBySide.rawValue
        layoutMenu.addItem(splitItem)

        layoutMenuItem.submenu = layoutMenu
        viewMenu.addItem(layoutMenuItem)

        let toggleLayoutItem = NSMenuItem(title: "Toggle Side-by-Side Diff", action: #selector(toggleDiffLayoutAction(_:)), keyEquivalent: "d")
        toggleLayoutItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(toggleLayoutItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Navigate Menu
        let navigateMenuItem = NSMenuItem()
        let navigateMenu = NSMenu(title: "Navigate")

        let nextHunkItem = NSMenuItem(title: "Go to Next Hunk", action: #selector(goToNextHunkAction(_:)), keyEquivalent: String(UnicodeScalar(NSF8FunctionKey)!))
        nextHunkItem.keyEquivalentModifierMask = [.command]
        navigateMenu.addItem(nextHunkItem)

        let prevHunkItem = NSMenuItem(title: "Go to Previous Hunk", action: #selector(goToPreviousHunkAction(_:)), keyEquivalent: String(UnicodeScalar(NSF8FunctionKey)!))
        prevHunkItem.keyEquivalentModifierMask = [.command, .shift]
        navigateMenu.addItem(prevHunkItem)

        navigateMenuItem.submenu = navigateMenu
        mainMenu.addItem(navigateMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

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
        } else if menu.title == "Diff Layout" {
            let currentLayout = UserDefaults.standard.string(forKey: "preferredDiffLayoutMode") ?? DiffLayoutMode.unified.rawValue
            for item in menu.items {
                if let id = item.representedObject as? String {
                    item.state = (id == currentLayout) ? .on : .off
                }
            }
        }
    }

    @objc func selectDiffLayoutAction(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: "preferredDiffLayoutMode")
        NotificationCenter.default.post(
            name: Notification.Name("anyDiffSetDiffLayout"),
            object: nil,
            userInfo: ["mode": mode]
        )
    }

    @objc func toggleDiffLayoutAction(_ sender: NSMenuItem) {
        let currentLayout = UserDefaults.standard.string(forKey: "preferredDiffLayoutMode") ?? DiffLayoutMode.unified.rawValue
        let newLayout = (currentLayout == DiffLayoutMode.unified.rawValue) ? DiffLayoutMode.sideBySide.rawValue : DiffLayoutMode.unified.rawValue
        UserDefaults.standard.set(newLayout, forKey: "preferredDiffLayoutMode")
        NotificationCenter.default.post(
            name: Notification.Name("anyDiffSetDiffLayout"),
            object: nil,
            userInfo: ["mode": newLayout]
        )
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

    @objc func toggleLeftPanelAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffToggleLeftPanel"), object: nil)
    }

    @objc func toggleRightPanelAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffToggleRightPanel"), object: nil)
    }

    @objc func resetPanelsLayoutAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffResetPanelsLayout"), object: nil)
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        toggleLeftPanelAction(sender)
    }

    @objc func toggleAgentPanelAction(_ sender: Any?) {
        toggleRightPanelAction(sender)
    }

    @objc func selectToolcallColorModeAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let mode = ToolcallColorMode(rawValue: rawValue) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: AgentDisplayPreferences.toolcallColorModeKey)
        NotificationCenter.default.post(name: AgentDisplayPreferences.didChangeNotification, object: nil)
    }

    @objc func findInProjectAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffFindInProject"), object: nil)
    }

    @objc func findNextAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffFindNext"), object: nil)
    }

    @objc func findPreviousAction(_ sender: Any?) {
        NotificationCenter.default.post(name: Notification.Name("anyDiffFindPrevious"), object: nil)
    }

    @objc func goToNextHunkAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .goToNextHunk, object: nil)
    }

    @objc func goToPreviousHunkAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .goToPreviousHunk, object: nil)
    }
}
