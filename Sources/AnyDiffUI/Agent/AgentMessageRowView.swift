import SwiftUI
import AnyDiffCore

public struct AgentMessageRowView: View {
    public let message: AgentMessage
    public let theme: Theme
    public var onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? = nil
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? = nil

    @State private var isThinkingExpanded: Bool = false
    @State private var previewImageIndex: Int? = nil
    @State private var isUserTextExpanded: Bool = false
    @State private var isHoveringExpandButton: Bool = false

    private var isCollapsibleUserText: Bool {
        message.content.count > 300 || message.content.filter({ $0 == "\n" }).count >= 7
    }

    public init(
        message: AgentMessage,
        theme: Theme,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRevert: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRestore: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.message = message
        self.theme = theme
        self.onReview = onReview
        self.onRevert = onRevert
        self.onRestore = onRestore
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
        .overlay {
            if previewImageIndex != nil && !message.images.isEmpty {
                AgentImagePreviewModalView(
                    images: message.images,
                    selectedIndex: $previewImageIndex,
                    theme: theme
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    userImagesView
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white)
                        .lineLimit(isCollapsibleUserText && !isUserTextExpanded ? 8 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isCollapsibleUserText {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isUserTextExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(isUserTextExpanded ? "Show less" : "Show more")
                            Image(systemName: isUserTextExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isHoveringExpandButton ? Color.white.opacity(0.15) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringExpandButton = hovering
                    }
                }
            }
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
                    .shadow(color: Color(red: 0.05, green: 0.40, blue: 0.95).opacity(0.40), radius: 6, x: 0, y: 2)
            )
        }
    }

    @ViewBuilder
    private var userImagesView: some View {
        let count = message.images.count
        if count == 1, let singleImage = message.images.first, let nsImg = NSImage(data: singleImage.data) {
            Button(action: {
                previewImageIndex = 0
            }) {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Click to enlarge")
        } else {
            HStack(spacing: 6) {
                ForEach(Array(message.images.enumerated()), id: \.element.id) { index, img in
                    Button(action: {
                        previewImageIndex = index
                    }) {
                        if let nsImg = NSImage(data: img.data) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Click to enlarge (\(img.filename ?? "image"))")
                }
            }
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
                    onReview: onReview,
                    onRevert: onRevert,
                    onRestore: onRestore
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
