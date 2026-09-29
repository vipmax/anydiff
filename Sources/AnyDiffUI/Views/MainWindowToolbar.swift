import SwiftUI
import AnyDiffCore

public struct MainWindowToolbarLeadingView: View {
    @ObservedObject public var repo: RepoCoordinator
    public let theme: Theme
    @Binding public var showOpenSourcePopover: Bool
    public let onOpenInBrowser: () -> Void

    public init(
        repo: RepoCoordinator,
        theme: Theme,
        showOpenSourcePopover: Binding<Bool>,
        onOpenInBrowser: @escaping () -> Void
    ) {
        self.repo = repo
        self.theme = theme
        self._showOpenSourcePopover = showOpenSourcePopover
        self.onOpenInBrowser = onOpenInBrowser
    }

    public var body: some View {
        HStack(spacing: 6) {
            if case .remote(let ref) = repo.comparisonTarget {
                remoteHeaderButton(for: ref)
            } else {
                localHeaderButton

                if repo.repoStatus != .notGitRepository && !repo.currentBranch.isEmpty {
                    BranchPickerView(
                        currentBranch: repo.currentBranch,
                        localBranches: repo.localBranches,
                        remoteBranches: repo.remoteBranches,
                        comparisonTarget: $repo.comparisonTarget,
                        onSelectTarget: { target in
                            repo.comparisonTarget = target
                            repo.loadCurrentDirectoryDiff()
                        }
                    )
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
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
            popoverContentView
        }
    }

    @ViewBuilder
    private var localHeaderButton: some View {
        Button(action: { showOpenSourcePopover.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(repo.currentFolderName.isEmpty ? "AnyDiff" : repo.currentFolderName)
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
            popoverContentView
        }
    }

    @ViewBuilder
    private var popoverContentView: some View {
        OpenSourceContentView(
            theme: theme,
            currentLocalPath: repo.currentPath,
            currentComparisonTarget: repo.comparisonTarget,
            isInline: false,
            onOpenLocalFolder: {
                showOpenSourcePopover = false
                repo.openGitRepositoryFolder()
            },
            onSelectLocalPath: { path in
                showOpenSourcePopover = false
                repo.currentPath = path
                repo.loadCurrentDirectoryDiff()
            },
            onOpenRemoteURL: { url in
                showOpenSourcePopover = false
                repo.loadRemoteDiff(from: url)
            },
            onOpenInBrowser: {
                onOpenInBrowser()
            },
            onClose: {
                showOpenSourcePopover = false
            }
        )
    }
}

public struct RightPanelToggleButton: View {
    public let isOpen: Bool
    public let title: String
    public let onToggle: () -> Void

    public init(isOpen: Bool, title: String, onToggle: @escaping () -> Void) {
        self.isOpen = isOpen
        self.title = title
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            Label(isOpen ? "Hide \(title)" : "Show \(title)", systemImage: "sidebar.right")
        }
        .help(isOpen ? "Hide \(title) (Cmd+Opt+A)" : "Show \(title) (Cmd+Opt+A)")
    }
}
