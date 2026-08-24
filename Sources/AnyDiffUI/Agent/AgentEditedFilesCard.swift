import SwiftUI
import AnyDiffCore

public struct AgentEditedFilesCard: View {
    public let summary: AgentEditedFilesSummary
    public let theme: Theme
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isReviewHovered: Bool = false
    @State private var isRevertHovered: Bool = false
    @State private var isRestoreHovered: Bool = false

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRevert: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRestore: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.summary = summary
        self.theme = theme
        self.onReview = onReview
        self.onRevert = onRevert
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row
            HStack(alignment: .center, spacing: 10) {
                // Left Icon Box
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                        )

                    Image(systemName: summary.isReverted ? "arrow.uturn.backward" : "square.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(summary.isReverted ? Color(theme.gutterForeground) : Color(theme.foreground).opacity(0.9))
                }

                // Title & Delta Counters
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(summary.isReverted ? Color(theme.gutterForeground) : Color(theme.foreground))

                    if summary.isReverted {
                        Text("Changes reverted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                    } else {
                        HStack(spacing: 5) {
                            if summary.totalAdditions > 0 {
                                Text("+\(summary.totalAdditions)")
                                    .foregroundColor(Color.green.opacity(0.95))
                            }
                            if summary.totalDeletions > 0 {
                                Text("-\(summary.totalDeletions)")
                                    .foregroundColor(Color.red.opacity(0.95))
                            }
                        }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }

                Spacer()

                if summary.isReverted {
                    // Restore Button
                    Button(action: {
                        onRestore?(summary)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Restore")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(isRestoreHovered ? Color.blue.opacity(0.95) : Color(theme.foreground).opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isRestoreHovered ? Color.blue.opacity(0.14) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isRestoreHovered ? Color.blue.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isRestoreHovered = hovering
                    }
                    .help("Restore changes that were reverted")
                } else {
                    // Revert Button
                    Button(action: {
                        onRevert?(summary)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Revert")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(isRevertHovered ? Color.red.opacity(0.95) : Color(theme.foreground).opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isRevertHovered ? Color.red.opacity(0.14) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isRevertHovered ? Color.red.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isRevertHovered = hovering
                    }
                    .help("Revert changes made during this turn")

                    // Review Button
                    Button(action: {
                        onReview?(summary)
                    }) {
                        Text("Review")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(theme.foreground))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isReviewHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.09))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isReviewHovered = hovering
                    }
                }
            }

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.8)

            // File Rows
            VStack(spacing: 8) {
                ForEach(summary.files) { file in
                    fileRow(file)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func fileRow(_ file: AgentEditedFileItem) -> some View {
        HStack(alignment: .center, spacing: 6) {
            // Path: Directory (muted) + Filename (prominent)
            HStack(spacing: 0) {
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.9))
                }
                Text(file.filename)
                    .fontWeight(.semibold)
                    .foregroundColor(Color(theme.foreground))
            }
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 12)

            // Stats (+ / -)
            HStack(spacing: 4) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundColor(Color.green.opacity(0.95))
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .foregroundColor(Color.red.opacity(0.95))
                }
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
    }
}
