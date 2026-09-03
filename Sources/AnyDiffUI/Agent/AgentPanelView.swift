import SwiftUI
import UniformTypeIdentifiers
import AnyDiffCore

public struct AgentPanelView: View {
    @ObservedObject public var agentManager: AgentSessionManager
    public var theme: Theme
    public var workingDirectory: String
    public var currentSelectedFile: String?
    public var fileDiffsSummary: String?
    public var agentAccentColor: Color
    public var agentIcon: String
    public var toolcallColorMode: ToolcallColorMode
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)?

    @State private var inputText: String = ""
    @State private var isInputCollapsed: Bool = false
    @State private var isChatNearBottom: Bool = true
    @State private var scrollToBottomRequest: Int = 0
    @State private var inputContentHeight: CGFloat = 22
    @State private var hoveredQuickAction: String?
    @State private var lastKnownStatus: AgentConnectionStatus = .disconnected
    @State private var isPanelDropTargeted: Bool = false
    @State private var previewImages: [AgentImageAttachment]? = nil
    @State private var previewImageIndex: Int? = nil

    public init(
        agentManager: AgentSessionManager,
        theme: Theme,
        workingDirectory: String,
        currentSelectedFile: String? = nil,
        fileDiffsSummary: String? = nil,
        agentAccentColor: Color = .accentColor,
        agentIcon: String = "sparkles",
        toolcallColorMode: ToolcallColorMode = AgentDisplayPreferences.toolcallColorMode,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.currentSelectedFile = currentSelectedFile
        self.fileDiffsSummary = fileDiffsSummary
        self.agentAccentColor = agentAccentColor
        self.agentIcon = agentIcon
        self.toolcallColorMode = toolcallColorMode
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Reserve space for window toolbar
            Rectangle()
                .fill(Color(theme.background))
                .frame(height: 5)

            ZStack(alignment: .bottomTrailing) {
                messagesArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if !isChatNearBottom && !agentManager.messages.isEmpty {
                    Button {
                        scrollToBottomRequest &+= 1
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(theme.foreground).opacity(0.9))
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.85), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Scroll to bottom")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .padding(.trailing, 10)
                    .padding(.bottom, isInputCollapsed ? 52 : 10)
                }

                if isInputCollapsed {
                    agentInputView
                        .fixedSize()
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                        .zIndex(1)
                }

                if let permission = agentManager.pendingPermission {
                    permissionRequestView(permission)
                        .padding(.horizontal, 10)
                        .padding(.bottom, isInputCollapsed ? 52 : 10)
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isInputCollapsed {
                agentInputView
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(Color(theme.background))
        .onDrop(of: [UTType.image, UTType.fileURL, UTType.png, UTType.jpeg, UTType.tiff, UTType.url], isTargeted: $isPanelDropTargeted) { providers in
            ImageAttachmentHelpers.extractImages(from: providers) { droppedImages in
                guard !droppedImages.isEmpty else { return }
                NotificationCenter.default.post(
                    name: Notification.Name("anyDiffAttachImages"),
                    object: nil,
                    userInfo: ["images": droppedImages]
                )
            }
            return true
        }
        .overlay {
            if isPanelDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(theme.background).opacity(0.88))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(agentAccentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(8)

                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundColor(agentAccentColor)
                        Text("Drop images to attach to chat")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(theme.foreground))
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay {
            if onPreviewImages == nil, let images = previewImages, previewImageIndex != nil {
                AgentImagePreviewModalView(
                    images: images,
                    selectedIndex: $previewImageIndex,
                    theme: theme
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            agentManager.prepareAgent(workingDirectory: workingDirectory)
        }
        .onChange(of: workingDirectory) { newDirectory in
            agentManager.prepareAgent(workingDirectory: newDirectory)
        }
        .onChange(of: inputContentHeight) { _ in
            preserveChatBottomIfNeeded()
        }
        .onChange(of: isInputCollapsed) { _ in
            preserveChatBottomIfNeeded()
        }
        .onChange(of: agentManager.status) { newStatus in
            if lastKnownStatus == .busy && newStatus == .idle {
                HapticFeedback.perform(.generic)
            }
            lastKnownStatus = newStatus
        }
    }

    private var agentInputView: some View {
        AgentInputView(
            text: $inputText,
            agentManager: agentManager,
            theme: theme,
            accentColor: agentAccentColor,
            isCollapsed: $isInputCollapsed,
            calculatedHeight: $inputContentHeight,
            onSend: { prompt, images in
                handleSendPrompt(prompt, images: images)
            },
            onCancel: { agentManager.cancel() },
            onReview: onReview,
            onPreviewImages: { imgs, idx, isDraft in
                if let onPreviewImages = onPreviewImages {
                    onPreviewImages(imgs, idx, isDraft)
                } else {
                    previewImages = imgs
                    previewImageIndex = idx
                }
            }
        )
    }

    private func preserveChatBottomIfNeeded() {
        guard isChatNearBottom else { return }
        scrollToBottomRequest &+= 1
    }

    @ViewBuilder
    private var messagesArea: some View {
        ZStack {
            if agentManager.messages.isEmpty {
                emptyStateView
                    .transition(.opacity)
            } else {
                AgentChatScrollRepresentable(
                    messages: agentManager.messages,
                    theme: theme,
                    accentColor: agentAccentColor,
                    toolcallColorMode: toolcallColorMode,
                    scrollToBottomTrigger: scrollToBottomRequest,
                    onNearBottomChanged: { nearBottom in
                        DispatchQueue.main.async {
                            if isChatNearBottom != nearBottom {
                                isChatNearBottom = nearBottom
                            }
                        }
                    },
                    onReview: onReview,
                    onRevert: { summary in
                        agentManager.revertTurn(summary: summary, workingDirectory: workingDirectory)
                    },
                    onRestore: { summary in
                        agentManager.restoreTurn(summary: summary, workingDirectory: workingDirectory)
                    },
                    onPreviewImages: { imgs, idx in
                        if let onPreviewImages = onPreviewImages {
                            onPreviewImages(imgs, idx, false)
                        } else {
                            previewImages = imgs
                            previewImageIndex = idx
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: agentManager.messages.isEmpty)
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                AgentIconView(icon: agentIcon, tintColor: agentAccentColor, size: 40)

                VStack(spacing: 7) {
                    Text(agentManager.agentTitle.isEmpty ? "Ask Agent" : "Ask \(agentManager.agentTitle)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Color(theme.foreground))

                    Text("Inspect diffs, write code changes, and run commands with your agent.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(theme.gutterForeground))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 390)
                }

                VStack(spacing: 8) {
                    quickActionButton("Explain current diff", icon: "doc.text.magnifyingglass") {
                        handleSendPrompt("Explain the current git diff and summarize the main changes.")
                    }
                    quickActionButton("Review changes for bugs", icon: "checkmark.circle") {
                        handleSendPrompt("Review these changes carefully and highlight any potential bugs, logic issues, or edge cases.")
                    }
                    quickActionButton("Generate commit message", icon: "text.badge.checkmark") {
                        handleSendPrompt("Generate a concise, conventional git commit message for these changes.")
                    }
                    quickActionButton("Commit and push", icon: "arrow.up.circle") {
                        handleSendPrompt("Commit the current changes with an appropriate conventional commit message and push the commit to the configured remote.")
                    }
                }
                .frame(maxWidth: 430)
                .padding(.top, 5)
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func quickActionButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredQuickAction == title

        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isHovered ? .white : agentAccentColor)
                    .frame(width: 24, height: 24)
                    .background(
                        isHovered ? agentAccentColor : agentAccentColor.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isHovered ? agentAccentColor : Color(theme.gutterForeground))
                    .frame(width: 26, height: 26)
                    .background(
                        isHovered
                            ? agentAccentColor.opacity(0.14)
                            : Color(theme.foreground).opacity(0.06),
                        in: Circle()
                    )
            }
            .foregroundColor(
                isHovered
                    ? Color(theme.foreground)
                    : Color(theme.foreground).opacity(0.85)
            )
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(agentAccentColor.opacity(isHovered ? 0.07 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.65), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.01 : 1)
        .shadow(
            color: isHovered ? agentAccentColor.opacity(0.16) : Color.black.opacity(0.04),
            radius: isHovered ? 12 : 8,
            y: isHovered ? 4 : 3
        )
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                hoveredQuickAction = hovering ? title : nil
            }
        }
    }

    private func handleSendPrompt(_ prompt: String, images: [AgentImageAttachment] = []) {
        var finalPrompt = prompt
        if finalPrompt.contains("@diff"), let summary = fileDiffsSummary {
            finalPrompt = finalPrompt.replacingOccurrences(of: "@diff", with: "\n\n[Diff Context]:\n\(summary)\n")
        }
        // A new prompt starts a new turn, so resume following the latest
        // output even if the user previously opened a tool card for inspection.
        scrollToBottomRequest &+= 1
        agentManager.sendPrompt(finalPrompt, images: images, workingDirectory: workingDirectory)
    }

    @ViewBuilder
    private func permissionRequestView(_ permission: AgentPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(.orange)
                Text("Permission required")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                Spacer()
            }

            Text(permission.title)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(theme.foreground))
                .lineLimit(3)

            if let command = permission.command, !command.isEmpty, command != permission.title {
                Text("$ \(command)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground))
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                ForEach(permission.options) { option in
                    Button {
                        agentManager.respondToPermission(optionId: option.optionId)
                    } label: {
                        Text(option.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(permissionOptionColor(option))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(permissionOptionColor(option).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(theme.gutterBackground).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.65), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    private func permissionOptionColor(_ option: ACPPermissionOption) -> Color {
        if option.kind?.lowercased().contains("reject") == true {
            return .red
        }
        if option.kind?.lowercased().contains("allow") == true {
            return .green
        }
        return Color(theme.foreground)
    }
}
