import SwiftUI
import AnyDiffCore

public struct AgentMessageRowView: View {
    public let message: AgentMessage
    public let theme: Theme
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isThinkingExpanded: Bool = false

    public init(
        message: AgentMessage,
        theme: Theme,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.message = message
        self.theme = theme
        self.onReview = onReview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == .user {
                userBubble
            } else {
                assistantBubble
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.10, green: 0.50, blue: 1.0),
                                    Color(red: 0.05, green: 0.42, blue: 0.94)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(Color(red: 0.40, green: 0.72, blue: 1.0).opacity(0.50), lineWidth: 1.0)
                        )
                        .shadow(color: Color(red: 0.05, green: 0.40, blue: 0.95).opacity(0.40), radius: 6, x: 0, y: 2)
                )
        }
    }

    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1. Thinking / Reasoning Block
            if let thought = message.thought, !thought.isEmpty {
                thinkingBlock(thought)
            }

            // 2. Tool Calls (File Edits, Commands, Reads)
            if !message.toolCalls.isEmpty {
                VStack(spacing: 6) {
                    ForEach(message.toolCalls) { toolItem in
                        AgentToolCallCard(item: toolItem, theme: theme, onReview: onReview)
                    }
                }
            }

            // 3. Assistant Message Text Content
            if !message.content.isEmpty {
                AgentMarkdownView(content: message.content, theme: theme)
            } else if message.isStreaming && message.toolCalls.isEmpty && (message.thought == nil || message.thought!.isEmpty) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Thinking...")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundColor(Color(theme.gutterForeground))
                }
                .padding(.vertical, 4)
            }

            // 4. Edited Files Card (if any files were modified during this turn)
            if let editedSummary = message.editedFilesSummary {
                AgentEditedFilesCard(
                    summary: editedSummary,
                    theme: theme,
                    onReview: onReview
                )
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thinkingBlock(_ thought: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isThinkingExpanded.toggle()
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: isThinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(message.isStreaming && message.content.isEmpty ? "Thinking..." : "Thoughts")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
            }
            .buttonStyle(.plain)

            if isThinkingExpanded {
                Text(thought)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(theme.gutterBackground).opacity(0.6))
                    )
            }
        }
    }
}
