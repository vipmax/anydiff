import SwiftUI
import AppKit
import AnyDiffCore

/// Popover displaying the complete commit message, author metadata, diff statistics, and changed files list.
public struct CommitDetailPopoverView: View {
    public var commit: GitCommit
    public var theme: Theme
    public var directory: String
    public var fileCount: Int
    public var additions: Int
    public var deletions: Int
    public var preloadedFiles: [CommitFileChange]
    public var onSelectFile: ((CommitFileChange) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?

    @State private var loadedFiles: [CommitFileChange] = []
    @State private var isLoadingFiles: Bool = false
    @State private var hasCopiedHash: Bool = false
    @State private var hasCopiedMessage: Bool = false
    @State private var isCopyHashHovered: Bool = false
    @State private var isMessageHovered: Bool = false
    @State private var isCopyMessageBtnHovered: Bool = false
    @State private var hoveredFilePath: String? = nil

    public init(
        commit: GitCommit,
        theme: Theme,
        directory: String = "",
        fileCount: Int? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        files: [CommitFileChange] = [],
        onSelectFile: ((CommitFileChange) -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.commit = commit
        self.theme = theme
        self.directory = directory
        self.fileCount = fileCount ?? (commit.filesChanged > 0 ? commit.filesChanged : 0)
        self.additions = additions ?? (commit.additions > 0 ? commit.additions : 0)
        self.deletions = deletions ?? (commit.deletions > 0 ? commit.deletions : 0)
        self.preloadedFiles = files
        self.onSelectFile = onSelectFile
        self.onOpen = onOpen
        self.onClose = onClose
    }

    private var fullMessage: String {
        if commit.body.isEmpty {
            return commit.summary
        }
        return "\(commit.summary)\n\n\(commit.body)"
    }

    private var displayFiles: [CommitFileChange] {
        if !preloadedFiles.isEmpty {
            return preloadedFiles
        }
        return loadedFiles
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                // 1. Author, email, date & hash with copy icon
                headerSection

                Divider()
                    .padding(.vertical, 2)

                // 2. Commit message (flexed with copy button, no background)
                messageSection

                Divider()
                    .padding(.vertical, 2)

                // 3. Changed files section
                filesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 410)
        .frame(maxHeight: 420)
        .onAppear {
            loadFilesIfNeeded()
        }
    }

    // MARK: - Section 1: Header (Author, email, date & hash with copy icon)
    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 1. Author & email
            HStack(spacing: 4) {
                Text(commit.authorName.isEmpty ? "unknown" : commit.authorName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)

                if !commit.authorEmail.isEmpty {
                    Text("<\(commit.authorEmail)>")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // 2. Date
            Text(Self.formatDate(commit.date))
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Hash with copy icon right next to it, plus refs
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(commit.shortHash)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)

                    Button(action: copyHash) {
                        Image(systemName: hasCopiedHash ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(hasCopiedHash ? .green : (isCopyHashHovered ? .primary : .secondary))
                    }
                    .buttonStyle(.plain)
                    .help(hasCopiedHash ? "Copied" : "Copy Hash")
                    .onHover { isCopyHashHovered = $0 }
                }

                // Attached branches / tags if any
                ForEach(commit.refs, id: \.name) { ref in
                    HStack(spacing: 3) {
                        Image(systemName: ref.type.isTag ? "tag.fill" : "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(ref.shortName)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Section 2: Commit Message (Flexed with hover copy button, no background)
    @ViewBuilder
    private var messageSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.summary)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !commit.body.isEmpty {
                    Text(commit.body)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copyMessage) {
                Image(systemName: hasCopiedMessage ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundColor(hasCopiedMessage ? .green : (isCopyMessageBtnHovered ? .primary : .secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasCopiedMessage ? "Message Copied" : "Copy Message")
            .opacity(isMessageHovered || hasCopiedMessage ? 1 : 0)
            .onHover { isCopyMessageBtnHovered = $0 }
        }
        .contentShape(Rectangle())
        .onHover { isMessageHovered = $0 }
        .textSelection(.enabled)
    }

    // MARK: - Section 3: Changed Files
    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            let filesCount = fileCount > 0 ? fileCount : (displayFiles.isEmpty ? commit.filesChanged : displayFiles.count)
            let totalAdds = additions > 0 ? additions : commit.additions
            let totalDels = deletions > 0 ? deletions : commit.deletions

            HStack(spacing: 6) {
                Text("CHANGED FILES (\(filesCount))")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)

                if isLoadingFiles {
                    ProgressView()
                        .controlSize(.mini)
                }

                Spacer()

                if totalAdds > 0 {
                    Text(verbatim: "+\(totalAdds)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffAddedGutter))
                }

                if totalDels > 0 {
                    Text(verbatim: "-\(totalDels)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(theme.diffDeletedGutter))
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            ForEach(displayFiles) { file in
                fileRow(file)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: CommitFileChange) -> some View {
        let isHovered = hoveredFilePath == file.path

        HStack(spacing: 6) {
            Image(systemName: fileIcon(for: file.path))
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .frame(width: 14)

            Text(file.fileName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if !file.directoryPath.isEmpty {
                Text(file.directoryPath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if file.additions > 0 {
                Text(verbatim: "+\(file.additions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.diffAddedGutter))
            }

            if file.deletions > 0 {
                Text(verbatim: "-\(file.deletions)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.diffDeletedGutter))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onClose?()
            if let onSelectFile = onSelectFile {
                onSelectFile(file)
            } else if let onOpen = onOpen {
                onOpen()
            }
        }
        .onHover { hovered in
            hoveredFilePath = hovered ? file.path : nil
        }
    }

    private func fileIcon(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "icns": return "photo"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc"
        }
    }

    // MARK: - Actions
    private func loadFilesIfNeeded() {
        guard preloadedFiles.isEmpty, !directory.isEmpty else { return }
        isLoadingFiles = true
        let dir = directory
        let hash = commit.hash
        DispatchQueue.global(qos: .userInitiated).async {
            let files = GitLogReader.shared.readCommitFiles(directory: dir, hash: hash)
            DispatchQueue.main.async {
                self.loadedFiles = files
                self.isLoadingFiles = false
            }
        }
    }

    private func copyHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
        hasCopiedHash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            hasCopiedHash = false
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullMessage, forType: .string)
        hasCopiedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            hasCopiedMessage = false
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let dateStr = formatter.string(from: date)
        let relStr = formatRelativeDate(date)
        return "\(dateStr) (\(relStr))"
    }

    private static func formatRelativeDate(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            let mins = max(1, Int(seconds / 60))
            return "\(mins)m ago"
        } else if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(seconds / 86400)
            return "\(days)d ago"
        }
    }
}
