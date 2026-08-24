import SwiftUI
import AnyDiffCore

public struct AgentToolCallCard: View {
    public let item: ToolCallItem
    public let theme: Theme
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isExpanded: Bool = false
    @State private var isDiffStatsHovered: Bool = false

    public init(item: ToolCallItem, theme: Theme, onReview: ((AgentEditedFilesSummary) -> Void)? = nil) {
        self.item = item
        self.theme = theme
        self.onReview = onReview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header Row
            HStack(spacing: 6) {
                // Action Pill Badge
                HStack(spacing: 4) {
                    toolIcon
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.shortToolName)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(actionBadgeBackground)
                .foregroundColor(actionBadgeForeground)
                .cornerRadius(6)

                // Title / Path
                Text(item.displayTitle)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(theme.foreground))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Diff Stats (+ / -)
                if item.additionsCount != nil || item.deletionsCount != nil {
                    Button(action: {
                        if let summary = item.createEditedFilesSummary() {
                            onReview?(summary)
                        }
                    }) {
                        HStack(spacing: 4) {
                            if let adds = item.additionsCount, adds > 0 {
                                Text("+\(adds)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            if let dels = item.deletionsCount, dels > 0 {
                                Text("-\(dels)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(Color.secondary.opacity(isDiffStatsHovered ? 0.15 : 0))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .onHover { isDiffStatsHovered = $0 }
                    .help("Review this file's diff in MultiBuffer")
                }

                // Status Indicator
                statusIndicator

                // Chevron
                if hasExpandableContent {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                }
            }

            // Description / Instruction
            if let desc = item.descriptionText, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(Color(theme.foreground).opacity(0.85))
                    .lineLimit(isExpanded ? nil : 2)
            } else if let summary = item.summary, !summary.isEmpty, !hasExpandableContent {
                Text(summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground))
                    .lineLimit(isExpanded ? nil : 2)
            }

            // Expandable Details (Diff, Command Output, Snippet)
            if isExpanded && hasExpandableContent {
                expandableContentView
                    .padding(.top, 2)
                    .padding(.bottom, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(actionBadgeForeground.opacity(item.status == .running ? 0.16 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(actionBadgeForeground.opacity(item.status == .running ? 0.50 : 0.32), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasExpandableContent {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        }
    }

    private var hasExpandableContent: Bool {
        if item.oldContent != nil || item.newContent != nil { return true }
        if item.shortToolName == "Run" { return true }
        if let cmd = item.command, !cmd.isEmpty { return true }
        if let out = item.output, !out.isEmpty { return true }
        if let sum = item.summary, !sum.isEmpty { return true }
        if let desc = item.descriptionText, !desc.isEmpty { return true }
        return false
    }

    private var language: String {
        Buffer.detectLanguage(for: item.path ?? item.displayTitle)
    }

    private func highlightedLine(_ line: String) -> AttributedString {
        let nsAttr = SyntaxHighlighter.shared.highlight(
            line: line,
            language: language,
            font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            theme: theme
        )
        return AttributedString(nsAttr)
    }

    @ViewBuilder
    private var expandableContentView: some View {
        if item.oldContent != nil || item.newContent != nil {
            // Diff Snippet Box
            VStack(alignment: .leading, spacing: 2) {
                if let old = item.oldContent, !old.isEmpty {
                    ForEach(Array(old.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 4) {
                            Text("-")
                                .foregroundColor(.red.opacity(0.92))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Text(highlightedLine(line))
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(2)
                    }
                }
                if let new = item.newContent, !new.isEmpty {
                    ForEach(Array(new.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 4) {
                            Text("+")
                                .foregroundColor(.green.opacity(0.92))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Text(highlightedLine(line))
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(2)
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.12))
            .cornerRadius(8)
        } else if item.shortToolName == "Run" || (item.command != nil && !(item.command?.isEmpty ?? true)) || (item.output != nil && !(item.output?.isEmpty ?? true)) {
            // Command Output Box
            VStack(alignment: .leading, spacing: 4) {
                let cmd = item.command ?? (item.shortToolName == "Run" ? item.displayTitle : "")
                if !cmd.isEmpty {
                    HStack(spacing: 4) {
                        Text("$")
                            .foregroundColor(Color(theme.keyword))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        Text(cmd)
                            .foregroundColor(Color(theme.foreground))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    }
                }
                if let out = item.output, !out.isEmpty {
                    Text(out)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(theme.gutterForeground))
                        .lineLimit(20)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.12))
            .cornerRadius(8)
        } else if let sum = item.summary, !sum.isEmpty {
            Text(sum)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(theme.gutterForeground))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.12))
                .cornerRadius(4)
        }
    }

    private var actionBadgeBackground: Color {
        actionBadgeForeground.opacity(0.24)
    }

    private var actionBadgeForeground: Color {
        switch item.shortToolName {
        case "Edit": return Color.orange
        case "Create": return Color.blue
        case "Run": return Color.purple
        case "Search": return Color.yellow
        case "Read": return Color.teal
        default: return Color.gray
        }
    }

    @ViewBuilder
    private var toolIcon: some View {
        switch item.shortToolName {
        case "Edit":
            Image(systemName: "pencil")
        case "Create":
            Image(systemName: "doc.badge.plus")
        case "Read":
            Image(systemName: "doc.text")
        case "Run":
            Image(systemName: "terminal")
        case "Search":
            Image(systemName: "magnifyingglass")
        default:
            Image(systemName: "gearshape")
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch item.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            EmptyView()
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        }
    }
}
