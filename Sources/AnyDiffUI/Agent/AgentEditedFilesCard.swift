import SwiftUI
import AnyDiffCore

public struct AgentEditedFilesCard: View {
    public let summary: AgentEditedFilesSummary
    public let theme: Theme
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isReviewHovered: Bool = false

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.summary = summary
        self.theme = theme
        self.onReview = onReview
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

                    Image(systemName: "square.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(theme.foreground).opacity(0.9))
                }

                // Title & Delta Counters
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))

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

                Spacer()

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
