import SwiftUI
import AnyDiffCore

public struct EmptyDiffView: View {
    public let theme: Theme
    public let loadableWorkingDirectory: String?
    public let repoStatus: RepoCoordinator.RepoStatus
    public let currentFolderName: String
    public let currentLocalPath: String?
    public let currentComparisonTarget: ComparisonTarget
    public let onOpenLocalFolder: () -> Void
    public let onSelectLocalPath: (String) -> Void
    public let onOpenRemoteURL: (String) -> Void
    public let onOpenInBrowser: () -> Void

    public init(
        theme: Theme,
        loadableWorkingDirectory: String?,
        repoStatus: RepoCoordinator.RepoStatus,
        currentFolderName: String,
        currentLocalPath: String?,
        currentComparisonTarget: ComparisonTarget,
        onOpenLocalFolder: @escaping () -> Void,
        onSelectLocalPath: @escaping (String) -> Void,
        onOpenRemoteURL: @escaping (String) -> Void,
        onOpenInBrowser: @escaping () -> Void
    ) {
        self.theme = theme
        self.loadableWorkingDirectory = loadableWorkingDirectory
        self.repoStatus = repoStatus
        self.currentFolderName = currentFolderName
        self.currentLocalPath = currentLocalPath
        self.currentComparisonTarget = currentComparisonTarget
        self.onOpenLocalFolder = onOpenLocalFolder
        self.onSelectLocalPath = onSelectLocalPath
        self.onOpenRemoteURL = onOpenRemoteURL
        self.onOpenInBrowser = onOpenInBrowser
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                statusHeaderView

                OpenSourceContentView(
                    theme: theme,
                    currentLocalPath: currentLocalPath,
                    currentComparisonTarget: currentComparisonTarget,
                    isInline: true,
                    onOpenLocalFolder: onOpenLocalFolder,
                    onSelectLocalPath: onSelectLocalPath,
                    onOpenRemoteURL: onOpenRemoteURL,
                    onOpenInBrowser: onOpenInBrowser
                )
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(theme.background))
    }

    @ViewBuilder
    private var statusHeaderView: some View {
        VStack(spacing: 6) {
            if loadableWorkingDirectory == nil {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                Text("Choose a Git Repository")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))

                Text("Open a repository to view its changes.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))
            } else if repoStatus == .notGitRepository {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                Text("Not a Git Repository")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))

                Text(currentFolderName.isEmpty ? "Current folder is not a Git repository." : "\"\(currentFolderName)\" is not a Git repository.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                Text("No Uncommitted Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))

                Text("Working tree in \(currentFolderName.isEmpty ? "project" : "\"\(currentFolderName)\"") is clean.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))
            }
        }
        .padding(.bottom, 4)
    }
}

public struct SearchEmptyStateView: View {
    public let query: String
    public let folderName: String
    public let theme: Theme

    public init(query: String, folderName: String, theme: Theme) {
        self.query = query
        self.folderName = folderName
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

            Text("No Matches Found")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(theme.foreground))

            Text("No results matching \"\(query)\" in \(folderName.isEmpty ? "project" : "\"\(folderName)\"").")
                .font(.system(size: 12))
                .foregroundColor(Color(theme.gutterForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(theme.background))
    }
}
