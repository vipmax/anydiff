import SwiftUI
import AnyDiffCore

public struct AgentEditedFilesCard: View {
    public let summary: AgentEditedFilesSummary
    public let theme: Theme
    public var accentColor: Color
    public let disableAgentColors: Bool
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isReviewHovered: Bool = false
    @State private var isRevertHovered: Bool = false
    @State private var isRestoreHovered: Bool = false

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color = .accentColor,
        disableAgentColors: Bool = false,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRevert: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRestore: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.disableAgentColors = disableAgentColors
        self.onReview = onReview
        self.onRevert = onRevert
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Left Title, Right Actions & Stats
            HStack(alignment: .center, spacing: 8) {
                // Title (Left aligned)
                Text(summary.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(summary.isReverted ? Color(theme.gutterForeground) : Color(theme.foreground))

                Spacer()

                // Actions & Stats (Right aligned: Revert, Review, +/-)
                HStack(alignment: .center, spacing: 8) {
                    if summary.isReverted {
                        // Restore Button
                        Button(action: {
                            onRestore?(summary)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Restore")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(isRestoreHovered ? Color.blue.opacity(0.95) : Color(theme.foreground).opacity(0.85))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isRestoreHovered ? Color.blue.opacity(0.16) : Color.white.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isRestoreHovered = $0 }
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
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(isRevertHovered ? Color.red.opacity(0.95) : Color(theme.foreground).opacity(0.85))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isRevertHovered ? Color.red.opacity(0.16) : Color.white.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isRevertHovered = $0 }
                        .help("Revert changes made during this turn")

                        // Review Button
                        Button(action: {
                            onReview?(summary)
                        }) {
                            Text("Review")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(isReviewHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.95))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isReviewHovered ? accentColor.opacity(0.28) : accentColor.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { isReviewHovered = $0 }
                        .help("Review diff in MultiBuffer editor")
                    }

                    // Delta Counters (+ / -) on the far right
                    if !summary.isReverted {
                        HStack(spacing: 5) {
                            if summary.totalAdditions > 0 {
                                Text("+\(summary.totalAdditions)")
                                    .foregroundColor(fileStatColor(.green))
                            }
                            if summary.totalDeletions > 0 {
                                Text("-\(summary.totalDeletions)")
                                    .foregroundColor(fileStatColor(.red))
                            }
                        }
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    }
                }
            }

            // Divider
            Rectangle()
                .fill(accentColor.opacity(0.12))
                .frame(height: 0.8)

            // File Rows
            VStack(spacing: 7) {
                ForEach(summary.files) { file in
                    fileRow(file)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.12),
                            accentColor.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                )
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
                        .foregroundColor(fileStatColor(.green))
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .foregroundColor(fileStatColor(.red))
                }
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
    }

    private func fileStatColor(_ color: Color) -> Color {
        color.opacity(0.95)
    }
}
