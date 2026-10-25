import SwiftUI
import AppKit
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
    public var agentId: String
    public var toolcallColorMode: ToolcallColorMode
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)?

    @State private var isChatNearBottom: Bool = true
    @State private var scrollToBottomRequest: Int = 0
    @State private var inputContentHeight: CGFloat = max(AgentMessageCell.userAvatarSize + 8, 38)
    @State private var inputTotalHeight: CGFloat = 0
    @State private var hoveredQuickAction: String?
    @State private var lastKnownStatus: AgentConnectionStatus = .disconnected
    @State private var isPanelDropTargeted: Bool = false
    @State private var previewImages: [AgentImageAttachment]? = nil
    @State private var previewImageIndex: Int? = nil
    @ObservedObject private var templateStore = AgentPromptTemplateStore.shared
    @State private var isCustomizingTemplates: Bool = false
    @State private var isQuickActionsPresented: Bool = false
    @State private var isCustomizeHovered: Bool = false

    public init(
        agentManager: AgentSessionManager,
        theme: Theme,
        workingDirectory: String,
        currentSelectedFile: String? = nil,
        fileDiffsSummary: String? = nil,
        agentAccentColor: Color = .accentColor,
        agentIcon: String = "sparkles",
        agentId: String = "default",
        toolcallColorMode: ToolcallColorMode = AgentDisplayPreferences.toolcallColorMode,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.currentSelectedFile = currentSelectedFile
        self.fileDiffsSummary = fileDiffsSummary
        self.agentAccentColor = agentAccentColor
        self.agentIcon = agentIcon
        self.agentId = agentId
        self.toolcallColorMode = toolcallColorMode
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
        self.onOpenURL = onOpenURL
    }

    public var onOpenURL: ((URL) -> Void)? = nil

    public var body: some View {
        VStack(spacing: 0) {
            if !agentManager.hasVisibleMessages {
                agentInputView
                    .frame(maxWidth: .infinity, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if (!agentManager.authMethods.isEmpty || agentManager.isAuthenticating) && agentManager.hasVisibleMessages {
                authRequiredTopBannerView
            }

            ZStack(alignment: .bottomTrailing) {
                messagesArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if !isChatNearBottom && agentManager.hasVisibleMessages {
                    AgentScrollToBottomButton(
                        theme: theme,
                        isBreathing: agentManager.isBusyOrStreaming
                    ) {
                        scrollToBottomRequest &+= 1
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(theme.background))
        .onDrop(of: [UTType.image, UTType.fileURL, UTType.png, UTType.jpeg, UTType.tiff, UTType.webP, UTType.heic, UTType.url, UTType.data, UTType.item], isTargeted: $isPanelDropTargeted) { providers in
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
        .onChange(of: inputTotalHeight) { _ in
            preserveChatBottomIfNeeded()
        }
        .onChange(of: agentManager.draftAttachments.count) { _ in
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
        var view = AgentInputView(
            text: $agentManager.draftPrompt,
            attachedImages: $agentManager.draftAttachments,
            agentManager: agentManager,
            theme: theme,
            accentColor: agentAccentColor,
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
        view.onTotalHeightChange = { height in
            DispatchQueue.main.async {
                if abs(inputTotalHeight - height) >= 1 { inputTotalHeight = height }
            }
        }
        return view
    }

    private func preserveChatBottomIfNeeded() {
        guard isChatNearBottom else { return }
        scrollToBottomRequest &+= 1
    }

    private var displayedMessages: [AgentMessage] {
        let base = agentManager.messages.filter { $0.hasVisibleContent }
        if agentManager.promptQueue.isEmpty {
            return base
        }
        let total = agentManager.promptQueue.count
        let queued = agentManager.promptQueue.enumerated().map { index, item in
            item.asAgentMessage(index: index, total: total)
        }
        return base + queued
    }

    @ViewBuilder
    private var messagesArea: some View {
        ZStack {
            if !agentManager.hasVisibleMessages {
                if (agentManager.status == .connecting || agentManager.statusMessage == "Loading session...") && !agentManager.isAuthenticating && agentManager.authMethods.isEmpty {
                    welcomeStateView(isLaunching: true)
                } else if !agentManager.authMethods.isEmpty || agentManager.isAuthenticating {
                    authRequiredEmptyStateView
                } else {
                    welcomeStateView(isLaunching: false)
                }
            } else {
                AgentChatScrollRepresentable(
                    messages: displayedMessages,
                    theme: theme,
                    accentColor: agentAccentColor,
                    agentIcon: agentIcon,
                    agentId: agentId,
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
                    },
                    onOpenURL: onOpenURL,
                    onDeleteQueuedMessage: { id in
                        agentManager.removeQueuedPrompt(id: id)
                    },
                    onUpdateQueuedMessage: { id, newText in
                        agentManager.updateQueuedPrompt(id: id, text: newText)
                    },
                    onMoveQueuedMessage: { id, direction in
                        agentManager.moveQueuedPrompt(id: id, direction: direction)
                    },
                    inputView: AnyView(agentInputView),
                    inputContentHeight: max(inputContentHeight, inputTotalHeight)
                )
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let onOpenURL {
                onOpenURL(url)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func welcomeStateView(isLaunching: Bool) -> some View {
        let title = agentManager.agentTitle.isEmpty ? "Agent" : agentManager.agentTitle
        let avatarSize = AgentAvatarProvider.currentAgentAvatarSize(for: agentId)
        let maxW = AgentMessageCell.maxAvatarWidth
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                AgentIconView(icon: agentIcon, agentId: agentId, tintColor: agentAccentColor, size: avatarSize)
                    .frame(width: maxW, alignment: .center)
                    .modifier(AgentWelcomePulse(isActive: isLaunching))

                HStack(alignment: .center, spacing: 6) {
                    ZStack(alignment: .leading) {
                        if isLaunching {
                            Text("Launching…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(theme.gutterForeground))
                                .modifier(AgentWelcomePulse(isActive: true))
                                .transition(.opacity)
                        } else {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(theme.foreground))
                                .transition(.opacity)
                        }
                    }

                    if !isLaunching {
                        quickActionsButton
                            .transition(.opacity)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: isLaunching)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quickActionsButton: some View {
        Button {
            isCustomizingTemplates = false
            isQuickActionsPresented.toggle()
        } label: {
            Image(systemName: "bolt")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isQuickActionsPresented || isCustomizeHovered
                    ? Color(theme.foreground)
                    : Color(theme.gutterForeground))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Color(theme.foreground).opacity(isQuickActionsPresented || isCustomizeHovered ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Quick actions")
        .onHover { isCustomizeHovered = $0 }
        .popover(isPresented: $isQuickActionsPresented, arrowEdge: .bottom) {
            quickActionsPopover
        }
    }

    @ViewBuilder
    private var quickActionsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCustomizingTemplates {
                AgentPromptTemplatesInlineView(
                    store: templateStore,
                    theme: theme,
                    accentColor: agentAccentColor,
                    onDone: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCustomizingTemplates = false
                        }
                    }
                )
            } else {
                HStack {
                    Text("Quick actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(theme.gutterForeground))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCustomizingTemplates = true
                        }
                    } label: {
                        Text("Customize")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(agentAccentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

                if templateStore.templates.isEmpty {
                    Button("Reset to Defaults") {
                        templateStore.resetToDefaults()
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(agentAccentColor)
                    .buttonStyle(.plain)
                    .padding(8)
                } else {
                    ForEach(templateStore.templates) { template in
                        quickActionRow(template.title) {
                            isQuickActionsPresented = false
                            handleSendPrompt(template.prompt)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func quickActionRow(_ title: String, action: @escaping () -> Void) -> some View {
        let isHovered = hoveredQuickAction == title
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Color(theme.foreground).opacity(isHovered ? 1 : 0.88))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(theme.foreground).opacity(isHovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredQuickAction = hovering ? title : (hoveredQuickAction == title ? nil : hoveredQuickAction)
        }
    }

    private func handleSendPrompt(_ prompt: String, images: [AgentImageAttachment] = []) {
        var finalPrompt = prompt
        if finalPrompt.contains("@diff"), let summary = fileDiffsSummary {
            finalPrompt = finalPrompt.replacingOccurrences(of: "@diff", with: "\n\n[Diff Context]:\n\(summary)\n")
        }
        // Synchronously reset input heights to 1-line height before triggering scroll / updates
        let minH = max(AgentMessageCell.userAvatarSize + 8, 38)
        inputContentHeight = minH
        inputTotalHeight = minH
        // A new prompt starts a new turn, so resume following the latest
        // output even if the user previously opened a tool card for inspection.
        scrollToBottomRequest &+= 1
        agentManager.sendPrompt(finalPrompt, images: images, workingDirectory: workingDirectory)
    }

    @ViewBuilder
    private var authRequiredEmptyStateView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    AgentIconView(icon: agentIcon, agentId: agentId, tintColor: agentAccentColor, size: 44)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.blue, in: Circle())
                        .offset(x: 3, y: 3)
                }

                VStack(spacing: 6) {
                    Text("Authenticate to \(agentManager.agentTitle)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(theme.foreground))

                    Text("Choose an account or sign-in method to start using this agent profile.")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(theme.gutterForeground))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 360)
                }

                if let error = agentManager.authErrorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                        Text(error)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 380)
                }

                if agentManager.isAuthenticating {
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for authentication…")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(theme.foreground))
                        }

                        Text("Please complete sign-in in your browser window.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(theme.gutterForeground))
                            .multilineTextAlignment(.center)

                        if let authURL = agentManager.authURL {
                            Button {
                                NSWorkspace.shared.open(authURL)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("Open Sign-In Page in Browser")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }

                        Button("Cancel") {
                            agentManager.cancel()
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Color(theme.gutterForeground))
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 360)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(theme.excerptHeaderBorder).opacity(0.6), lineWidth: 1)
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(agentManager.authMethods.enumerated()), id: \.element.id) { index, method in
                            authMethodButton(method: method, isPrimary: index == 0)
                        }
                    }
                    .frame(maxWidth: 380)
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func authMethodButton(method: ACPAuthMethod, isPrimary: Bool) -> some View {
        Button {
            Task {
                try? await agentManager.authenticate(methodId: method.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: authMethodIcon(for: method.id))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isPrimary ? .white : agentAccentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        isPrimary ? agentAccentColor : agentAccentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(theme.foreground))
                    if let desc = method.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundColor(Color(theme.gutterForeground))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground))
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isPrimary ? agentAccentColor.opacity(0.4) : Color(theme.excerptHeaderBorder).opacity(0.6),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func authMethodIcon(for id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("oauth") || lower.contains("google") {
            return "person.crop.circle.fill"
        } else if lower.contains("key") {
            return "key.fill"
        } else if lower.contains("enterprise") || lower.contains("platform") {
            return "building.2.fill"
        }
        return "lock.fill"
    }

    @ViewBuilder
    private var authRequiredTopBannerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundColor(.blue)
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("Authentication required")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                Text("Sign in to continue using this agent.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(theme.gutterForeground))
            }

            Spacer()

            if agentManager.isAuthenticating {
                ProgressView()
                    .controlSize(.small)
            } else if let firstMethod = agentManager.authMethods.first {
                Button {
                    Task {
                        try? await agentManager.authenticate(methodId: firstMethod.id)
                    }
                } label: {
                    Text(firstMethod.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(theme.gutterBackground))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(theme.excerptHeaderBorder)),
            alignment: .bottom
        )
    }
}

private struct AgentScrollToBottomButton: View {
    let theme: Theme
    let isBreathing: Bool
    let action: () -> Void

    @State private var pulseLow = false

    var body: some View {
        Button(action: action) {
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
                .opacity(isBreathing && pulseLow ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .help("Scroll to bottom")
        .onAppear {
            updateAnimation(isBreathing)
        }
        .onChange(of: isBreathing) { newValue in
            updateAnimation(newValue)
        }
    }

    private func updateAnimation(_ active: Bool) {
        if active {
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pulseLow = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                pulseLow = false
            }
        }
    }
}

/// Soft breathing used while the agent process is launching.
private struct AgentWelcomePulse: ViewModifier {
    let isActive: Bool
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && dimmed ? 0.35 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
                value: dimmed
            )
            .onAppear { if isActive { dimmed = true } }
            .onChange(of: isActive) { active in dimmed = active }
    }
}

