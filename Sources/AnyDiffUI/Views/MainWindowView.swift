import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore

private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var isDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        self.isDark = Self.readIsDark()
        self.appearanceObservation = NSApp.observe(\NSApplication.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isDark = Self.readIsDark()
            }
        }
    }

    private static func readIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

public struct MainWindowView: View {
    public var initialPath: String?

    @StateObject private var multiBuffer = MultiBuffer()
    @StateObject private var reviewManager = ReviewManager()
    @StateObject private var displayMap: DisplayMap

    @StateObject private var reviewMultiBuffer = MultiBuffer()
    @StateObject private var reviewDisplayMap: DisplayMap
    @State private var reviewFileDiffs: [FileDiff] = []
    @State private var reviewViewStateResetToken: UInt64 = 0
    @State private var preparedReviewSummary: AgentEditedFilesSummary? = nil

    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @StateObject private var agentCoordinator = AgentSessionCoordinator()
    @State private var isAgentSessionsPresented: Bool = false
    @State private var isAgentSessionsHovered: Bool = false
    @State private var isReviewCloseHovered: Bool = false

    private var activeAgentManager: AgentSessionManager? {
        agentCoordinator.activeManager
    }

    private var isMockAgent: Bool {
        agentCoordinator.isMockAgent
    }

    private var isReviewActive: Bool {
        agentCoordinator.activeReviewSummary != nil
    }

    private var activeMultiBuffer: MultiBuffer {
        isReviewActive ? reviewMultiBuffer : multiBuffer
    }

    private var activeDisplayMap: DisplayMap {
        isReviewActive ? reviewDisplayMap : displayMap
    }

    private var activeFileDiffs: [FileDiff] {
        isReviewActive ? reviewFileDiffs : fileDiffs
    }

    public enum RepoStatus {
        case notGitRepository
        case clean
        case hasChanges
    }

    @State private var currentPath: String? = nil
    @State private var isReloading: Bool = false
    @State private var isStreaming: Bool = false
    @State private var streamingCount: Int = 0
    @State private var currentBranch: String = ""
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var comparisonTarget: ComparisonTarget = .workingTree
    @State private var repoStatus: RepoStatus = .clean
    @State private var fileDiffs: [FileDiff] = []
    @State private var selectedFilePath: String? = nil
    @State private var isWatchModeEnabled: Bool = true
    @State private var folderWatcher: FolderWatcher? = nil
    @State private var selectedTheme: Theme = .unifiedDark
    @State private var followsSystemAppearance: Bool = true
    @State private var viewMode: DiffViewMode = .unified
    @State private var contextLines: Int = 3
    @State private var fontSize: CGFloat = 13

    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var commentTarget: (filePath: String, lineNumber: Int)? = nil
    @State private var currentFolderName: String = ""
    @State private var showOpenSourcePopover: Bool = false
    @State private var isWindowDropTargeted: Bool = false
    @State private var remoteTarget: GitHubDiffReference? = nil
    @State private var remoteErrorMessage: String? = nil
    @State private var remoteLoadTask: Task<Void, Never>? = nil
    @State private var gitStateReloadWorkItem: DispatchWorkItem? = nil
    @State private var hasPendingGitStateReload: Bool = false
    @State private var loadGeneration: UInt64 = 0
    @State private var watchRefreshGeneration: UInt64 = 0
    @State private var pendingWatchPaths: Set<String> = []
    @State private var watchRefreshInFlight: Bool = false

    public init(initialPath: String? = nil) {
        self.initialPath = initialPath
        let mb = MultiBuffer()
        let rm = ReviewManager()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: rm)

        let rmb = MultiBuffer()
        let rdm = DisplayMap(multiBuffer: rmb, reviewManager: rm)

        self._multiBuffer = StateObject(wrappedValue: mb)
        self._reviewManager = StateObject(wrappedValue: rm)
        self._displayMap = StateObject(wrappedValue: dm)
        self._reviewMultiBuffer = StateObject(wrappedValue: rmb)
        self._reviewDisplayMap = StateObject(wrappedValue: rdm)
    }

    private var activeTheme: Theme {
        if followsSystemAppearance {
            return systemAppearance.isDark ? .unifiedDark : .macOSLight
        }
        return selectedTheme
    }

    private var commentModalBinding: Binding<IdentifiableCommentTarget?> {
        Binding(
            get: { commentTarget.map { IdentifiableCommentTarget(filePath: $0.filePath, lineNumber: $0.lineNumber) } },
            set: { _ in commentTarget = nil }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } content: {
            editorColumnView
        } detail: {
            agentColumnView
        }
        .preferredColorScheme(activeTheme.isDark ? .dark : .light)
        .environment(\.colorScheme, activeTheme.isDark ? .dark : .light)
        .toolbarBackground(Color(activeTheme.background), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(activeTheme.isDark ? .dark : .light, for: .windowToolbar)
        .background(Color(activeTheme.background).ignoresSafeArea())
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.text], isTargeted: $isWindowDropTargeted) { providers in
            handleWindowDrop(providers: providers)
        }
        .overlay(windowDropOverlayView)
        .overlay {
            if let preview = agentCoordinator.activeImagePreview {
                AgentImagePreviewModalView(
                    images: preview.images,
                    selectedIndex: Binding(
                        get: { agentCoordinator.activeImagePreview?.selectedIndex },
                        set: { newIdx in
                            if let newIdx = newIdx {
                                agentCoordinator.activeImagePreview?.selectedIndex = newIdx
                            } else {
                                agentCoordinator.activeImagePreview = nil
                            }
                        }
                    ),
                    onDelete: preview.isDraft ? { delIdx in
                        NotificationCenter.default.post(
                            name: Notification.Name("anyDiffDeleteDraftImage"),
                            object: nil,
                            userInfo: ["index": delIdx]
                        )
                        if let currentImages = agentCoordinator.activeImagePreview?.images, delIdx < currentImages.count {
                            var updated = currentImages
                            updated.remove(at: delIdx)
                            if updated.isEmpty {
                                agentCoordinator.activeImagePreview = nil
                            } else {
                                agentCoordinator.activeImagePreview?.images = updated
                            }
                        }
                    } : nil,
                    theme: activeTheme
                )
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .sheet(item: commentModalBinding) { target in
            commentModalView(for: target)
        }
        .onAppear(perform: handleOnAppear)
        .onChange(of: agentCoordinator.activeReviewSummary) { newSummary in
            if let summary = newSummary {
                // beginReview preloads the review before switching modes. The
                // fallback handles any coordinator-driven activation that did
                // not go through that path.
                if preparedReviewSummary == summary {
                    preparedReviewSummary = nil
                } else {
                    loadReviewDiff(for: summary)
                }
            } else {
                preparedReviewSummary = nil
                loadCurrentDirectoryDiff()
            }
        }
        .onChange(of: selectedTheme.id) { _ in updateWindowAppearance() }
        .onChange(of: followsSystemAppearance) { _ in updateWindowAppearance() }
        .onChange(of: isWatchModeEnabled) { enabled in
            if enabled {
                let currentDir = effectiveWorkingDirectory
                restartWatcher(for: currentDir)
                startPendingWatchRefresh(directory: URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path)
            } else {
                folderWatcher?.stop()
                folderWatcher = nil
                pendingWatchPaths.removeAll()
                watchRefreshGeneration &+= 1
            }
        }
        .onDisappear {
            folderWatcher?.stop()
            folderWatcher = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenProject"))) { _ in
            showOpenSourcePopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenURL"))) { _ in
            showOpenSourcePopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffOpenInBrowser"))) { _ in
            openInBrowser()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentSessionTurnCompleted"))) { notification in
            guard let session = notification.object as? AgentSessionItem else { return }
            let isError = (notification.userInfo?["isError"] as? Bool) ?? false
            if session.isNotificationsEnabled {
                if isError {
                    SoundFeedback.play(.error)
                } else {
                    SoundFeedback.play(.completion)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentPermissionRequested"))) { notification in
            guard let session = notification.object as? AgentSessionItem else { return }
            if session.isNotificationsEnabled {
                SoundFeedback.play(.attention)
                HapticFeedback.perform(.levelChange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffReloadDiff"))) { _ in
            reloadCurrentDiff()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleWatchMode"))) { _ in
            isWatchModeEnabled.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffToggleAgent"))) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                agentCoordinator.togglePanel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffSelectTheme"))) { notif in
            if let themeId = notif.userInfo?["themeId"] as? String {
                if themeId == "system" {
                    followsSystemAppearance = true
                } else if let t = Theme.allThemes.first(where: { $0.id == themeId }) {
                    selectedTheme = t
                    followsSystemAppearance = false
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        SidebarFileListView(
            fileDiffs: activeFileDiffs,
            theme: activeTheme,
            emptyMessage: isReviewActive ? "No files in review" : (repoStatus == .notGitRepository ? "Not a Git repository" : "No changed files"),
            isReloading: isReloading,
            isStreaming: isStreaming,
            streamingCount: streamingCount,
            comparisonTarget: comparisonTarget,
            isWatchModeEnabled: isWatchModeEnabled,
            reviewManager: reviewManager,
            selectedFilePath: $selectedFilePath,
            onReload: { reloadCurrentDiff() },
            onToggleWatchMode: { isWatchModeEnabled.toggle() }
        )
        .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 800)
    }

    @ViewBuilder
    private var editorColumnView: some View {
        Group {
            // Keep the editor host mounted while the first review diff is
            // loading. `reviewFileDiffs` starts empty, and replacing the host
            // with the empty state would destroy its UI coordinator and the
            // main editor snapshot before the first review can be closed.
            if activeFileDiffs.isEmpty && !isReviewActive {
                emptyStateDetailView
            } else {
                editorDetailView
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toolbarNavigationItems
            }
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItem(placement: .automatic) {
                if agentCoordinator.isPanelOpen {
                    agentToolbarHeader
                } else {
                    agentToolbarButton
                }
            }
        }
        .background(hiddenKeyboardShortcuts)
        .navigationSplitViewColumnWidth(min: 360, ideal: 760, max: 1600)
    }

    @ViewBuilder
    private var agentColumnView: some View {
        Group {
            if agentCoordinator.isPanelOpen {
                if !agentCoordinator.showStartScreen, let activeSession = agentCoordinator.activeSession {
                    AgentPanelView(
                        agentManager: activeSession.manager,
                        theme: activeTheme,
                        workingDirectory: effectiveWorkingDirectory,
                        currentSelectedFile: selectedFilePath,
                        fileDiffsSummary: currentDiffSummary,
                        agentAccentColor: activeSession.preset.color,
                        onReview: { summary in
                            beginReview(summary: summary)
                        },
                        onPreviewImages: { imgs, idx, isDraft in
                            agentCoordinator.showImagePreview(images: imgs, selectedIndex: idx, isDraft: isDraft)
                        }
                    )
                    .id(activeSession.id)
                } else {
                    AgentStartScreenView(
                        coordinator: agentCoordinator,
                        theme: activeTheme,
                        workingDirectory: effectiveWorkingDirectory
                    )
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(
            min: agentCoordinator.isPanelOpen ? 280 : 0,
            ideal: agentCoordinator.isPanelOpen ? 500 : 0,
            max: agentCoordinator.isPanelOpen ? 800 : 0
        )
    }

    @ViewBuilder
    private var agentToolbarHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            if let activeSession = agentCoordinator.activeSession {
                Button(action: { isAgentSessionsPresented.toggle() }) {
                    Text(activeSession.preset.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isAgentSessionsHovered || isAgentSessionsPresented
                            ? Color(nsColor: .labelColor)
                            : Color(nsColor: .labelColor).opacity(0.92))
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .frame(minWidth: 58, minHeight: 24)
                        .background(Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(agentAccentColor.opacity(
                                    isAgentSessionsHovered || isAgentSessionsPresented ? 0.08 : 0
                                ))
                        )
                }
                .buttonStyle(.plain)
                .help("Sessions")
                .popover(isPresented: $isAgentSessionsPresented, arrowEdge: .bottom) {
                    AgentSettingsPopoverView(
                        coordinator: agentCoordinator,
                        theme: activeTheme,
                        workingDirectory: effectiveWorkingDirectory,
                        onClose: { isAgentSessionsPresented = false }
                    )
                }
                .padding(.trailing, 2)
                .scaleEffect(isAgentSessionsHovered ? 1.02 : 1)
                .shadow(
                    color: isAgentSessionsHovered || isAgentSessionsPresented
                        ? agentAccentColor.opacity(0.16)
                        : Color.clear,
                    radius: isAgentSessionsHovered || isAgentSessionsPresented ? 9 : 5,
                    y: isAgentSessionsHovered || isAgentSessionsPresented ? 2 : 1
                )
                .animation(.easeOut(duration: 0.16), value: isAgentSessionsHovered)
                .animation(.easeOut(duration: 0.16), value: isAgentSessionsPresented)
                .onHover { isAgentSessionsHovered = $0 }
            }

            if let activeSession = agentCoordinator.activeSession {
                Button(action: {
                    activeSession.isNotificationsEnabled.toggle()
                }) {
                    Image(systemName: activeSession.isNotificationsEnabled ? "bell.fill" : "bell.slash")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 18, height: 18)
                        .foregroundColor(activeSession.isNotificationsEnabled
                            ? agentAccentColor
                            : Color(nsColor: .secondaryLabelColor).opacity(0.85))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(
                    accentColor: agentAccentColor,
                    isActive: activeSession.isNotificationsEnabled
                ))
                .help(activeSession.isNotificationsEnabled
                    ? "Sound notifications enabled for this chat (Click to mute)"
                    : "Sound notifications disabled for this chat (Click to enable)")
            }

            if hasActiveAgentSession {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = agentCoordinator.createNewSession(workingDirectory: effectiveWorkingDirectory)
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14.5, weight: .medium))
                        .frame(width: 18, height: 18)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(accentColor: agentAccentColor))
                .help("New Agent Session (Cmd+N)")
            }

            if hasActiveAgentSession {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isShowingAgentStartScreen {
                            if let active = agentCoordinator.activeSession {
                                agentCoordinator.selectSession(id: active.id)
                            }
                        } else {
                            agentCoordinator.openStartScreen()
                        }
                    }
                }) {
                    Image(systemName: isShowingAgentStartScreen ? "chevron.right" : "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18, height: 18)
                        .foregroundColor(isShowingAgentStartScreen ? agentAccentColor : Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(AgentToolbarActionButtonStyle(
                    accentColor: agentAccentColor,
                    isActive: isShowingAgentStartScreen
                ))
                .help(isShowingAgentStartScreen ? "Back to Chat" : "Choose Agent / All Agents")
            }

            agentPanelToggleButton(isOpen: true)
        }
    }

    private var hasActiveAgentSession: Bool {
        agentCoordinator.activeSession != nil
    }

    private var agentAccentColor: Color {
        agentCoordinator.activeSession?.preset.color ?? .accentColor
    }

    private var isShowingAgentStartScreen: Bool {
        agentCoordinator.showStartScreen || !hasActiveAgentSession
    }

    @ViewBuilder
    private var agentToolbarButton: some View {
        HStack(spacing: 6) {
            agentPanelToggleButton(isOpen: false)
        }
    }

    @ViewBuilder
    private func agentPanelToggleButton(isOpen: Bool) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                agentCoordinator.isPanelOpen = !isOpen
            }
        }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 18, height: 18)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help(isOpen ? "Hide Agent Panel (Cmd+Opt+A)" : "Show Agent Panel (Cmd+Opt+A)")
    }

    private var currentDiffSummary: String {
        guard !fileDiffs.isEmpty else { return "No uncommitted changes." }
        var summary = "Repository: \(currentFolderName)\n"
        summary += "Changed Files (\(fileDiffs.count)):\n"
        for file in fileDiffs.prefix(25) {
            summary += "- \(file.displayPath) (+\(file.additions), -\(file.deletions))\n"
        }
        if fileDiffs.count > 25 {
            summary += "...and \(fileDiffs.count - 25) more files\n"
        }
        return summary
    }

    @ViewBuilder
    private var emptyStateDetailView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                emptyStatusHeaderView

                OpenSourceContentView(
                    theme: activeTheme,
                    currentLocalPath: currentPath,
                    currentComparisonTarget: comparisonTarget,
                    isInline: true,
                    onOpenLocalFolder: { openGitRepositoryFolder() },
                    onSelectLocalPath: { path in
                        self.currentPath = path
                        loadCurrentDirectoryDiff()
                    },
                    onOpenRemoteURL: { url in
                        loadRemoteDiff(from: url)
                    },
                    onOpenInBrowser: { openInBrowser() }
                )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(activeTheme.background))
    }

    @ViewBuilder
    private var emptyStatusHeaderView: some View {
        VStack(spacing: 6) {
            if repoStatus == .notGitRepository {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                Text("Not a Git Repository")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(activeTheme.foreground))

                Text(currentFolderName.isEmpty ? "Current folder is not a Git repository." : "\"\(currentFolderName)\" is not a Git repository.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(activeTheme.gutterForeground))
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundColor(Color(activeTheme.gutterForeground).opacity(0.8))

                Text("No Uncommitted Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(activeTheme.foreground))

                Text("Working tree in \(currentFolderName.isEmpty ? "project" : "\"\(currentFolderName)\"") is clean.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(activeTheme.gutterForeground))
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var editorDetailView: some View {
        EditorHostView(
            displayMap: activeDisplayMap,
            theme: activeTheme,
            fontSize: fontSize,
            isEditable: (!isReviewActive && comparisonTarget == .workingTree),
            selectedFilePath: selectedFilePath,
            viewStateResetToken: isReviewActive ? reviewViewStateResetToken : nil,
            onCursorChange: { location, _ in
                if let path = location?.filePath, self.selectedFilePath != path {
                    self.selectedFilePath = path
                }
            },
            onAddCommentRequest: { path, line in
                commentTarget = (filePath: path, lineNumber: line)
            }
        )
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var toolbarNavigationItems: some View {
        HStack(spacing: 6) {
            if case .remote(let ref) = comparisonTarget {
                remoteHeaderButton(for: ref)

                Button(action: openInBrowser) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help("Open Pull Request in Browser (Cmd+Shift+B)")

                readOnlyBadge
            } else {
                localHeaderButton

                if repoStatus != .notGitRepository && !currentBranch.isEmpty {
                    BranchPickerView(
                        currentBranch: currentBranch,
                        localBranches: localBranches,
                        remoteBranches: remoteBranches,
                        comparisonTarget: $comparisonTarget,
                        onSelectTarget: { target in
                            self.comparisonTarget = target
                            loadCurrentDirectoryDiff()
                        }
                    )
                }

                if isReviewActive {
                    reviewReadOnlyBadge
                } else if comparisonTarget != .workingTree {
                    readOnlyBadge
                }
            }
        }
        .animation(nil, value: isReviewActive)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var reviewReadOnlyBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)

            Text("Read-Only Diff")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(isReviewCloseHovered ? .primary : .secondary.opacity(0.8))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isReviewCloseHovered ? Color.secondary.opacity(0.16) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help("Exit Review (Esc)")
                .accessibilityLabel("Exit Review")
                .accessibilityAddTraits(.isButton)
                .onTapGesture {
                    endReview()
                }
            .onHover { isReviewCloseHovered = $0 }
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 3.5)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder
    private func remoteHeaderButton(for ref: GitHubDiffReference) -> some View {
        Button(action: { showOpenSourcePopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                Text(ref.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Switch Project or Remote Diff (Cmd+O)")
        .popover(isPresented: $showOpenSourcePopover, arrowEdge: .bottom) {
            openSourcePopoverContentView
        }
    }

    @ViewBuilder
    private var localHeaderButton: some View {
        Button(action: { showOpenSourcePopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(currentFolderName.isEmpty ? "AnyDiff" : currentFolderName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Open Git Repository or Diff (Cmd+O)")
        .popover(isPresented: $showOpenSourcePopover, arrowEdge: .bottom) {
            openSourcePopoverContentView
        }
    }

    @ViewBuilder
    private var readOnlyBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5))
            Text("Read-Only")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(5)
        .fixedSize()
        .help("Read-only mode.")
    }

    @ViewBuilder
    private var openSourcePopoverContentView: some View {
        OpenSourceContentView(
            theme: activeTheme,
            currentLocalPath: currentPath,
            currentComparisonTarget: comparisonTarget,
            isInline: false,
            onOpenLocalFolder: {
                showOpenSourcePopover = false
                openGitRepositoryFolder()
            },
            onSelectLocalPath: { path in
                showOpenSourcePopover = false
                self.currentPath = path
                loadCurrentDirectoryDiff()
            },
            onOpenRemoteURL: { url in
                showOpenSourcePopover = false
                loadRemoteDiff(from: url)
            },
            onOpenInBrowser: {
                openInBrowser()
            },
            onClose: {
                showOpenSourcePopover = false
            }
        )
    }

    @ViewBuilder
    private var hiddenKeyboardShortcuts: some View {
        Group {
            Button(action: { reloadCurrentDiff() }) {}
                .keyboardShortcut("r", modifiers: .command)
            Button(action: { handleOpenShortcut() }) {}
                .keyboardShortcut("o", modifiers: .command)
            Button(action: { openGitRepositoryFolder() }) {}
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(action: { showOpenSourcePopover = true }) {}
                .keyboardShortcut("u", modifiers: .command)
            Button(action: { openInBrowser() }) {}
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button(action: { fontSize = max(9, fontSize - 1) }) {}
                .keyboardShortcut("-", modifiers: .command)
            Button(action: { fontSize = min(28, fontSize + 1) }) {}
                .keyboardShortcut("+", modifiers: .command)
            Button(action: { fontSize = min(28, fontSize + 1) }) {}
                .keyboardShortcut("=", modifiers: .command)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    agentCoordinator.togglePanel()
                }
            }) {}
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button(action: {
                if agentCoordinator.activeReviewSummary != nil {
                    endReview()
                }
            }) {}
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
    }

    private func loadReviewDiff(for summary: AgentEditedFilesSummary) {
        let currentDir = effectiveWorkingDirectory
        let isGit = isGitRepository(at: currentDir)

        // 1. Direct raw diff data attached to the summary
        if let rawData = summary.rawDiffData, !rawData.isEmpty {
            let parsed = GitDiffParser.shared.parseZeroCopy(data: rawData)
            if !parsed.isEmpty {
                loadDiff(files: parsed, rawData: rawData, isReview: true)
                return
            }
        }

        // 2. Fetch turn snapshot diff using the base commit hash
        if isGit, let baseHash = summary.baseCommitHash, !baseHash.isEmpty {
            if let diffData = AgentGitChangesDetector.fetchTurnDiffData(
                workingDirectory: currentDir,
                baseCommit: baseHash,
                pathFilter: Set(summary.filePaths)
            ), !diffData.isEmpty {
                let parsed = GitDiffParser.shared.parseZeroCopy(data: diffData)
                if !parsed.isEmpty {
                    loadDiff(files: parsed, rawData: diffData, isReview: true)
                    return
                }
            }
        }

        // 3. Fallback to working tree path filter
        let pathFilter = Set(summary.filePaths)
        let (files, rawData) = isGit
            ? fetchGitDiffFiles(at: currentDir, target: .workingTree, pathFilter: pathFilter)
            : (files: [], data: nil)

        if !files.isEmpty {
            loadDiff(files: files, rawData: rawData, isReview: true)
        } else {
            var synthText = ""
            for file in summary.files {
                synthText += """
                diff --git a/\(file.path) b/\(file.path)
                --- a/\(file.path)
                +++ b/\(file.path)
                @@ -1,\(max(1, file.deletions)) +1,\(max(1, file.additions)) @@
                -    // Original implementation
                +    // Modified by Agent
                +    // Changes: +\(file.additions) -\(file.deletions)

                """
            }
            let data = Data(synthText.utf8)
            let parsed = GitDiffParser.shared.parseZeroCopy(data: data)
            loadDiff(files: parsed, rawData: data, isReview: true)
        }
    }

    private func beginReview(summary: AgentEditedFilesSummary) {
        reviewViewStateResetToken &+= 1
        clearReviewDiff()
        loadReviewDiff(for: summary)
        preparedReviewSummary = summary
        agentCoordinator.startReview(summary: summary)
    }

    private func endReview() {
        agentCoordinator.exitReview()
        preparedReviewSummary = nil
        clearReviewDiff()
    }

    private func clearReviewDiff() {
        reviewFileDiffs = []
        reviewMultiBuffer.clear()
        reviewDisplayMap.clear()
    }

    private func handleOpenShortcut() {
        if showOpenSourcePopover {
            showOpenSourcePopover = false
            openGitRepositoryFolder()
        } else if fileDiffs.isEmpty {
            openGitRepositoryFolder()
        } else {
            showOpenSourcePopover = true
        }
    }

    @ViewBuilder
    private var windowDropOverlayView: some View {
        if isWindowDropTargeted {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(.accentColor)
                    Text("Drop folder or URL to open")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(activeTheme.background).opacity(0.95))
                        .shadow(color: .black.opacity(0.35), radius: 24)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.accentColor, lineWidth: 2)
                )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func commentModalView(for target: IdentifiableCommentTarget) -> some View {
        AddCommentModal(
            filePath: target.filePath,
            lineNumber: target.lineNumber,
            onAdd: { author, content in
                _ = reviewManager.addComment(filePath: target.filePath, lineNumber: target.lineNumber, author: author, content: content)
                displayMap.rebuild()
                commentTarget = nil
            },
            onCancel: {
                commentTarget = nil
            }
        )
    }

    private func handleOnAppear() {
        if let storedThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") {
            if storedThemeId == "system" {
                followsSystemAppearance = true
            } else if let t = Theme.allThemes.first(where: { $0.id == storedThemeId }) {
                selectedTheme = t
                followsSystemAppearance = false
            }
        }
        if let initial = initialPath, (initial.hasPrefix("http://") || initial.hasPrefix("https://") || initial.contains("github.com") || initial.contains("diffshub.com") || initial.contains("#")) {
            loadRemoteDiff(from: initial)
        } else {
            loadCurrentDirectoryDiff()
        }
        updateWindowAppearance()
    }

    private func handleWindowDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                } else if let string = item as? String, let url = URL(string: string) {
                    targetURL = url
                }
                if let url = targetURL {
                    DispatchQueue.main.async {
                        let path = url.path
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                            self.showOpenSourcePopover = false
                            if isDir.boolValue {
                                self.currentPath = path
                            } else {
                                self.currentPath = (path as NSString).deletingLastPathComponent
                            }
                            self.loadCurrentDirectoryDiff()
                        }
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                var stringVal: String?
                if let url = item as? URL {
                    stringVal = url.absoluteString
                } else if let str = item as? String {
                    stringVal = str
                }
                if let str = stringVal {
                    DispatchQueue.main.async {
                        self.showOpenSourcePopover = false
                        self.loadRemoteDiff(from: str)
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        self.showOpenSourcePopover = false
                        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                            let expanded = (trimmed as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: expanded) {
                                self.currentPath = expanded
                                self.loadCurrentDirectoryDiff()
                                return
                            }
                        }
                        self.loadRemoteDiff(from: trimmed)
                    }
                }
            }
            return true
        }
        return false
    }

    private func openInBrowser() {
        if case .remote(let ref) = comparisonTarget {
            if let url = ref.webURL ?? Optional(ref.diffURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func reloadCurrentDiff() {
        if let reviewSummary = agentCoordinator.activeReviewSummary {
            loadReviewDiff(for: reviewSummary)
            return
        }
        if case .remote(let ref) = comparisonTarget {
            loadRemoteDiff(reference: ref)
        } else {
            loadCurrentDirectoryDiff()
        }
    }

    private func updateWindowAppearance() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.backgroundColor = activeTheme.background
                window.appearance = NSAppearance(named: activeTheme.isDark ? .darkAqua : .aqua)
                window.titlebarSeparatorStyle = .none
            }
        }
    }

    // MARK: - Remote GitHub Diff Loading

    public func loadRemoteDiff(from urlString: String) {
        guard !isReloading else { return }
        switch GitHubDiffService.shared.parseReference(from: urlString) {
        case .success(let ref):
            RecentSourcesManager.shared.addRemoteURL(urlString)
            loadRemoteDiff(reference: ref)
        case .failure(let err):
            self.remoteErrorMessage = err.localizedDescription
        }
    }

    public func loadRemoteDiff(reference: GitHubDiffReference) {
        guard !isReloading else { return }
        if let webURL = reference.webURL?.absoluteString {
            RecentSourcesManager.shared.addRemoteURL(webURL)
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReloading = true
        isStreaming = true
        remoteErrorMessage = nil

        // Clear existing buffers and caches
        multiBuffer.clear()
        displayMap.clear()
        fileDiffs = []
        selectedFilePath = nil

        self.remoteTarget = reference
        self.comparisonTarget = .remote(reference)
        self.currentFolderName = reference.displayTitle
        self.currentBranch = ""
        self.localBranches = []
        self.remoteBranches = []
        self.multiBuffer.baseDirectory = nil
        NSApp.windows.first?.title = reference.displayTitle
        self.repoStatus = .hasChanges

        let task = Task {
            do {
                var allFiles: [FileDiff] = []
                var initialRenderDone = false
                var lastProgressUpdateTime = Date()

                for try await fileDiff in GitHubDiffService.shared.streamDiff(for: reference) {
                    if Task.isCancelled { break }
                    allFiles.append(fileDiff)

                    // 1. Initial Instant Paint (<50ms): show the first file right away
                    if !initialRenderDone && allFiles.count >= 1 {
                        initialRenderDone = true
                        let firstBatch = allFiles
                        await MainActor.run {
                            guard self.loadGeneration == generation else { return }
                            self.fileDiffs = firstBatch
                            self.appendFileDiffsToMultiBuffer(firstBatch)
                            self.displayMap.rebuild()
                            self.displayMap.markContentLoaded()
                            if let first = firstBatch.first {
                                self.selectedFilePath = first.displayPath
                            }
                        }
                    }

                    // 2. Throttle sidebar progress indicator (every 200ms) with ZERO DisplayMap rebuild
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdateTime) >= 0.2 {
                        lastProgressUpdateTime = now
                        let count = allFiles.count
                        await MainActor.run {
                            guard self.loadGeneration == generation else { return }
                            self.streamingCount = count
                        }
                    }
                }

                // 3. Final single atomic commit: append remaining files and rebuild DisplayMap ONCE
                let finalFiles = allFiles
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.multiBuffer.clear()
                    self.displayMap.clear()
                    self.fileDiffs = finalFiles
                    self.appendFileDiffsToMultiBuffer(finalFiles)
                    self.displayMap.rebuild()
                    self.displayMap.markContentLoaded()

                    self.isStreaming = false
                    self.isReloading = false
                    self.remoteLoadTask = nil
                    self.streamingCount = finalFiles.count
                    if self.selectedFilePath == nil, let first = finalFiles.first {
                        self.selectedFilePath = first.displayPath
                    }
                    if finalFiles.isEmpty {
                        self.repoStatus = .clean
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isStreaming = false
                    self.isReloading = false
                    self.remoteLoadTask = nil
                    self.remoteErrorMessage = error.localizedDescription
                }
            }
        }
        remoteLoadTask = task
    }

    private func appendFileDiffsToMultiBuffer(_ files: [FileDiff], rawData: Data? = nil, into destination: MultiBuffer? = nil) {
        let target = destination ?? multiBuffer
        for file in files {
            let fileAdds = file.additions
            let fileDels = file.deletions

            if file.status == .deleted {
                let hunk = file.hunks.first
                let buffer: Buffer
                if let rawData = rawData, let h = hunk, !h.lineSpans.isEmpty {
                    buffer = Buffer(
                        filePath: file.displayPath,
                        storage: .makeDiffFlat(data: rawData, spans: h.lineSpans, side: .old),
                        language: Buffer.detectLanguage(for: file.displayPath),
                        totalAdditions: 0,
                        totalDeletions: fileDels,
                        startLineNumber: 1,
                        fullDiskPath: nil,
                        diskFileLineCount: h.lineSpans.count - h.addedLineCount
                    )
                } else {
                    var oldLines: [String] = []
                    for hunk in file.hunks {
                        for line in hunk.lines {
                            if line.kind == .deleted || line.kind == .unchanged {
                                oldLines.append(line.text)
                            }
                        }
                    }
                    buffer = Buffer(
                        filePath: file.displayPath,
                        lines: [],
                        language: Buffer.detectLanguage(for: file.displayPath),
                        baselineLines: oldLines,
                        totalAdditions: 0,
                        totalDeletions: fileDels,
                        startLineNumber: 1,
                        fullDiskPath: nil,
                        diskFileLineCount: oldLines.count
                    )
                }
                buffer.isFullFile = true
                target.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: .deleted,
                    bufferRange: 0..<0,
                    hunk: hunk,
                    isCollapsed: false,
                    isFileStart: true
                )
                target.addExcerpt(excerpt)
            } else if file.hunks.isEmpty {
                let buffer = Buffer(
                    filePath: file.displayPath,
                    lines: [],
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: [],
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: nil,
                    diskFileLineCount: 0
                )
                buffer.isFullFile = true
                target.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: file.status,
                    bufferRange: 0..<0,
                    hunk: nil,
                    isCollapsed: false,
                    isFileStart: true
                )
                target.addExcerpt(excerpt)
            } else {
                for (hIdx, hunk) in file.hunks.enumerated() {
                    let startLine = hunk.newRange.lowerBound
                    let isLazy = (file.status != .added || file.hunks.count > 1)
                    let buffer: Buffer

                    if let rawData = rawData, !hunk.lineSpans.isEmpty {
                        buffer = Buffer(
                            filePath: file.displayPath,
                            storage: .makeDiffFlat(data: rawData, spans: hunk.lineSpans, side: .new),
                            language: Buffer.detectLanguage(for: file.displayPath),
                            totalAdditions: fileAdds,
                            totalDeletions: fileDels,
                            startLineNumber: startLine,
                            fullDiskPath: nil,
                            diskFileLineCount: nil,
                            isLazySlice: isLazy
                        )
                    } else {
                        let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                        let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                        buffer = Buffer(
                            filePath: file.displayPath,
                            lines: newFileLines,
                            language: Buffer.detectLanguage(for: file.displayPath),
                            baselineLines: oldBaselineLines,
                            totalAdditions: fileAdds,
                            totalDeletions: fileDels,
                            startLineNumber: startLine,
                            fullDiskPath: nil,
                            diskFileLineCount: nil,
                            isLazySlice: isLazy
                        )
                    }
                    buffer.isFullFile = (file.status == .added && file.hunks.count == 1)
                    target.addBuffer(buffer)

                    let excerpt = Excerpt(
                        bufferId: buffer.id,
                        filePath: file.displayPath,
                        fileStatus: file.status,
                        bufferRange: 0..<buffer.lineCount,
                        hunk: hunk,
                        isCollapsed: false,
                        isFileStart: (hIdx == 0)
                    )
                    target.addExcerpt(excerpt)
                }
            }
        }
    }

    // MARK: - Current Directory Diff Loading

    public var effectiveWorkingDirectory: String {
        if let currentPath = currentPath, !currentPath.isEmpty {
            return (currentPath as NSString).expandingTildeInPath
        }
        if let initialPath = initialPath, !initialPath.isEmpty {
            return (initialPath as NSString).expandingTildeInPath
        }
        let cwd = FileManager.default.currentDirectoryPath
        if cwd == "/" || cwd.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return cwd
    }

    public var effectiveBaseDirectory: String {
        if let base = multiBuffer.baseDirectory, !base.isEmpty {
            return (base as NSString).expandingTildeInPath
        }
        return effectiveWorkingDirectory
    }

    public func loadCurrentDirectoryDiff() {
        // A local project must leave remote mode first. Otherwise fetchGitDiff
        // receives `.remote` and intentionally returns no local diff.
        if case .remote = comparisonTarget {
            remoteLoadTask?.cancel()
            remoteLoadTask = nil
            loadGeneration &+= 1
            isReloading = false
            isStreaming = false
            remoteTarget = nil
            remoteErrorMessage = nil
            comparisonTarget = .workingTree
        }

        guard !isReloading else {
            hasPendingGitStateReload = true
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isReloading = true
        let currentDir = effectiveWorkingDirectory
        multiBuffer.baseDirectory = currentDir
        let folderName = (currentDir as NSString).lastPathComponent
        self.currentFolderName = folderName
        DispatchQueue.main.async {
            NSApp.windows.first?.title = "\(folderName)"
        }

        if isWatchModeEnabled {
            let resolvedDir = URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path
            if folderWatcher == nil || folderWatcher?.watchedURL.path != resolvedDir {
                restartWatcher(for: currentDir)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let isGit = self.isGitRepository(at: currentDir)
            let branch = isGit ? self.fetchCurrentBranch(at: currentDir) : ""
            let branches = isGit ? self.fetchAvailableBranches(at: currentDir) : (local: [], remote: [])
            let (files, rawData) = isGit ? self.fetchGitDiffFiles(at: currentDir, target: self.comparisonTarget) : (files: [], data: nil)

            DispatchQueue.main.async {
                guard self.loadGeneration == generation else { return }
                self.currentBranch = branch
                self.localBranches = branches.local
                self.remoteBranches = branches.remote

                defer {
                    self.isReloading = false
                    if self.hasPendingGitStateReload {
                        self.hasPendingGitStateReload = false
                        self.scheduleGitStateReload()
                    }
                }

                guard isGit else {
                    self.repoStatus = .notGitRepository
                    self.loadDiff(files: [])
                    return
                }
                RecentSourcesManager.shared.addLocalPath(currentDir)
                if !files.isEmpty {
                    self.repoStatus = .hasChanges
                    self.loadDiff(files: files, rawData: rawData)
                } else {
                    self.repoStatus = .clean
                    self.loadDiff(files: [])
                }
            }
        }
    }

    private func restartWatcher(for directoryPath: String) {
        folderWatcher?.stop()
        folderWatcher = nil

        guard isWatchModeEnabled, !directoryPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: directoryPath) else { return }

        let resolvedURL = URL(fileURLWithPath: directoryPath).resolvingSymlinksInPath()
        let watcher = FolderWatcher(url: resolvedURL, latency: 0.25) { events in
            DispatchQueue.main.async {
                self.handleFolderWatcherEvents(events)
            }
        }
        watcher.start()
        self.folderWatcher = watcher
    }

    private func scheduleGitStateReload() {
        gitStateReloadWorkItem?.cancel()
        if isReloading {
            hasPendingGitStateReload = true
            return
        }
        let item = DispatchWorkItem { [self] in
            guard self.isWatchModeEnabled else { return }
            if self.isReloading {
                self.hasPendingGitStateReload = true
                return
            }
            self.loadCurrentDirectoryDiff()
        }
        gitStateReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }

    private func handleFolderWatcherEvents(_ events: [FileSystemChangeEvent]) {
        guard isWatchModeEnabled else { return }
        if case .remote = comparisonTarget { return }

        let meaningful = events.filter { !FolderWatcher.shouldIgnore(path: $0.path) }
        guard !meaningful.isEmpty else { return }

        if isReloading {
            hasPendingGitStateReload = true
            return
        }
        // Check if any event was caused by git commit, checkout, branch switch, add/reset
        let hasGitStateChange = meaningful.contains { event in
            event.path.contains("/.git/HEAD")
                || event.path.contains("/.git/refs/")
                || event.path.hasSuffix("/.git/index")
                || event.path.hasSuffix("/.git/packed-refs")
                || event.path.hasSuffix("/.git/commondir")
        }

        if hasGitStateChange {
            scheduleGitStateReload()
            return
        }

        let currentDir = effectiveWorkingDirectory
        let resolvedCurrentDir = URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path

        // Keep concrete relative paths. A watcher batch can contain unrelated
        // files; only these paths are fetched and replaced below.
        var changedPaths = Set<String>()
        var hasRenameEvents = false
        for event in meaningful {
            let eventURL = URL(fileURLWithPath: event.path).resolvingSymlinksInPath()
            let resolvedEventPath = eventURL.path

            // Ignore directory metadata and the repository root itself.
            if resolvedEventPath == resolvedCurrentDir || (event.isDirectory && !event.isFile) {
                continue
            }

            // AnyDiff's own atomic save emits FSEvents too. The exact-path
            // marker suppresses only those events; an external edit remains
            // eligible even when another file is dirty.
            if multiBuffer.isSelfSavedRecentlyExact(filePath: resolvedEventPath, threshold: 3.0) {
                continue
            }

            let prefix = resolvedCurrentDir.hasSuffix("/") ? resolvedCurrentDir : resolvedCurrentDir + "/"
            guard resolvedEventPath.hasPrefix(prefix) else { continue }
            let relative = String(resolvedEventPath.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }

            // Skip files currently being typed in by the user or recently saved
            if multiBuffer.isFileDirty(filePath: relative) || multiBuffer.isSelfSavedRecently(filePath: relative, threshold: 3.0) {
                continue
            }

            changedPaths.insert(relative)
            if event.changeTypes.contains(.renamed) {
                hasRenameEvents = true
            }
        }

        guard !changedPaths.isEmpty else { return }
        pendingWatchPaths.formUnion(changedPaths)
        guard !watchRefreshInFlight else { return }
        startPendingWatchRefresh(directory: resolvedCurrentDir, checkRenames: hasRenameEvents)
    }

    /// Serializes watch reads while coalescing events that arrive during an
    /// in-flight read. No path is discarded when a second event batch arrives.
    private func startPendingWatchRefresh(directory: String, checkRenames: Bool = false) {
        guard !pendingWatchPaths.isEmpty, !watchRefreshInFlight else { return }
        let paths = pendingWatchPaths
        pendingWatchPaths.removeAll()
        watchRefreshInFlight = true

        // Snapshot all currently displayed buffers in O(Excerpts)
        var snapshots: [String: [(BufferId, Int)]] = [:]
        snapshots.reserveCapacity(multiBuffer.excerpts.count)
        for excerpt in multiBuffer.excerpts {
            let version = multiBuffer.buffer(for: excerpt.bufferId)?.version ?? -1
            snapshots[excerpt.filePath, default: []].append((excerpt.bufferId, version))
        }
        watchRefreshGeneration &+= 1
        let refreshGeneration = watchRefreshGeneration
        let target = comparisonTarget

        DispatchQueue.global(qos: .userInitiated).async {
            var effectivePaths = paths
            if checkRenames {
                for path in paths {
                    let renames = self.renamedPaths(at: directory, relatedTo: path)
                    effectivePaths.formUnion(renames)
                }
            }
            let result = self.fetchGitDiffFiles(at: directory, target: target, pathFilter: effectivePaths)
            DispatchQueue.main.async {
                defer {
                    self.watchRefreshInFlight = false
                    if self.isWatchModeEnabled && self.comparisonTarget == target {
                        let currentDir = self.effectiveWorkingDirectory
                        self.startPendingWatchRefresh(directory: URL(fileURLWithPath: currentDir).resolvingSymlinksInPath().path)
                    }
                }
                guard self.isWatchModeEnabled,
                      self.watchRefreshGeneration == refreshGeneration,
                      self.comparisonTarget == target else { return }

                // Group current excerpts by path for fast O(1) comparison
                var currentByPath: [String: [(BufferId, Int)]] = [:]
                for excerpt in self.multiBuffer.excerpts {
                    let version = self.multiBuffer.buffer(for: excerpt.bufferId)?.version ?? -1
                    currentByPath[excerpt.filePath, default: []].append((excerpt.bufferId, version))
                }

                // Dirty buffers and any buffer edited since the read began are
                // left untouched. They will be reflected on a later explicit
                // reload after the user saves/finishes editing.
                let candidatePaths = effectivePaths
                    .union(result.files.map(\.displayPath))
                    .union(result.files.filter { $0.status == .renamed }.map(\.oldPath))
                var safePaths = Set(candidatePaths.filter { path in
                    guard !self.multiBuffer.isFileDirty(filePath: path) else { return false }
                    let current = currentByPath[path] ?? []
                    guard let expected = snapshots[path] else { return current.isEmpty }
                    guard expected.count == current.count else { return false }
                    return expected.elementsEqual(current) { lhs, rhs in
                        lhs.0 == rhs.0 && lhs.1 == rhs.1
                    }
                })
                // A rename is one logical file transition. Never apply only
                // its new side when the old side was edited or changed during
                // the async read; that would duplicate the dirty content.
                for rename in result.files where rename.status == .renamed {
                    guard safePaths.contains(rename.oldPath), safePaths.contains(rename.newPath) else {
                        safePaths.remove(rename.oldPath)
                        safePaths.remove(rename.newPath)
                        safePaths.remove(rename.displayPath)
                        continue
                    }
                }
                guard !safePaths.isEmpty else { return }

                for path in safePaths {
                    let diff = result.files.first { $0.displayPath == path }
                    self.applyWatchedFile(path: path, diff: diff, rawData: result.data)
                }
                self.displayMap.rebuild()
                self.displayMap.markContentLoaded()
                self.updateWatchedFileDiffs(result.files, safePaths: safePaths)
            }
        }
    }

    /// FSEvents reports one side of a rename. Resolve its pair from git's
    /// name-status metadata so the old buffer is removed together with the
    /// new buffer being inserted.
    private func renamedPaths(at directory: String, relatedTo path: String) -> Set<String> {
        guard let output = runGit(arguments: ["-C", directory, "diff", "HEAD", "--name-status", "-M"]) else { return [] }
        var paths = Set<String>()
        for line in output.split(whereSeparator: { $0 == "\n" }) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, fields[0].hasPrefix("R") else { continue }
            if fields[1] == path || fields[2] == path {
                paths.insert(fields[1])
                paths.insert(fields[2])
            }
        }
        return paths
    }

    private func updateWatchedFileDiffs(_ refreshed: [FileDiff], safePaths: Set<String>) {
        let oldFiles = fileDiffs
        let refreshedByDisplay = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.displayPath, $0) })
        let renamedByOld = Dictionary(uniqueKeysWithValues: refreshed.filter { $0.status == .renamed }.map { ($0.oldPath, $0) })
        var updated: [FileDiff] = []
        var consumed = Set<String>()

        for oldFile in oldFiles {
            if let rename = renamedByOld[oldFile.displayPath], safePaths.contains(oldFile.displayPath) {
                updated.append(rename)
                consumed.insert(rename.displayPath)
            } else if safePaths.contains(oldFile.displayPath) {
                if let replacement = refreshedByDisplay[oldFile.displayPath] {
                    updated.append(replacement)
                    consumed.insert(replacement.displayPath)
                }
            } else {
                updated.append(oldFile)
            }
        }

        // New/untracked paths are appended in parser order, which is stable
        // for a single filtered git invocation.
        for file in refreshed where safePaths.contains(file.displayPath) && !consumed.contains(file.displayPath) {
            updated.append(file)
        }
        fileDiffs = updated
        if fileDiffs.isEmpty {
            repoStatus = .clean
            selectedFilePath = nil
        } else {
            repoStatus = .hasChanges
            if let current = selectedFilePath,
               (fileDiffs.contains(where: { $0.displayPath == current || $0.newPath == current || $0.oldPath == current }) ||
                multiBuffer.excerpts.contains(where: { $0.filePath == current })) {
                // Keep existing selection intact, do not jump to first file
            } else {
                selectedFilePath = fileDiffs.first?.displayPath
            }
        }
    }

    private func isGitRepository(at path: String) -> Bool {
        return runGit(arguments: ["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
    }

    private func fetchCurrentBranch(at path: String) -> String {
        runGit(arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
    }

    private func fetchAvailableBranches(at path: String) -> (local: [String], remote: [String]) {
        let localOut = runGit(arguments: ["-C", path, "branch", "--format=%(refname:short)"]) ?? ""
        let local = localOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let remoteOut = runGit(arguments: ["-C", path, "branch", "-r", "--format=%(refname:short)"]) ?? ""
        let remote = remoteOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.contains("HEAD") }

        return (local, remote)
    }

    private func fetchGitDiffFiles(at path: String, target: ComparisonTarget = .workingTree, pathFilter: Set<String>? = nil) -> (files: [FileDiff], data: Data?) {
        let argumentSets: [[String]]
        switch target {
        case .workingTree:
            argumentSets = [
                ["-C", path, "diff", "HEAD"],
                ["-C", path, "diff"],
                ["-C", path, "diff", "--staged"]
            ]
        case .baseBranch(let base):
            argumentSets = [
                ["-C", path, "diff", "\(base)..."],
                ["-C", path, "diff", "\(base)..HEAD"]
            ]
        case .directBranch(let branch):
            argumentSets = [
                ["-C", path, "diff", branch]
            ]
        case .remote:
            return (files: [], data: nil)
        }

        var allFiles: [FileDiff] = []
        var rawData: Data? = nil
        for baseArgs in argumentSets {
            var args = baseArgs
            if let pathFilter, !pathFilter.isEmpty {
                args += ["--"] + pathFilter.sorted()
            }
            if let data = runGitData(arguments: args) {
                let files = GitDiffParser.shared.parseZeroCopy(data: data)
                if !files.isEmpty {
                    allFiles = files
                    rawData = data
                    break
                }
            }
        }
        if case .workingTree = target {
            let untracked = fetchUntrackedFiles(at: path, pathFilter: pathFilter)
            allFiles.append(contentsOf: untracked)
        }
        allFiles = filterIgnoredFiles(allFiles, at: path)
        return (files: allFiles, data: rawData)
    }

    private func filterIgnoredFiles(_ files: [FileDiff], at directory: String) -> [FileDiff] {
        guard !files.isEmpty else { return [] }
        let paths = files.map(\.displayPath)
        let ignoredPaths = fetchIgnoredPaths(paths: paths, at: directory)
        guard !ignoredPaths.isEmpty else { return files }
        return files.filter {
            !ignoredPaths.contains($0.displayPath) &&
            !ignoredPaths.contains($0.newPath) &&
            !ignoredPaths.contains($0.oldPath)
        }
    }

    private func fetchIgnoredPaths(paths: [String], at directory: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var result = Set<String>()
        let batchSize = 250
        for i in stride(from: 0, to: paths.count, by: batchSize) {
            let batch = Array(paths[i..<min(i + batchSize, paths.count)])
            var args = ["-C", directory, "check-ignore", "--no-index", "--"]
            args.append(contentsOf: batch)
            if let output = runGit(arguments: args), !output.isEmpty {
                let ignored = output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                result.formUnion(ignored)
            }
        }
        return result
    }

    private func fetchUntrackedFiles(at path: String, pathFilter: Set<String>? = nil) -> [FileDiff] {
        var args = ["-C", path, "ls-files", "--others", "--exclude-standard"]
        if let pathFilter, !pathFilter.isEmpty {
            args += ["--"] + pathFilter.sorted()
        }
        guard let output = runGit(arguments: args), !output.isEmpty else {
            return []
        }
        let filePaths = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && (pathFilter == nil || pathFilter!.contains($0)) }
        var result: [FileDiff] = []
        for relPath in filePaths {
            let fullPath = URL(fileURLWithPath: path).appendingPathComponent(relPath).path
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            let diffLines = lines.enumerated().map { (idx, text) in
                DiffLine(kind: .added, text: text, oldLineNumber: nil, newLineNumber: idx + 1)
            }
            let hunk = DiffHunk(
                oldRange: 0..<0,
                newRange: 1..<(lines.count + 1),
                header: "",
                lines: diffLines,
                addedLineCount: lines.count,
                deletedLineCount: 0
            )
            let fileDiff = FileDiff(
                oldPath: relPath,
                newPath: relPath,
                status: .added,
                hunks: [hunk]
            )
            result.append(fileDiff)
        }
        return result
    }

    /// Applies one watch result in-place. The temporary builder gives the
    /// refreshed file the same construction rules as a normal diff load while
    /// `MultiBuffer.replaceFile` keeps every unrelated buffer/excerpt intact.
    private func applyWatchedFile(path: String, diff: FileDiff?, rawData: Data?) {
        let collapsed = multiBuffer.excerpts
            .filter { $0.filePath == path }
            .contains { $0.isCollapsed }

        let rebuilt = MultiBuffer()
        rebuilt.baseDirectory = multiBuffer.baseDirectory
        if let diff {
            appendFileDiffsToMultiBuffer([diff], rawData: rawData, into: rebuilt)
        }

        let baseDir = effectiveBaseDirectory
        let fullPath = URL(fileURLWithPath: baseDir).appendingPathComponent(path).path
        for buffer in rebuilt.buffers.values {
            buffer.fullDiskPath = fullPath
        }
        var newExcerpts = rebuilt.excerpts
        if collapsed {
            for index in newExcerpts.indices {
                newExcerpts[index].isCollapsed = true
            }
        }
        multiBuffer.replaceFile(
            filePath: path,
            buffers: Array(rebuilt.buffers.values),
            excerpts: newExcerpts
        )
    }

    private func runGit(arguments: [String]) -> String? {
        if let data = runGitData(arguments: arguments) {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func runGitData(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: - Diff Loading & MultiBuffer Assembly

    public func loadDiff(text: String) {
        let data = Data(text.utf8)
        loadDiff(data: data)
    }

    public func loadDiff(data: Data) {
        let parsedFiles = GitDiffParser.shared.parseZeroCopy(data: data)
        loadDiff(files: parsedFiles, rawData: data)
    }

    public func loadDiff(files parsedFiles: [FileDiff], rawData: Data? = nil, isReview: Bool = false) {
        let targetMB = isReview ? reviewMultiBuffer : multiBuffer
        let targetDM = isReview ? reviewDisplayMap : displayMap

        let collapsedFilePaths = Set(targetMB.excerpts.filter { $0.isCollapsed }.map { $0.filePath })
        if isReview {
            self.reviewFileDiffs = parsedFiles
        } else {
            self.fileDiffs = parsedFiles
        }

        targetMB.clear()
        targetDM.clear()
        LineLayoutCache.shared.clear()
        SyntaxHighlighter.shared.clearCache()

        let baseDir = effectiveBaseDirectory

        for file in parsedFiles {
            let relativePath = file.displayPath
            let wasCollapsed = collapsedFilePaths.contains(relativePath)
            var fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: fullPath) {
                let components = relativePath.components(separatedBy: "/")
                if components.count > 1 {
                    let subPath = components.dropFirst().joined(separator: "/")
                    let altPath = (baseDir as NSString).appendingPathComponent(subPath)
                    if FileManager.default.fileExists(atPath: altPath) {
                        fullPath = altPath
                    }
                }
            }

            let fileAdds = file.additions
            let fileDels = file.deletions

            if file.hunks.isEmpty {
                let buffer = Buffer(
                    filePath: file.displayPath,
                    lines: [],
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: [],
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: fullPath,
                    diskFileLineCount: nil
                )
                buffer.isFullFile = true
                targetMB.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: file.status,
                    bufferRange: 0..<0,
                    hunk: nil,
                    isCollapsed: wasCollapsed,
                    isFileStart: true
                )
                targetMB.addExcerpt(excerpt)
            } else if file.status == .deleted {
                let hunk = file.hunks.first
                let buffer: Buffer
                if let rawData = rawData, let h = hunk, !h.lineSpans.isEmpty {
                    buffer = Buffer(
                        filePath: file.displayPath,
                        storage: .makeDiffFlat(data: rawData, spans: h.lineSpans, side: .old),
                        language: Buffer.detectLanguage(for: file.displayPath),
                        totalAdditions: 0,
                        totalDeletions: fileDels,
                        startLineNumber: 1,
                        fullDiskPath: fullPath,
                        diskFileLineCount: h.lineSpans.count - h.addedLineCount
                    )
                } else {
                    var oldLines: [String] = []
                    for hunk in file.hunks {
                        for line in hunk.lines {
                            if line.kind == .deleted || line.kind == .unchanged {
                                oldLines.append(line.text)
                            }
                        }
                    }
                    buffer = Buffer(
                        filePath: file.displayPath,
                        lines: [],
                        language: Buffer.detectLanguage(for: file.displayPath),
                        baselineLines: oldLines,
                        totalAdditions: 0,
                        totalDeletions: fileDels,
                        startLineNumber: 1,
                        fullDiskPath: fullPath,
                        diskFileLineCount: oldLines.count
                    )
                }
                buffer.isFullFile = true
                targetMB.addBuffer(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: .deleted,
                    bufferRange: 0..<0,
                    hunk: hunk,
                    isCollapsed: wasCollapsed,
                    isFileStart: true
                )
                targetMB.addExcerpt(excerpt)
            } else {
                for (hIdx, hunk) in file.hunks.enumerated() {
                    let startLine = hunk.newRange.lowerBound
                    let isLazy = (file.status != .added || file.hunks.count > 1)
                    let buffer: Buffer

                    if let rawData = rawData, !hunk.lineSpans.isEmpty {
                        buffer = Buffer(
                            filePath: file.displayPath,
                            storage: .makeDiffFlat(data: rawData, spans: hunk.lineSpans, side: .new),
                            language: Buffer.detectLanguage(for: file.displayPath),
                            totalAdditions: fileAdds,
                            totalDeletions: fileDels,
                            startLineNumber: startLine,
                            fullDiskPath: fullPath,
                            diskFileLineCount: nil,
                            isLazySlice: isLazy
                        )
                    } else {
                        let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                        let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                        buffer = Buffer(
                            filePath: file.displayPath,
                            lines: newFileLines,
                            language: Buffer.detectLanguage(for: file.displayPath),
                            baselineLines: oldBaselineLines,
                            totalAdditions: fileAdds,
                            totalDeletions: fileDels,
                            startLineNumber: startLine,
                            fullDiskPath: fullPath,
                            diskFileLineCount: nil,
                            isLazySlice: isLazy
                        )
                    }
                    buffer.isFullFile = (file.status == .added && file.hunks.count == 1)
                    targetMB.addBuffer(buffer)

                    let excerpt = Excerpt(
                        bufferId: buffer.id,
                        filePath: file.displayPath,
                        fileStatus: file.status,
                        bufferRange: 0..<buffer.lineCount,
                        hunk: hunk,
                        isCollapsed: wasCollapsed,
                        isFileStart: (hIdx == 0)
                    )
                    targetMB.addExcerpt(excerpt)
                }
            }
        }

        targetDM.rebuild()
        targetDM.markContentLoaded()

        let currentSelected = selectedFilePath
        if let sel = currentSelected, parsedFiles.contains(where: { $0.displayPath == sel }) {
            self.selectedFilePath = sel
        } else if self.selectedFilePath == nil || !parsedFiles.contains(where: { $0.displayPath == self.selectedFilePath }) {
            self.selectedFilePath = parsedFiles.first?.displayPath
        }
    }

    private func openGitRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository to view uncommitted diffs"

        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            self.currentPath = path
            // `loadCurrentDirectoryDiff` handles cancellation and the mode
            // transition from a remote stream to the selected local project.
            loadCurrentDirectoryDiff()
        }
    }

    private func expandAllExcerpts() {
        for i in 0..<activeMultiBuffer.excerpts.count {
            activeMultiBuffer.expandExcerptAll(at: i)
        }
        activeDisplayMap.rebuild()
    }

    private func collapseAllExcerpts() {
        activeMultiBuffer.collapseAll()
        activeDisplayMap.rebuild()
    }
}

struct IdentifiableCommentTarget: Identifiable {
    var id: String { "\(filePath):\(lineNumber)" }
    let filePath: String
    let lineNumber: Int
}

public struct ToolbarHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(minWidth: 26, minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.secondary.opacity(configuration.isPressed ? 0.24 : 0.14) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct AgentToolbarActionButtonStyle: ButtonStyle {
    private let accentColor: Color
    private let isActive: Bool
    @State private var isHovered = false

    public init(accentColor: Color = .accentColor, isActive: Bool = false) {
        self.accentColor = accentColor
        self.isActive = isActive
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isActive || isHovered || configuration.isPressed

        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(minWidth: 26, minHeight: 24)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accentColor.opacity(isHighlighted ? 0.08 : 0))
            )
            .scaleEffect(isHovered ? 1.02 : 1)
            .shadow(
                color: isHighlighted ? accentColor.opacity(0.16) : Color.clear,
                radius: isHighlighted ? 9 : 5,
                y: isHighlighted ? 2 : 1
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}
