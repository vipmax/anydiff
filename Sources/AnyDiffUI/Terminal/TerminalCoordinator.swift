import Foundation
import Combine
import AnyDiffCore

/// Terminal display mode: modern collapsible command MultiBuffer vs classic fullscreen Interactive terminal.
public enum TerminalDisplayMode: String, CaseIterable, Sendable {
    case multiBuffer = "MultiBuffer"
    case interactive = "Interactive"
}

/// Represents an individual terminal tab instance with its own persistent shell,
/// multibuffer command history, and optional interactive fullscreen terminal session.
@MainActor
public final class TerminalTab: ObservableObject, Identifiable {
    public let id: UUID
    @Published public var title: String
    @Published public var customTitle: String? = nil
    @Published public var displayMode: TerminalDisplayMode = .multiBuffer
    public let createdAt: Date

    /// Modern block/multibuffer session backed by an asynchronous persistent shell process.
    public let blockSession: BlockTerminalSession

    /// Classic interactive fullscreen PTY session (used in Interactive mode).
    public let interactiveSession: TerminalSession

    private var cancellables = Set<AnyCancellable>()

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        customInteractiveSession: TerminalSession? = nil
    ) {
        self.id = id
        self.title = title ?? "Terminal"
        self.createdAt = Date()
        self.blockSession = BlockTerminalSession(workingDirectory: workingDirectory)
        self.interactiveSession = customInteractiveSession ?? TerminalSession(workingDirectory: workingDirectory)

        // Forward high-level lifecycle state changes so UI updates reactively without re-rendering on every stream chunk
        blockSession.$isProcessRunning
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        blockSession.$currentDirectory
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        blockSession.$isAlternateBufferActive
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.interactiveSession.$isRunning
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Whether alternate buffer (e.g. vim/htop) or explicit interactive mode is active.
    public var isShowingInteractive: Bool {
        displayMode == .interactive || blockSession.isAlternateBufferActive
    }

    /// The active terminal session for rendering interactive grids.
    public var activeTerminalSession: TerminalSession {
        if blockSession.isProcessRunning, let active = blockSession.activeTerminalSession {
            return active
        }
        return interactiveSession
    }

    /// Whether a command or shell is actively running in the background.
    public var isRunning: Bool {
        if !isShowingInteractive {
            return blockSession.isProcessRunning
        } else {
            return activeTerminalSession.isRunning
        }
    }

    /// Exit code of the last completed process/command, if any.
    public var exitCode: Int32? {
        if !isShowingInteractive {
            return blockSession.multiBuffer.blocks.last?.exitCode
        } else {
            return activeTerminalSession.exitCode
        }
    }

    /// Tracked physical working directory of this tab.
    public var currentDirectory: String {
        blockSession.currentDirectory
    }

    /// User-visible title computed from custom name, directory name, or default title.
    public var displayTitle: String {
        if let custom = customTitle, !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        // Folder name if available
        let folderName = (currentDirectory as NSString).lastPathComponent
        if !folderName.isEmpty && folderName != "/" && folderName != NSHomeDirectory() {
            return folderName
        }
        return title
    }

    /// Renames the terminal tab to a custom user-defined title.
    public func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        self.customTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Restarts the active shell or process.
    public func restart() {
        if isShowingInteractive {
            activeTerminalSession.restart(workingDirectory: currentDirectory)
        } else {
            blockSession.persistentSession.restart(workingDirectory: currentDirectory)
        }
    }

    /// Clears the output buffer or screen.
    public func clear() {
        if isShowingInteractive {
            activeTerminalSession.clear()
        } else {
            blockSession.multiBuffer.clear()
        }
    }

    /// Sends a SIGINT interrupt (Ctrl+C).
    public func interrupt() {
        if !isShowingInteractive {
            blockSession.sendInterrupt()
        } else {
            activeTerminalSession.sendSignal(SIGINT)
        }
    }

    /// Terminates both background shell processes when tab is closed.
    public func terminate() {
        blockSession.persistentSession.terminateProcess()
        interactiveSession.terminateProcess()
    }
}

/// Domain coordinator managing multiple background terminal tabs,
/// active tab selection, background process lifecycles, and tab creation/closing.
@MainActor
public final class TerminalCoordinator: ObservableObject {
    @Published public private(set) var tabs: [TerminalTab] = []
    @Published public var activeTabId: UUID? = nil
    public var defaultWorkingDirectory: String

    private var nextTerminalNumber: Int = 1
    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    public init(workingDirectory: String = FileManager.default.currentDirectoryPath) {
        self.defaultWorkingDirectory = workingDirectory
        _ = createTab(workingDirectory: workingDirectory)
    }

    /// Backward-compatibility initializer wrapping an existing TerminalSession.
    public init(singleSession: TerminalSession) {
        self.defaultWorkingDirectory = singleSession.currentDirectory
        let tab = TerminalTab(
            title: "Terminal 1",
            workingDirectory: singleSession.currentDirectory,
            customInteractiveSession: singleSession
        )
        self.tabs = [tab]
        self.activeTabId = tab.id
        self.nextTerminalNumber = 2
        bindTab(tab)
    }

    /// The currently selected active terminal tab.
    public var activeTab: TerminalTab? {
        if let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) {
            return tab
        }
        return tabs.first
    }

    /// Creates and switches to a new background terminal tab.
    @discardableResult
    public func createTab(workingDirectory: String? = nil, title: String? = nil) -> TerminalTab {
        let dir = workingDirectory ?? activeTab?.currentDirectory ?? defaultWorkingDirectory
        let num = nextTerminalNumber
        nextTerminalNumber += 1
        let tabTitle = title ?? "Terminal \(num)"
        let tab = TerminalTab(title: tabTitle, workingDirectory: dir)
        tabs.append(tab)
        activeTabId = tab.id
        bindTab(tab)
        return tab
    }

    /// Closes a terminal tab and terminates its background processes.
    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.terminate()
        tabSubscriptions.removeValue(forKey: id)
        tabs.remove(at: index)

        if tabs.isEmpty {
            // Keep at least one tab open
            let newTab = createTab()
            activeTabId = newTab.id
        } else if activeTabId == id {
            let nextIndex = min(index, tabs.count - 1)
            activeTabId = tabs[nextIndex].id
        }
    }

    /// Selects the specified tab by ID.
    public func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
    }

    /// Selects the next tab in circular order.
    public func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let currentId = activeTabId, let idx = tabs.firstIndex(where: { $0.id == currentId }) else {
            activeTabId = tabs.first?.id
            return
        }
        let nextIdx = (idx + 1) % tabs.count
        activeTabId = tabs[nextIdx].id
    }

    /// Selects the previous tab in circular order.
    public func selectPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let currentId = activeTabId, let idx = tabs.firstIndex(where: { $0.id == currentId }) else {
            activeTabId = tabs.last?.id
            return
        }
        let prevIdx = (idx - 1 + tabs.count) % tabs.count
        activeTabId = tabs[prevIdx].id
    }

    /// Closes all tabs except the specified one.
    public func closeOtherTabs(except id: UUID) {
        let toClose = tabs.filter { $0.id != id }
        for tab in toClose {
            tab.terminate()
            tabSubscriptions.removeValue(forKey: tab.id)
        }
        tabs.removeAll(where: { $0.id != id })
        activeTabId = id
    }

    /// Terminates all background terminal processes across all tabs.
    public func terminateAll() {
        for tab in tabs {
            tab.terminate()
        }
        tabs.removeAll()
        tabSubscriptions.removeAll()
    }

    private func bindTab(_ tab: TerminalTab) {
        // Tab item views observe tab directly, so coordinator only forwards when active tab state changes
        let sub = tab.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, self.activeTabId == tab.id else { return }
                self.objectWillChange.send()
            }
        tabSubscriptions[tab.id] = sub
    }
}
