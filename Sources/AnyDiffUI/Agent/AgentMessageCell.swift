import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public final class AgentMessageCell: NSView {
    public override var isFlipped: Bool { true }

    // Temporary performance switch: keep the code-block implementation in
    // place, but omit these heavy expandable cards from the chat output while
    // the scrolling path is being tuned. Flip back to `true` to restore them.
    static let showsCodeBlocks = false
    // Keep the colored expandable tool cards implemented, but use compact
    // text-only rows in the current chat while scroll performance is tuned.
    static let usesSimpleToolCalls = false

    public var onToggleThought: (() -> Void)?
    public var onToggleTool: (() -> Void)?
    public var onReview: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentEditedFilesCardView)?.onReview = onReview
        }
    }
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentEditedFilesCardView)?.onRevert = onRevert
        }
    }
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentEditedFilesCardView)?.onRestore = onRestore
        }
    }
    public var onRestoreCheckpoint: ((UUID) -> Void)?
    public var onUndoRestoreCheckpoint: ((UUID) -> Void)?
    public private(set) var message: AgentMessage
    var theme: Theme
    var accentColor: Color
    var toolcallColorMode: ToolcallColorMode
    var isCompactMode: Bool
    let nativeTextSelectionEnabled: Bool
    var isThoughtExpanded: Bool = false
    var expandedToolIds: Set<String> = []
    var expandedToolGroupKeys: Set<String> = []
    var toolGroupViewsByKey: [String: AgentToolGroupView] = [:]
    var toolCallIDs: [String] = []
    var inlineThoughtViews: [AgentThoughtBlockView] = []
    var markdownViewsByTextPart: [[NSView]] = []
    var orderedAssistantViews: [NSView] = []
    var editedFilesCardView: NSView?
    var cachedParsedDiffFiles: [FileDiff]?
    var cachedParsedDiffDataCount: Int = -1

    public func parsedDiffFiles() -> [FileDiff]? {
        guard let rawData = message.editedFilesSummary?.rawDiffData,
              !rawData.isEmpty else {
            return nil
        }
        if rawData.count == cachedParsedDiffDataCount, let cached = cachedParsedDiffFiles {
            return cached
        }
        let files = GitDiffParser.shared.parse(data: rawData)
        cachedParsedDiffFiles = files
        cachedParsedDiffDataCount = rawData.count
        return files
    }

    public func parsedDiffHunks(for itemPath: String) -> [DiffHunk]? {
        guard let files = parsedDiffFiles() else { return nil }
        guard let matchedFile = files.first(where: {
            let p = $0.displayPath
            return p == itemPath || p.hasSuffix(itemPath) || itemPath.hasSuffix(p)
        }), !matchedFile.hunks.isEmpty else {
            return nil
        }
        return matchedFile.hunks
    }

    var hasInlineThoughtParts: Bool {
        message.orderedParts.contains { part in
            if case .thought(let str) = part {
                return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    var hasCompactTopThought: Bool {
        guard !hasInlineThoughtParts,
              let thought = message.thought else { return false }
        return isCompactThought(thought)
    }

    func isCompactThought(_ thought: String) -> Bool {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed.count <= 120 &&
            trimmed.split(whereSeparator: { $0.isNewline }).count <= 2
    }

    // Subviews
    public let avatarAuraView = AgentAvatarAuraView()
    public let roleIconView = AgentAvatarImageView()
    /// Unstuck (layout) Y of the avatar inside the cell.
    var stickyAvatarBaseY: CGFloat = 1
    /// Top of the visible viewport in this cell's coordinates (may be negative/greater than height).
    private var stickyViewportTop: CGFloat = -.greatestFiniteMagnitude
    private static let stickyAvatarInset: CGFloat = 6
    public let typingIndicatorView = AgentTypingIndicatorView()
    public private(set) var agentIconName: String = "sparkles"
    public private(set) var agentId: String = "default"
    let userBubbleView = AgentFlippedView()
    let queuedHeaderView = AgentQueuedHeaderView()
    public let queuedEditorView = AgentQueuedInlineEditorView()
    public private(set) var isEditingQueuedMessage: Bool = false
    let userContentContainerView = AgentFlippedView()
    let userTextView = AgentSelectableTextView()
    var userImageViews: [NSButton] = []
    var userContentViews: [NSView] = []
    var renderedUserContent: String? = nil
    var renderedUserThemeId: String? = nil
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    public var onDeleteQueuedMessage: ((UUID) -> Void)?
    public var onEditQueuedMessage: ((UUID) -> Void)?
    public var onUpdateQueuedMessage: ((UUID, String) -> Void)?
    public var onMoveQueuedMessage: ((UUID, QueueMoveDirection) -> Void)?
    public var onRequestLayout: (() -> Void)?
    let thoughtHeaderButton = AgentHoverButton()
    let thoughtTextView = AgentSelectableTextView()
    var toolCallViews: [NSView] = []
    var pendingToolCallAppearances: [NSView] = []
    var pendingEditedFilesCardAppearance: NSView?
    var pendingUserMessageAppearance = false
    var markdownViews: [NSView] = []
    var streamingRenderedContent: String = ""
    var cachedLayoutWidth: CGFloat = -1
    var cachedLayoutHeight: CGFloat = 0
    var layoutNeedsApplication = true
    let maxCodeBlockHeight: CGFloat = 320
    struct TextMeasurementKey: Hashable {
        let view: ObjectIdentifier
        let width: Int
    }
    var cachedTextHeights: [TextMeasurementKey: CGFloat] = [:]

    struct StreamingFadeChunk {
        let range: NSRange
        let startTime: TimeInterval
    }
    struct StreamingLineCacheKey: Hashable {
        let raw: String
        let fontSize: CGFloat
        let fontTraits: UInt
        let colorAlpha: Int
        let headIndent: CGFloat
        let firstLineHeadIndent: CGFloat
        let lineSpacing: CGFloat
        let paragraphSpacing: CGFloat
        let paragraphSpacingBefore: CGFloat
    }
    var streamingLineCache: [StreamingLineCacheKey: NSAttributedString] = [:]
    var streamingFadeChunks: [StreamingFadeChunk] = []
    var streamingFadeTimer: Timer?
    var streamingBaseAttributedString: NSAttributedString?
    var thoughtFadeChunks: [StreamingFadeChunk] = []
    var thoughtFadeTimer: Timer?
    var previousStreamedLength: Int = 0

    deinit {
        streamingFadeTimer?.invalidate()
        streamingFadeTimer = nil
        thoughtFadeTimer?.invalidate()
        thoughtFadeTimer = nil
    }

    var needsLayoutApplication: Bool {
        layoutNeedsApplication
    }

    public init(
        message: AgentMessage,
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode = .full,
        isCompactMode: Bool = false,
        nativeTextSelectionEnabled: Bool = false,
        agentIconName: String = "sparkles",
        agentId: String = "default"
    ) {
        self.message = message
        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode
        self.isCompactMode = isCompactMode
        self.nativeTextSelectionEnabled = nativeTextSelectionEnabled
        self.agentIconName = agentIconName
        self.agentId = agentId
        super.init(frame: .zero)
        setup()
        configure(message: message, theme: theme, accentColor: accentColor, toolcallColorMode: toolcallColorMode, isCompactMode: isCompactMode, agentIconName: agentIconName, agentId: agentId)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        avatarAuraView.isHidden = true
        addSubview(avatarAuraView)

        roleIconView.wantsLayer = true
        roleIconView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        roleIconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(roleIconView)

        typingIndicatorView.wantsLayer = true
        typingIndicatorView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        typingIndicatorView.isHidden = true
        addSubview(typingIndicatorView)

        userBubbleView.wantsLayer = true
        userBubbleView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        userBubbleView.layer?.cornerRadius = 0
        userBubbleView.layer?.borderWidth = 0.0
        userBubbleView.layer?.masksToBounds = false
        userBubbleView.layer?.shadowColor = nil
        userBubbleView.layer?.shadowOpacity = 0.0

        userContentContainerView.wantsLayer = true
        userContentContainerView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        userContentContainerView.layer?.masksToBounds = true
        userBubbleView.addSubview(queuedHeaderView)
        userBubbleView.addSubview(queuedEditorView)
        userBubbleView.addSubview(userContentContainerView)
        addSubview(userBubbleView)

        thoughtHeaderButton.wantsLayer = true
        thoughtHeaderButton.layerContentsRedrawPolicy = .onSetNeedsDisplay
        thoughtHeaderButton.isBordered = false
        thoughtHeaderButton.setButtonType(.momentaryPushIn)
        thoughtHeaderButton.alignment = .left
        thoughtHeaderButton.defaultBackgroundColor = .clear
        thoughtHeaderButton.hoverBackgroundColor = .clear
        thoughtHeaderButton.target = self
        thoughtHeaderButton.action = #selector(toggleThought)
        thoughtHeaderButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        thoughtHeaderButton.imagePosition = .imageRight
        thoughtHeaderButton.imageHugsTitle = true
        thoughtHeaderButton.imageScaling = .scaleProportionallyDown
        thoughtHeaderButton.isHidden = true
        updateThoughtHeaderAppearance()
        addSubview(thoughtHeaderButton)

        thoughtTextView.parentCell = self
        thoughtTextView.isHidden = true
        thoughtTextView.alphaValue = 0
    }

    public func configure(
        message: AgentMessage,
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode = .full,
        isCompactMode: Bool = false,
        agentIconName: String = "sparkles",
        agentId: String = "default"
    ) {
        let previousMessage = self.message
        let shouldAnimateStreamingText =
            previousMessage.id == message.id &&
            message.role == .assistant &&
            message.isStreaming &&
            message.content.count > previousMessage.content.count &&
            message.content.hasPrefix(previousMessage.content)

        let themeChanged = theme.id != self.theme.id
        let accentChanged = accentColor != self.accentColor
        let displayModeChanged = toolcallColorMode != self.toolcallColorMode || isCompactMode != self.isCompactMode
        let thoughtChanged = previousMessage.thought != message.thought
        let toolCallsChanged = message.toolCalls != previousMessage.toolCalls
        let partsChanged = message.orderedParts != previousMessage.orderedParts
        let contentChanged = previousMessage.content.count != message.content.count || previousMessage.content != message.content
        let editedFilesChanged = previousMessage.editedFilesSummary != message.editedFilesSummary
        if editedFilesChanged {
            cachedParsedDiffFiles = nil
            cachedParsedDiffDataCount = -1
        }
        if themeChanged || accentChanged {
            streamingLineCache.removeAll(keepingCapacity: message.isStreaming)
        }
        defer {
            if !message.isStreaming && !streamingLineCache.isEmpty {
                streamingLineCache.removeAll(keepingCapacity: false)
            }
        }

        let isSameUserMessageMetadataOnlyUpdate =
            (!userContentViews.isEmpty || !userImageViews.isEmpty) &&
            previousMessage.id == message.id &&
            previousMessage.role == .user &&
            message.role == .user &&
            !contentChanged &&
            !themeChanged &&
            !accentChanged &&
            previousMessage.images == message.images

        self.message = message
        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode
        self.isCompactMode = isCompactMode
        self.agentIconName = agentIconName
        self.agentId = agentId
        if !isSameUserMessageMetadataOnlyUpdate || previousMessage.isQueued != message.isQueued {
            invalidateLayoutCache()
        }

        if message.role == .user {
            if !isSameUserMessageMetadataOnlyUpdate {
                avatarAuraView.stopAnimating(animated: false)
                roleIconView.layer?.removeAnimation(forKey: "agentRolePulse")
                roleIconView.layer?.opacity = 1.0
                let userSize = AgentMessageCell.userAvatarSize
                roleIconView.isUserRole = true
                roleIconView.image = AgentAvatarProvider.userAvatarImage
                roleIconView.layer?.cornerRadius = userSize / 2
                roleIconView.layer?.masksToBounds = true
                roleIconView.layer?.backgroundColor = nil
                roleIconView.contentTintColor = nil
                roleIconView.isHidden = false
                roleIconView.toolTip = "Click or right-click to customize avatar settings"
                roleIconView.onRightClick = { [weak self] view in
                    guard self != nil else { return }
                    AgentAvatarProvider.showEditor(relativeTo: view, initialTab: .user)
                }
                roleIconView.onClick = { [weak self] view in
                    guard self != nil else { return }
                    AgentAvatarProvider.showEditor(relativeTo: view, initialTab: .user)
                }

                userTextView.cellId = message.id
                userTextView.tvKey = "user"
                userBubbleView.isHidden = false
                thoughtHeaderButton.isHidden = true
                thoughtTextView.isHidden = true
                thoughtTextView.alphaValue = 0
                thoughtTextView.removeFromSuperview()

                userBubbleView.layer?.backgroundColor = NSColor.clear.cgColor
                userBubbleView.layer?.borderWidth = 0.0
                userBubbleView.layer?.borderColor = nil
                userBubbleView.layer?.shadowColor = nil
                userBubbleView.layer?.shadowOpacity = 0.0

                userImageViews.forEach { $0.removeFromSuperview() }
                userImageViews.removeAll()

                let inlineMarkerCount = message.content.components(separatedBy: AgentImageAttachment.inlineTextMarker).count - 1
                let hasInlineImagePositions = !message.images.isEmpty && inlineMarkerCount == message.images.count
                if !hasInlineImagePositions {
                    for (index, img) in message.images.enumerated() {
                        if let nsImage = ImageAttachmentHelpers.inlineDisplayImage(for: img).image {
                            let btn = NSButton()
                            btn.image = nsImage
                            btn.imageScaling = .scaleProportionallyUpOrDown
                            btn.isBordered = false
                            btn.wantsLayer = true
                            btn.layerContentsRedrawPolicy = .onSetNeedsDisplay
                            btn.layer?.cornerRadius = 8
                            btn.layer?.masksToBounds = true
                            btn.layer?.borderWidth = 1
                            btn.layer?.borderColor = (NSColor(cgColor: theme.excerptHeaderBorder.cgColor) ?? NSColor.separatorColor).withAlphaComponent(0.6).cgColor
                            btn.target = self
                            btn.action = #selector(handleImageClick(_:))
                            btn.tag = index
                            userBubbleView.addSubview(btn)
                            userImageViews.append(btn)
                        }
                    }
                }

                rebuildUserContentViews(content: message.content, forceRebuild: themeChanged || accentChanged)
            }

            if message.isQueued {
                userBubbleView.alphaValue = 0.94
                roleIconView.alphaValue = 0.88
                queuedHeaderView.isHidden = false
                queuedHeaderView.configure(
                    position: message.queuePosition ?? 1,
                    total: message.queueTotal ?? 1,
                    theme: theme,
                    accentColor: accentColor
                )
                queuedHeaderView.onMoveUp = { [weak self] in
                    guard let self else { return }
                    self.onMoveQueuedMessage?(self.message.id, .up)
                }
                queuedHeaderView.onMoveDown = { [weak self] in
                    guard let self else { return }
                    self.onMoveQueuedMessage?(self.message.id, .down)
                }
                queuedHeaderView.onEdit = { [weak self] in
                    guard let self else { return }
                    if self.isEditingQueuedMessage {
                        self.stopEditingQueuedMessage()
                    } else {
                        self.startEditingQueuedMessage()
                    }
                }
                queuedHeaderView.onDelete = { [weak self] in
                    guard let self else { return }
                    self.onDeleteQueuedMessage?(self.message.id)
                }

                queuedEditorView.onSave = { [weak self] newText in
                    guard let self else { return }
                    self.stopEditingQueuedMessage()
                    self.onUpdateQueuedMessage?(self.message.id, newText)
                }
                queuedEditorView.onCancel = { [weak self] in
                    guard let self else { return }
                    self.stopEditingQueuedMessage()
                }
                queuedEditorView.onHeightChange = { [weak self] in
                    guard let self else { return }
                    self.invalidateLayoutCache()
                    self.onRequestLayout?()
                }

                if isEditingQueuedMessage {
                    queuedEditorView.updateTheme(theme: theme, accentColor: accentColor)
                    queuedEditorView.isHidden = false
                    userContentContainerView.isHidden = true
                } else {
                    queuedEditorView.isHidden = true
                }
            } else {
                isEditingQueuedMessage = false
                userBubbleView.alphaValue = 1.0
                roleIconView.alphaValue = 1.0
                queuedHeaderView.isHidden = true
                queuedEditorView.isHidden = true
            }

            clearAssistantViews()
        } else {
            clearUserViews()
            roleIconView.alphaValue = 1.0
            let agentSize = AgentAvatarProvider.currentAgentAvatarSize(for: agentId)
            let showCircle = AgentAvatarProvider.shouldShowAgentCircle(for: agentId)
            roleIconView.isUserRole = true
            roleIconView.toolTip = "Click or right-click to customize avatar settings"
            roleIconView.onRightClick = { [weak self] view in
                guard let self = self else { return }
                AgentAvatarProvider.showEditor(relativeTo: view, initialTab: .agent, agentId: self.agentId)
            }
            roleIconView.onClick = { [weak self] view in
                guard let self = self else { return }
                AgentAvatarProvider.showEditor(relativeTo: view, initialTab: .agent, agentId: self.agentId)
            }
            if let customAgentImg = AgentAvatarProvider.customAgentAvatarImage(for: agentId) {
                roleIconView.image = customAgentImg
                roleIconView.layer?.cornerRadius = agentSize / 2
                roleIconView.layer?.masksToBounds = true
                roleIconView.layer?.backgroundColor = nil
                roleIconView.contentTintColor = nil
            } else {
                let iconPaddingSize = showCircle ? ceil(agentSize * 0.62) : agentSize
                roleIconView.image = AgentAvatarProvider.agentIconImage(for: agentIconName, size: iconPaddingSize)
                if showCircle {
                    roleIconView.layer?.cornerRadius = agentSize / 2
                    roleIconView.layer?.masksToBounds = true
                    let circleBg = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor).withAlphaComponent(0.12)
                    roleIconView.layer?.backgroundColor = circleBg.cgColor
                } else {
                    roleIconView.layer?.cornerRadius = 0
                    roleIconView.layer?.masksToBounds = false
                    roleIconView.layer?.backgroundColor = nil
                }
                roleIconView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.85) ?? .secondaryLabelColor
            }
            roleIconView.isHidden = !message.hasVisibleContent

            thoughtTextView.cellId = message.id
            thoughtTextView.tvKey = "thought"
            userBubbleView.isHidden = true

            // 1. Thought block. Live ACP reasoning is also represented in
            // orderedParts so thoughts can appear between tools/text instead
            // of being forced into one detached top section.
            let hasInline = hasInlineThoughtParts
            let hasTopThought = (message.thought?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)

            if hasInline {
                thoughtHeaderButton.isHidden = true
                thoughtTextView.isHidden = true
                thoughtTextView.alphaValue = 0
                thoughtTextView.removeFromSuperview()
                if partsChanged || themeChanged || inlineThoughtViews.isEmpty {
                    rebuildInlineThoughtViews()
                }
            } else {
                clearInlineThoughtViews()
                if hasTopThought {
                    let isCompact = isCompactThought(message.thought ?? "")
                    thoughtHeaderButton.isHidden = isCompact
                    updateThoughtHeaderAppearance()
                    thoughtHeaderButton.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.85) ?? NSColor.secondaryLabelColor
                    let shouldShowThought = isCompact || isThoughtExpanded
                    thoughtTextView.isHidden = !shouldShowThought
                    thoughtTextView.alphaValue = shouldShowThought ? 1 : 0
                    if shouldShowThought {
                        if thoughtTextView.superview == nil {
                            addSubview(thoughtTextView)
                        }
                    } else {
                        thoughtTextView.removeFromSuperview()
                    }
                    let previousThoughtLength = thoughtTextView.textStorage?.length ?? 0
                    let previousThought = previousMessage.thought ?? ""
                    let isThoughtAppend = (message.thought ?? "").count > previousThought.count &&
                        (message.thought ?? "").hasPrefix(previousThought)

                    thoughtTextView.textStorage?.setAttributedString(
                        formatThoughtMarkdownString(
                            message.thought ?? "",
                            fontSize: 11.5,
                            alpha: 0.8,
                            lineSpacing: isCompact ? 1.5 : 2
                        )
                    )
                    if thoughtChanged && (isCompact || isThoughtExpanded) {
                        animateNewThoughtText(
                            startLocation: isThoughtAppend ? previousThoughtLength : 0
                        )
                    }
                } else {
                    thoughtHeaderButton.isHidden = true
                    thoughtTextView.isHidden = true
                    thoughtTextView.alphaValue = 0
                    thoughtTextView.removeFromSuperview()
                }
            }

            // 2. Tool calls. Keep unchanged cards alive while a running tool
            // streams status/output updates. Rebuilding the whole list here
            // made every tool event recreate all headers and nested views.
            if toolCallsChanged || editedFilesChanged || themeChanged || accentChanged || displayModeChanged || toolCallViews.isEmpty {
                updateToolCallViews(
                    previousItems: previousMessage.toolCalls,
                    newItems: message.toolCalls,
                    styleChanged: themeChanged || displayModeChanged,
                    editedFilesChanged: editedFilesChanged
                )
            }

            // 3. Keep the streaming path incremental. Re-parsing the entire
            // growing markdown response and recreating every NSTextView for
            // each chunk causes long main-thread stalls while the user scrolls.
            // The completed response is compiled once below, after streaming
            // has stopped.
            let finishedStreaming = previousMessage.isStreaming && !message.isStreaming
            let textPartCount = message.orderedParts.reduce(into: 0) { count, part in
                if case .text = part { count += 1 }
            }
            if message.isStreaming && textPartCount <= 1 {
                if contentChanged || themeChanged || markdownViews.isEmpty {
                    updateStreamingTextView(content: message.content, themeChanged: themeChanged)
                }
                if !markdownViews.isEmpty {
                    markdownViewsByTextPart = [markdownViews]
                }
            } else if contentChanged || finishedStreaming || themeChanged || (markdownViews.isEmpty && !message.content.isEmpty) {
                rebuildMarkdownViews(content: message.content, highlightCode: true)
            }

            // 4. Edited files card
            if let summary = message.editedFilesSummary, !message.toolCalls.isEmpty {
                if let card = editedFilesCardView as? AgentEditedFilesCardView {
                    card.configure(
                        summary: summary,
                        theme: theme,
                        accentColor: accentColor,
                        disableAgentColors: toolcallColorMode != .full,
                        isLiveStreaming: message.isStreaming
                    )
                    card.onReview = onReview
                    card.onRevert = onRevert
                    card.onRestore = onRestore
                } else {
                    editedFilesCardView?.removeFromSuperview()
                    let card = AgentEditedFilesCardView(
                        summary: summary,
                        theme: theme,
                        accentColor: accentColor,
                        disableAgentColors: toolcallColorMode != .full,
                        isLiveStreaming: message.isStreaming
                    )
                    card.onReview = onReview
                    card.onRevert = onRevert
                    card.onRestore = onRestore
                    addSubview(card)
                    editedFilesCardView = card
                    pendingEditedFilesCardAppearance = card
                }
            } else {
                editedFilesCardView?.removeFromSuperview()
                editedFilesCardView = nil
                pendingEditedFilesCardAppearance = nil
            }

            rebuildAssistantViewOrder()

            // Animating every token starts a new Core Animation transaction and
            // makes AppKit chase a moving document height. Keep streaming
            // updates immediate; completed responses can still use the normal
            // layout transition when needed.
            if shouldAnimateStreamingText && !message.isStreaming {
                animateStreamingTextUpdate()
            }

            typingIndicatorView.stopAnimating()
            typingIndicatorView.isHidden = true
            roleIconView.layer?.removeAnimation(forKey: "agentRolePulse")
            roleIconView.layer?.opacity = 1.0
            if message.role == .assistant && message.isStreaming && message.hasVisibleContent {
                avatarAuraView.configure(colors: theme.agentAuraColors, isDark: theme.isDark)
                avatarAuraView.startAnimating()
            } else {
                let justFinishedStreaming = previousMessage.id == message.id && previousMessage.isStreaming
                avatarAuraView.stopAnimating(animated: justFinishedStreaming)
            }
        }

        if !message.isStreaming || themeChanged {
            updateNativeTextSelection()
        }
    }

    public var isWaitingForResponse: Bool {
        guard message.role == .assistant && message.isStreaming else { return false }
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTools = !message.toolCalls.isEmpty
        let hasTopThought = (message.thought?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        let hasInline = hasInlineThoughtParts
        return !hasContent && !hasTools && !hasTopThought && !hasInline
    }

    func updateNativeTextSelection() {
        func update(_ view: NSView) {
            if let textView = view as? AgentSelectableTextView {
                textView.isSelectable = nativeTextSelectionEnabled
                textView.isEditable = false
            }
            for subview in view.subviews {
                update(subview)
            }
        }
        update(self)
    }

    func updateToolCallViews(
        previousItems: [ToolCallItem],
        newItems: [ToolCallItem],
        styleChanged: Bool,
        editedFilesChanged: Bool = false
    ) {
        let previousIDs = Set(previousItems.map(\.id))

        // Fast path: if style hasn't changed and we already have tool views,
        // reconcile incrementally by tool ID without tearing down views.
        if !styleChanged && !toolCallViews.isEmpty {
            var existingViewsByID: [String: NSView] = [:]
            existingViewsByID.reserveCapacity(toolCallViews.count)
            for (id, view) in zip(toolCallIDs, toolCallViews) {
                existingViewsByID[id] = view
            }

            var nextViews: [NSView] = []
            nextViews.reserveCapacity(newItems.count)
            var nextIDs: [String] = []
            nextIDs.reserveCapacity(newItems.count)
            var retainedViewIDs = Set<ObjectIdentifier>()

            for (index, item) in newItems.enumerated() {
                nextIDs.append(item.id)
                if let existing = existingViewsByID[item.id],
                   let card = existing as? AgentToolCardView,
                   card.canUpdateInPlace(with: item) {
                    let prevItem = index < previousItems.count && previousItems[index].id == item.id ? previousItems[index] : nil
                    if prevItem != item || editedFilesChanged {
                        card.update(item: item, theme: theme)
                    }
                    nextViews.append(card)
                    retainedViewIDs.insert(ObjectIdentifier(card))
                } else if let existing = existingViewsByID[item.id],
                          let simple = existing as? AgentSimpleToolCallView {
                    let prevItem = index < previousItems.count && previousItems[index].id == item.id ? previousItems[index] : nil
                    if prevItem != item {
                        let replacement = makeToolCallView(item: item, index: index)
                        existing.removeFromSuperview()
                        nextViews.append(replacement)
                        retainedViewIDs.insert(ObjectIdentifier(replacement))
                    } else {
                        nextViews.append(simple)
                        retainedViewIDs.insert(ObjectIdentifier(simple))
                    }
                } else {
                    let view = makeToolCallView(item: item, index: index)
                    nextViews.append(view)
                    retainedViewIDs.insert(ObjectIdentifier(view))
                    if !previousIDs.contains(item.id) {
                        pendingToolCallAppearances.append(view)
                    }
                }
            }

            // Clean up old views that are no longer part of newItems
            for view in toolCallViews {
                if !retainedViewIDs.contains(ObjectIdentifier(view)) {
                    view.removeFromSuperview()
                }
            }

            toolCallViews = nextViews
            toolCallIDs = nextIDs
            return
        }

        // Slow path: initial setup or theme/style changed
        for view in toolCallViews {
            view.removeFromSuperview()
        }
        toolCallViews.removeAll(keepingCapacity: true)
        toolCallIDs.removeAll(keepingCapacity: true)

        for (index, item) in newItems.enumerated() {
            let view = makeToolCallView(item: item, index: index)
            toolCallViews.append(view)
            toolCallIDs.append(item.id)
            let continuesPreviousCall = index < previousItems.count &&
                representsSameToolCall(previousItems[index], item)
            if !continuesPreviousCall && !previousIDs.contains(item.id) {
                pendingToolCallAppearances.append(view)
            }
        }
    }

    func representsSameToolCall(_ previous: ToolCallItem, _ current: ToolCallItem) -> Bool {
        if previous.id == current.id { return true }
        return previous.toolName == current.toolName &&
            previous.path == current.path &&
            previous.command == current.command
    }

    func prepareUserMessageAppearance() {
        pendingUserMessageAppearance = true
        userBubbleView.alphaValue = 0
    }

    func animatePendingAppearances(animated: Bool) {
        var views = pendingToolCallAppearances
        pendingToolCallAppearances.removeAll()
        if let pendingEditedFilesCardAppearance {
            views.append(pendingEditedFilesCardAppearance)
            self.pendingEditedFilesCardAppearance = nil
        }
        if pendingUserMessageAppearance {
            views.append(userBubbleView)
            pendingUserMessageAppearance = false
        }
        guard !views.isEmpty else { return }

        guard animated else {
            for view in views {
                view.alphaValue = 1
            }
            return
        }

        for view in views {
            view.alphaValue = 0
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for view in views {
                view.animator().alphaValue = 1
            }
        }
    }

    func animateStreamingTextUpdate() {
        guard let latestView = markdownViews.last else { return }

        // Keep the text readable while still giving each streamed update a
        // subtle entrance. A low starting alpha makes the whole line flash
        // gray on every chunk.
        latestView.alphaValue = 0.86
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            latestView.animator().alphaValue = 1
        }
    }

    func animateNewThoughtText(startLocation: Int) {
        guard !thoughtTextView.isHidden,
              let textStorage = thoughtTextView.textStorage,
              textStorage.length > startLocation else { return }

        if startLocation == 0 {
            thoughtFadeChunks.removeAll()
            thoughtFadeTimer?.invalidate()
            thoughtFadeTimer = nil
        }

        thoughtFadeChunks.removeAll { $0.range.location >= textStorage.length }
        thoughtFadeChunks.append(
            StreamingFadeChunk(
                range: NSRange(location: startLocation, length: textStorage.length - startLocation),
                startTime: CACurrentMediaTime()
            )
        )

        if thoughtFadeTimer == nil {
            thoughtFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                self?.updateThoughtFadeAnimation()
            }
        }
        updateThoughtFadeAnimation()
    }

    func updateThoughtFadeAnimation() {
        guard let textStorage = thoughtTextView.textStorage, textStorage.length > 0 else {
            thoughtFadeTimer?.invalidate()
            thoughtFadeTimer = nil
            thoughtFadeChunks.removeAll()
            return
        }

        let now = CACurrentMediaTime()
        let duration: TimeInterval = 0.16
        let expiredThoughtChunks = thoughtFadeChunks.filter { now - $0.startTime >= duration }
        thoughtFadeChunks.removeAll { now - $0.startTime >= duration }

        let baseColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
            .withAlphaComponent(0.8)
        textStorage.beginEditing()
        for chunk in expiredThoughtChunks {
            guard chunk.range.location + chunk.range.length <= textStorage.length else { continue }
            textStorage.addAttribute(
                .foregroundColor,
                value: baseColor,
                range: chunk.range
            )
        }
        for chunk in thoughtFadeChunks {
            guard chunk.range.location + chunk.range.length <= textStorage.length else { continue }
            let progress = min(1.0, max(0.0, (now - chunk.startTime) / duration))
            let alpha = 0.15 + (0.85 * progress)
            textStorage.addAttribute(
                .foregroundColor,
                value: baseColor.withAlphaComponent(alpha),
                range: chunk.range
            )
        }
        textStorage.endEditing()

        if thoughtFadeChunks.isEmpty {
            thoughtFadeTimer?.invalidate()
            thoughtFadeTimer = nil
        }
    }

    func clearAssistantViews() {
        for v in toolCallViews { v.removeFromSuperview() }
        toolCallViews.removeAll()
        toolCallIDs.removeAll()
        for (_, groupView) in toolGroupViewsByKey {
            groupView.removeFromSuperview()
        }
        toolGroupViewsByKey.removeAll()
        pendingToolCallAppearances.removeAll()
        pendingEditedFilesCardAppearance = nil
        pendingUserMessageAppearance = false
        clearInlineThoughtViews()
        for v in markdownViews { v.removeFromSuperview() }
        markdownViews.removeAll()
        markdownViewsByTextPart.removeAll()
        orderedAssistantViews.removeAll()
        editedFilesCardView?.removeFromSuperview()
        editedFilesCardView = nil
        streamingRenderedContent = ""
        streamingLineCache.removeAll()
        streamingFadeTimer?.invalidate()
        streamingFadeTimer = nil
        streamingFadeChunks.removeAll()
        streamingBaseAttributedString = nil
        thoughtFadeTimer?.invalidate()
        thoughtFadeTimer = nil
        thoughtFadeChunks.removeAll()
        previousStreamedLength = 0
        cachedParsedDiffFiles = nil
        cachedParsedDiffDataCount = -1
        typingIndicatorView.stopAnimating()
        typingIndicatorView.isHidden = true
        avatarAuraView.stopAnimating(animated: false)
        roleIconView.layer?.removeAnimation(forKey: "agentRolePulse")
        roleIconView.layer?.opacity = 1.0
    }

    public func refreshAvatars() {
        let settings = AgentAvatarProvider.loadSettings()
        if message.role == .user {
            let userSize = settings.userAvatarSize
            roleIconView.image = AgentAvatarProvider.userAvatarImage
            roleIconView.layer?.cornerRadius = userSize / 2
            roleIconView.layer?.masksToBounds = true
            roleIconView.layer?.backgroundColor = nil
        } else {
            let agentSize = AgentAvatarProvider.currentAgentAvatarSize(for: agentId)
            let showCircle = AgentAvatarProvider.shouldShowAgentCircle(for: agentId)
            if let customAgentImg = AgentAvatarProvider.customAgentAvatarImage(for: agentId) {
                roleIconView.image = customAgentImg
                roleIconView.layer?.cornerRadius = agentSize / 2
                roleIconView.layer?.masksToBounds = true
                roleIconView.layer?.backgroundColor = nil
                roleIconView.contentTintColor = nil
            } else {
                let iconPaddingSize = showCircle ? ceil(agentSize * 0.62) : agentSize
                roleIconView.image = AgentAvatarProvider.agentIconImage(for: agentIconName, size: iconPaddingSize)
                if showCircle {
                    roleIconView.layer?.cornerRadius = agentSize / 2
                    roleIconView.layer?.masksToBounds = true
                    let circleBg = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor).withAlphaComponent(0.12)
                    roleIconView.layer?.backgroundColor = circleBg.cgColor
                } else {
                    roleIconView.layer?.cornerRadius = 0
                    roleIconView.layer?.masksToBounds = false
                    roleIconView.layer?.backgroundColor = nil
                }
                roleIconView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.85) ?? .secondaryLabelColor
            }
        }
        invalidateLayoutCache()
    }

    public func refreshUserAvatar() {
        refreshAvatars()
    }

    public func startEditingQueuedMessage() {
        guard message.isQueued else { return }
        isEditingQueuedMessage = true
        queuedEditorView.setText(message.content, theme: theme, accentColor: accentColor)
        queuedEditorView.isHidden = false
        userContentContainerView.isHidden = true
        invalidateLayoutCache()
        onRequestLayout?()
        DispatchQueue.main.async { [weak self] in
            self?.queuedEditorView.focus()
        }
    }

    public func stopEditingQueuedMessage() {
        guard isEditingQueuedMessage else { return }
        isEditingQueuedMessage = false
        queuedEditorView.isHidden = true
        userContentContainerView.isHidden = userContentViews.isEmpty
        invalidateLayoutCache()
        onRequestLayout?()
    }

    func clearUserViews() {
        queuedHeaderView.isHidden = true
        queuedEditorView.isHidden = true
        isEditingQueuedMessage = false
        for v in userContentViews { v.removeFromSuperview() }
        userContentViews.removeAll()
        userImageViews.forEach { $0.removeFromSuperview() }
        userImageViews.removeAll()
        renderedUserContent = nil
        renderedUserThemeId = nil
    }

    func rebuildUserContentViews(content: String, forceRebuild: Bool = false) {
        if !forceRebuild && renderedUserThemeId == theme.id && renderedUserContent == content && !userContentViews.isEmpty {
            return
        }
        renderedUserContent = content
        renderedUserThemeId = theme.id

        for v in userContentViews {
            v.removeFromSuperview()
        }
        userContentViews.removeAll()
        userTextView.isHidden = true

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let inlineMarkerCount = trimmed.components(separatedBy: AgentImageAttachment.inlineTextMarker).count - 1
        let hasInlineImagePositions = inlineMarkerCount > 0 && inlineMarkerCount == message.images.count
        let blocks = AgentMarkdownParser.parse(
            hasInlineImagePositions ? trimmed : AgentImageAttachment.removingInlineTextMarkers(from: trimmed)
        )
        let hasComplexBlocks = blocks.contains { block in
            if case .codeBlock = block { return true }
            if case .quote = block { return true }
            return false
        }
        if hasInlineImagePositions && !hasComplexBlocks {
            var nextImageIndex = 0
            let tv = AgentSelectableTextView()
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "user_text_inline_images"
            tv.isSelectable = true
            tv.textStorage?.setAttributedString(inlineImageAttributedText(from: trimmed, imageIndex: &nextImageIndex))
            userContentContainerView.addSubview(tv)
            userContentViews.append(tv)
            return
        }

        guard !blocks.isEmpty else {
            let tv = AgentSelectableTextView()
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "user_text_0"
            tv.isSelectable = true
            let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
            let bodyColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 3
            bodyStyle.paragraphSpacing = 0
            tv.textStorage?.setAttributedString(NSAttributedString(string: trimmed, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: bodyStyle
            ]))
            userContentContainerView.addSubview(tv)
            userContentViews.append(tv)
            return
        }

        var currentText = NSMutableAttributedString()
        var textIndex = 0

        func flushCurrentText() {
            let s = currentText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else {
                currentText = NSMutableAttributedString()
                return
            }
            let tv = AgentSelectableTextView()
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "user_text_\(textIndex)"
            tv.isSelectable = true
            tv.textStorage?.setAttributedString(currentText)
            userContentContainerView.addSubview(tv)
            userContentViews.append(tv)
            textIndex += 1
            currentText = NSMutableAttributedString()
        }

        let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let bodyColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 3
        bodyStyle.paragraphSpacing = 0
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: bodyColor,
            .paragraphStyle: bodyStyle
        ]

        var lastBlockWasListItem = false
        var nextInlineImageIndex = 0

        for block in blocks {
            switch block {
            case .codeBlock(let language, let code):
                flushCurrentText()
                let codeView = AgentUserCodeBlockView()
                codeView.configure(
                    code: code,
                    language: language,
                    theme: theme,
                    accentColor: accentColor,
                    messageId: message.id,
                    index: userContentViews.count,
                    parentCell: self
                )
                userContentContainerView.addSubview(codeView)
                userContentViews.append(codeView)
                lastBlockWasListItem = false

            case .paragraph(let text):
                let attr: NSAttributedString
                if hasInlineImagePositions && text.contains(AgentImageAttachment.inlineTextMarker) {
                    attr = inlineImageAttributedText(
                        from: text,
                        imageIndex: &nextInlineImageIndex,
                        font: bodyFont,
                        color: bodyColor,
                        paragraphStyle: bodyStyle
                    )
                } else {
                    attr = formatInlineMarkdownString(text, font: bodyFont, color: bodyColor, paragraphStyle: bodyStyle)
                }
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: separatorAttrs))
                }
                currentText.append(attr)
                lastBlockWasListItem = false

            case .header(let level, let text):
                let hFont = NSFont.systemFont(ofSize: level <= 2 ? 14.5 : 13.5, weight: .bold)
                let attr = formatInlineMarkdownString(text, font: hFont, color: bodyColor, paragraphStyle: bodyStyle)
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: separatorAttrs))
                }
                currentText.append(attr)
                lastBlockWasListItem = false

            case .bulletItem(let text):
                let bStyle = NSMutableParagraphStyle()
                bStyle.lineSpacing = 3
                bStyle.headIndent = 14
                bStyle.firstLineHeadIndent = 0
                bStyle.paragraphSpacing = 0
                let attr = formatInlineMarkdownString("• \(text)", font: bodyFont, color: bodyColor, paragraphStyle: bStyle)
                if currentText.length > 0 {
                    let sep = lastBlockWasListItem ? "\n" : "\n\n"
                    currentText.append(NSAttributedString(string: sep, attributes: separatorAttrs))
                }
                currentText.append(attr)
                lastBlockWasListItem = true

            case .numberedItem(let number, let text):
                let nStyle = NSMutableParagraphStyle()
                nStyle.lineSpacing = 3
                nStyle.headIndent = 14
                nStyle.firstLineHeadIndent = 0
                nStyle.paragraphSpacing = 0
                let attr = formatInlineMarkdownString("\(number). \(text)", font: bodyFont, color: bodyColor, paragraphStyle: nStyle)
                if currentText.length > 0 {
                    let sep = lastBlockWasListItem ? "\n" : "\n\n"
                    currentText.append(NSAttributedString(string: sep, attributes: separatorAttrs))
                }
                currentText.append(attr)
                lastBlockWasListItem = true

            case .quote(let text):
                flushCurrentText()
                let quoteAttr = formatQuoteAttributedText(text, theme: theme)
                let quoteView = AgentUserQuoteBlockView()
                quoteView.configure(
                    attributedText: quoteAttr,
                    theme: theme,
                    accentColor: accentColor,
                    messageId: message.id,
                    index: userContentViews.count,
                    parentCell: self
                )
                userContentContainerView.addSubview(quoteView)
                userContentViews.append(quoteView)

            case .divider:
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n───\n", attributes: [.foregroundColor: NSColor.separatorColor]))
                }

            case .table, .image:
                break

            @unknown default:
                break
            }
        }
        flushCurrentText()
    }

    private func inlineImageAttributedText(
        from content: String,
        imageIndex: inout Int,
        font: NSFont? = nil,
        color: NSColor? = nil,
        paragraphStyle: NSMutableParagraphStyle? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = content as NSString
        let bodyFont = font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        let bodyColor = color ?? (NSColor(cgColor: theme.foreground.cgColor) ?? .textColor)
        let bodyStyle: NSMutableParagraphStyle = paragraphStyle ?? {
            let s = NSMutableParagraphStyle()
            s.lineSpacing = 3
            return s
        }()

        var textLocation = 0
        while textLocation < source.length, imageIndex < message.images.count {
            let markerRange = source.range(
                of: AgentImageAttachment.inlineTextMarker,
                options: [],
                range: NSRange(location: textLocation, length: source.length - textLocation)
            )
            guard markerRange.location != NSNotFound else { break }
            if markerRange.location > textLocation {
                let segment = source.substring(with: NSRange(location: textLocation, length: markerRange.location - textLocation))
                result.append(
                    formatInlineMarkdownString(segment, font: bodyFont, color: bodyColor, paragraphStyle: bodyStyle)
                )
            }

            let currentImageOrdinal = imageIndex
            let item = message.images[currentImageOrdinal]
            let display = ImageAttachmentHelpers.inlineDisplayImage(for: item)
            if let image = display.image {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = display.bounds
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes(
                    [
                        .font: bodyFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: bodyStyle,
                        AgentSelectableTextView.userInlineImageIndexKey: currentImageOrdinal
                    ],
                    range: NSRange(location: 0, length: attachmentString.length)
                )
                result.append(attachmentString)
            }

            imageIndex += 1
            textLocation = NSMaxRange(markerRange)
        }

        if textLocation < source.length {
            let segment = source.substring(from: textLocation)
            result.append(
                formatInlineMarkdownString(segment, font: bodyFont, color: bodyColor, paragraphStyle: bodyStyle)
            )
        }
        return result
    }

    func measureUserContentViewsHeight(width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        let wrapWidth = max(50, width - 6)
        for (i, view) in userContentViews.enumerated() {
            if let tv = view as? AgentSelectableTextView {
                let h = measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: wrapWidth)
                total += h
            } else if let cb = view as? AgentUserCodeBlockView {
                total += cb.height(for: width)
            } else if let qv = view as? AgentUserQuoteBlockView {
                total += qv.height(for: width)
            }
            if i < userContentViews.count - 1 {
                total += 8
            }
        }
        return total
    }

    func clearInlineThoughtViews() {
        for view in inlineThoughtViews {
            view.removeFromSuperview()
        }
        inlineThoughtViews.removeAll()
    }

    func rebuildInlineThoughtViews() {
        let expandedStates = inlineThoughtViews.map(\.isExpanded)
        clearInlineThoughtViews()

        var thoughtIndex = 0
        for part in message.orderedParts {
            guard case .thought(let text) = part else { continue }

            let title = thoughtPanelTitle(text)
            let body = thoughtBodyText(text)
            let isExpandable = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                normalizedThoughtText(body) != normalizedThoughtText(title)
            let thoughtView = AgentThoughtBlockView(
                title: title,
                attributedText: formatThoughtMarkdownString(
                    isExpandable ? body : "",
                    fontSize: 11.5,
                    alpha: 0.8,
                    lineSpacing: 0
                ),
                isExpandable: isExpandable
            )
            thoughtView.textView.parentCell = self
            thoughtView.textView.cellId = message.id
            thoughtView.textView.tvKey = "thought_\(thoughtIndex)"
            thoughtView.textView.isSelectable = nativeTextSelectionEnabled
            thoughtView.textView.isEditable = false
            thoughtView.updateColors(theme: theme)
            if thoughtIndex < expandedStates.count {
                thoughtView.setExpanded(expandedStates[thoughtIndex])
            }
            thoughtView.onToggle = { [weak self] in
                self?.invalidateLayoutCache()
                self?.onToggleThought?()
            }
            inlineThoughtViews.append(thoughtView)
            thoughtIndex += 1
        }
    }

    func thoughtPanelTitle(_ text: String) -> String {
        let firstLine = text
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? text
        let rendered = formatThoughtMarkdownString(
            firstLine.trimmingCharacters(in: .whitespacesAndNewlines),
            fontSize: 11.5,
            alpha: 0.8,
            lineSpacing: 0
        ).string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rendered.count > 120 else { return rendered.isEmpty ? "Thoughts" : rendered }
        return String(rendered.prefix(117)) + "…"
    }

    func thoughtBodyText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return "" }

        return lines
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func normalizedThoughtText(_ text: String) -> String {
        formatThoughtMarkdownString(text, fontSize: 11.5, alpha: 1, lineSpacing: 0)
            .string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rebuildMarkdownViews(content: String, highlightCode: Bool) {
        let textParts: [String] = message.orderedParts.compactMap { part in
            if case .text(let text) = part { return text }
            return nil
        }

        if textParts.count == 1,
           markdownViews.count == 1,
           let existing = markdownViews[0] as? AgentSelectableTextView,
           existing.tvKey == "md_0" {
            let text = textParts[0]
            let sections = compileSections(
                from: text,
                splitRichText: !nativeTextSelectionEnabled,
                allowUnclosedTrailingMermaid: !message.isStreaming
            )
            if sections.count == 1, case .richText(let attr) = sections[0] {
                existing.cellId = message.id
                existing.isSelectable = nativeTextSelectionEnabled
                if let prevBase = streamingBaseAttributedString,
                   prevBase.isEqual(to: attr),
                   let ts = existing.textStorage,
                   ts.length == attr.length {
                    // Already up-to-date from streaming; let any active tail fade finish naturally.
                } else {
                    streamingFadeTimer?.invalidate()
                    streamingFadeTimer = nil
                    streamingFadeChunks.removeAll()
                    if let ts = existing.textStorage {
                        let commonLen = streamingBaseAttributedString.map {
                            ts.length == $0.length ? Self.commonAttributedPrefixLength($0, attr) : 0
                        } ?? 0
                        ts.beginEditing()
                        if commonLen == 0 {
                            ts.setAttributedString(attr)
                        } else {
                            let oldTail = NSRange(location: commonLen, length: ts.length - commonLen)
                            let newTail = NSRange(location: commonLen, length: attr.length - commonLen)
                            ts.replaceCharacters(in: oldTail, with: attr.attributedSubstring(from: newTail))
                        }
                        ts.endEditing()
                    }
                    streamingBaseAttributedString = nil
                }
                streamingRenderedContent = ""
                markdownViewsByTextPart = [[existing]]
                invalidateLayoutCache()
                return
            }
        }

        streamingFadeTimer?.invalidate()
        streamingFadeTimer = nil
        streamingFadeChunks.removeAll()
        streamingBaseAttributedString = nil
        for v in markdownViews { v.removeFromSuperview() }
        markdownViews.removeAll()
        markdownViewsByTextPart.removeAll()
        streamingRenderedContent = ""
        invalidateLayoutCache()

        var sectionIndex = 0
        for text in textParts {
            let sections = compileSections(
                from: text,
                splitRichText: !nativeTextSelectionEnabled,
                allowUnclosedTrailingMermaid: !message.isStreaming
            )
            var partViews: [NSView] = []
            for section in sections {
                let view = createSectionView(
                    section: section,
                    index: sectionIndex,
                    highlightCode: highlightCode
                )
                sectionIndex += 1
                addSubview(view)
                markdownViews.append(view)
                partViews.append(view)
            }
            markdownViewsByTextPart.append(partViews)
        }
    }

    func rebuildAssistantViewOrder() {
        var textPartIndex = 0
        var thoughtPartIndex = 0
        var nextViews: [NSView] = []
        var activeGroupKeys = Set<String>()
        var currentToolRun: [(id: String, view: NSView)] = []

        func flushToolRun() {
            guard !currentToolRun.isEmpty else { return }
            if currentToolRun.count >= 2 {
                let groupKey = currentToolRun[0].id
                activeGroupKeys.insert(groupKey)
                let viewsInGroup = currentToolRun.map(\.view)
                let isExp = expandedToolGroupKeys.contains(groupKey)
                let groupView: AgentToolGroupView
                if let existing = toolGroupViewsByKey[groupKey] {
                    groupView = existing
                    groupView.update(toolViews: viewsInGroup, theme: theme, isExpanded: isExp, isCompactMode: isCompactMode)
                    if groupView.superview !== self {
                        addSubview(groupView)
                    }
                } else {
                    groupView = AgentToolGroupView(
                        groupKey: groupKey,
                        toolViews: viewsInGroup,
                        theme: theme,
                        isExpanded: isExp,
                        isCompactMode: isCompactMode
                    )
                    groupView.onToggle = { [weak self, weak groupView] in
                        guard let self, let groupView else { return }
                        if groupView.isExpanded {
                            self.expandedToolGroupKeys.insert(groupView.groupKey)
                        } else {
                            self.expandedToolGroupKeys.remove(groupView.groupKey)
                        }
                        self.invalidateLayoutCache()
                        self.onToggleTool?()
                    }
                    addSubview(groupView)
                    toolGroupViewsByKey[groupKey] = groupView
                }
                if !isExp {
                    for v in viewsInGroup where v.superview != nil {
                        v.removeFromSuperview()
                    }
                }
                let groupedViewIDs = Set(viewsInGroup.map(ObjectIdentifier.init))
                pendingToolCallAppearances.removeAll { groupedViewIDs.contains(ObjectIdentifier($0)) }
                nextViews.append(groupView)
            } else {
                let singleView = currentToolRun[0].view
                if singleView.superview !== self {
                    singleView.removeFromSuperview()
                    addSubview(singleView)
                }
                singleView.isHidden = false
                singleView.alphaValue = 1
                nextViews.append(singleView)
            }
            currentToolRun.removeAll(keepingCapacity: true)
        }

        for part in message.orderedParts {
            switch part {
            case .toolCall(let id):
                if let index = toolCallIDs.firstIndex(of: id) {
                    currentToolRun.append((id: id, view: toolCallViews[index]))
                }
            case .thought:
                if thoughtPartIndex < inlineThoughtViews.count {
                    let thoughtView = inlineThoughtViews[thoughtPartIndex]
                    currentToolRun.append((id: "thought_\(thoughtPartIndex)", view: thoughtView))
                }
                thoughtPartIndex += 1
            case .text:
                flushToolRun()
                if textPartIndex < markdownViewsByTextPart.count {
                    nextViews.append(contentsOf: markdownViewsByTextPart[textPartIndex])
                }
                textPartIndex += 1
            }
        }
        flushToolRun()

        for (key, groupView) in toolGroupViewsByKey where !activeGroupKeys.contains(key) {
            groupView.removeFromSuperview()
            toolGroupViewsByKey.removeValue(forKey: key)
        }

        if let card = editedFilesCardView {
            nextViews.append(card)
        }

        orderedAssistantViews = nextViews
    }

    func updateStreamingTextView(content: String, themeChanged: Bool) {
        let textView: AgentSelectableTextView
        if !themeChanged,
           markdownViews.count == 1,
           let existing = markdownViews[0] as? AgentSelectableTextView,
           existing.tvKey == "md_0" {
            textView = existing
        } else {
            for v in markdownViews { v.removeFromSuperview() }
            markdownViews.removeAll()

            textView = AgentSelectableTextView()
            textView.parentCell = self
            textView.cellId = message.id
            textView.tvKey = "md_0"
            textView.isSelectable = nativeTextSelectionEnabled
            addSubview(textView)
            markdownViews.append(textView)
            streamingRenderedContent = ""
            streamingBaseAttributedString = nil
        }

        let sections = compileSections(from: content, splitRichText: false)
        let mutable = NSMutableAttributedString()
        for (i, section) in sections.enumerated() {
            switch section {
            case .richText(let attr):
                if i > 0 && mutable.length > 0 {
                    mutable.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                }
                mutable.append(attr)
            case .quote(let attr):
                if i > 0 && mutable.length > 0 {
                    mutable.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                }
                let quoteMutable = NSMutableAttributedString()
                quoteMutable.append(NSAttributedString(string: "▎ ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor
                ]))
                quoteMutable.append(attr)
                mutable.append(quoteMutable)
            case .codeBlock(_, let code), .mermaidDiagram(let code):
                if i > 0 && mutable.length > 0 {
                    mutable.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 2
                let codeColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
                let codeBg = (NSColor(cgColor: theme.gutterBackground.cgColor) ?? NSColor.windowBackgroundColor).withAlphaComponent(0.65)
                let codeAttr = NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: codeColor,
                    .backgroundColor: codeBg,
                    .paragraphStyle: style
                ])
                mutable.append(codeAttr)
            case .divider:
                if i > 0 && mutable.length > 0 {
                    mutable.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                }
                let divStyle = NSMutableParagraphStyle()
                divStyle.alignment = .center
                divStyle.paragraphSpacing = 6
                divStyle.paragraphSpacingBefore = 6
                let divColor = (NSColor(cgColor: theme.excerptHeaderBorder.cgColor) ?? .separatorColor).withAlphaComponent(0.4)
                let divAttr = NSAttributedString(string: "────────────────────────────────────────\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .light),
                    .foregroundColor: divColor,
                    .paragraphStyle: divStyle
                ])
                mutable.append(divAttr)
            }
        }

        if mutable.length == 0 && !content.isEmpty {
            let font = NSFont.systemFont(ofSize: 13)
            let color = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            mutable.append(NSAttributedString(string: content, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]))
        }

        // Time-based left-to-right fade-in: each newly added token chunk fades in over 160ms
        // and automatically reaches 100% solid opacity even if streaming pauses or tool calls start!
        let now = CACurrentMediaTime()
        let duration: TimeInterval = 0.16
        let expiredChunks = streamingFadeChunks.filter { now - $0.startTime >= duration }
        streamingFadeChunks.removeAll { now - $0.startTime >= duration }

        let newLength = mutable.length
        if newLength < previousStreamedLength {
            streamingFadeChunks.removeAll { $0.range.location >= newLength }
        }
        if newLength > previousStreamedLength {
            let addedRange = NSRange(location: previousStreamedLength, length: newLength - previousStreamedLength)
            streamingFadeChunks.append(StreamingFadeChunk(range: addedRange, startTime: now))
            if streamingFadeTimer == nil {
                streamingFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                    self?.updateStreamingFadeAnimation()
                }
            }
        }
        previousStreamedLength = newLength

        let commonPrefixLen: Int
        if let prevBase = streamingBaseAttributedString,
           let ts = textView.textStorage,
           ts.length == prevBase.length {
            commonPrefixLen = Self.commonAttributedPrefixLength(prevBase, mutable)
        } else {
            commonPrefixLen = 0
        }
        streamingBaseAttributedString = NSAttributedString(attributedString: mutable)

        if let textStorage = textView.textStorage {
            let baseColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            textStorage.beginEditing()
            if commonPrefixLen == 0 {
                textStorage.setAttributedString(mutable)
            } else {
                let oldTailRange = NSRange(location: commonPrefixLen, length: textStorage.length - commonPrefixLen)
                let newTailRange = NSRange(location: commonPrefixLen, length: mutable.length - commonPrefixLen)
                textStorage.replaceCharacters(in: oldTailRange, with: mutable.attributedSubstring(from: newTailRange))
                for chunk in expiredChunks where chunk.range.location < commonPrefixLen {
                    let clampedLen = min(chunk.range.length, commonPrefixLen - chunk.range.location)
                    if clampedLen > 0 {
                        let prefixChunkRange = NSRange(location: chunk.range.location, length: clampedLen)
                        applyStreamingForeground(alpha: 1.0, in: prefixChunkRange, from: mutable, to: textStorage, fallbackColor: baseColor)
                    }
                }
            }
            for chunk in streamingFadeChunks {
                let progress = min(1.0, max(0.0, (now - chunk.startTime) / duration))
                let alpha = 0.15 + (0.85 * progress)
                applyStreamingForeground(alpha: alpha, in: chunk.range, from: mutable, to: textStorage, fallbackColor: baseColor)
            }
            textStorage.endEditing()
        }
        textView.needsDisplay = true
        streamingRenderedContent = content
    }

    private static func commonAttributedPrefixLength(_ oldAttr: NSAttributedString, _ newAttr: NSAttributedString) -> Int {
        let minLen = min(oldAttr.length, newAttr.length)
        guard minLen > 0 else { return 0 }
        let nsOld = oldAttr.string as NSString
        var searchLen = minLen
        for _ in 0..<3 {
            guard searchLen > 0 else { break }
            let nlRange = nsOld.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: searchLen))
            guard nlRange.location != NSNotFound else { break }
            let candidateLen = nlRange.location + 1
            let prefixRange = NSRange(location: 0, length: candidateLen)
            if oldAttr.attributedSubstring(from: prefixRange).isEqual(to: newAttr.attributedSubstring(from: prefixRange)) {
                return candidateLen
            }
            searchLen = nlRange.location
        }
        return 0
    }

    func updateStreamingFadeAnimation() {
        guard let textView = markdownViews.first as? AgentSelectableTextView,
              let textStorage = textView.textStorage,
              textStorage.length > 0 else {
            streamingFadeTimer?.invalidate()
            streamingFadeTimer = nil
            streamingFadeChunks.removeAll()
            streamingBaseAttributedString = nil
            return
        }

        let now = CACurrentMediaTime()
        let duration: TimeInterval = 0.16
        let expiredChunks = streamingFadeChunks.filter { now - $0.startTime >= duration }
        streamingFadeChunks.removeAll { now - $0.startTime >= duration }

        let baseColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        textStorage.beginEditing()
        if let base = streamingBaseAttributedString {
            for chunk in expiredChunks {
                applyStreamingForeground(alpha: 1.0, in: chunk.range, from: base, to: textStorage, fallbackColor: baseColor)
            }
            for chunk in streamingFadeChunks {
                let progress = min(1.0, max(0.0, (now - chunk.startTime) / duration))
                let alpha = 0.15 + (0.85 * progress)
                applyStreamingForeground(alpha: alpha, in: chunk.range, from: base, to: textStorage, fallbackColor: baseColor)
            }
        }
        textStorage.endEditing()
        if streamingFadeChunks.isEmpty {
            streamingFadeTimer?.invalidate()
            streamingFadeTimer = nil
        }
    }

    private func applyStreamingForeground(
        alpha: CGFloat,
        in range: NSRange,
        from base: NSAttributedString,
        to target: NSMutableAttributedString,
        fallbackColor: NSColor
    ) {
        let clampedEnd = min(range.location + range.length, min(base.length, target.length))
        guard range.location >= 0, clampedEnd > range.location else { return }
        let safeRange = NSRange(location: range.location, length: clampedEnd - range.location)
        base.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, subrange, _ in
            let origColor = (value as? NSColor) ?? fallbackColor
            let finalColor = alpha >= 0.999 ? origColor : origColor.withAlphaComponent(origColor.alphaComponent * alpha)
            target.addAttribute(.foregroundColor, value: finalColor, range: subrange)
        }
    }

    func buildAssistantViews() {
        // 1. Thought block
        if let thought = message.thought, !thought.isEmpty {
            let isCompact = isCompactThought(thought)
            thoughtHeaderButton.isHidden = isCompact
            updateThoughtHeaderAppearance()
            thoughtHeaderButton.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.85) ?? NSColor.secondaryLabelColor
            let shouldShowThought = isCompact || isThoughtExpanded
            thoughtTextView.isHidden = !shouldShowThought
            thoughtTextView.alphaValue = shouldShowThought ? 1 : 0
            if shouldShowThought {
                if thoughtTextView.superview == nil {
                    addSubview(thoughtTextView)
                }
            } else {
                thoughtTextView.removeFromSuperview()
            }
            thoughtTextView.cellId = message.id
            thoughtTextView.tvKey = "thought"

            thoughtTextView.textStorage?.setAttributedString(
                formatThoughtMarkdownString(
                    thought,
                    fontSize: 11.5,
                    alpha: 0.8,
                    lineSpacing: isCompact ? 1.5 : 2
                )
            )
        } else {
            thoughtHeaderButton.isHidden = true
            thoughtTextView.isHidden = true
            thoughtTextView.alphaValue = 0
            thoughtTextView.removeFromSuperview()
        }

        // 2. Tool calls
        for (idx, tool) in message.toolCalls.enumerated() {
            let toolView = makeToolCallView(item: tool, index: idx)
            addSubview(toolView)
            toolCallViews.append(toolView)
        }

        // 3. Compile consecutive text into unified rich-text sections
        let sections = compileSections(from: message.content)
        for (idx, section) in sections.enumerated() {
            let view = createSectionView(section: section, index: idx)
            addSubview(view)
            markdownViews.append(view)
        }
    }

    func makeToolCallView(item: ToolCallItem, index: Int) -> NSView {
        if Self.usesSimpleToolCalls {
            return AgentSimpleToolCallView(item: item, theme: theme)
        }

        let isExp = expandedToolIds.contains(item.id)
        let card = AgentToolCardView(
            item: item,
            theme: theme,
            index: index,
            parentCell: self,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            initiallyExpanded: isExp
        )
        card.onReview = { [weak self] summary in
            self?.onReview?(summary)
        }
        card.onToggle = { [weak self, weak card] in
            guard let self, let card else { return }
            if card.isExpanded {
                self.expandedToolIds.insert(card.item.id)
            } else {
                self.expandedToolIds.remove(card.item.id)
            }
            self.invalidateLayoutCache()
            self.onToggleTool?()
        }
        return card
    }

    @objc func toggleThought() {
        isThoughtExpanded.toggle()
        updateThoughtHeaderAppearance()
        if isThoughtExpanded {
            if thoughtTextView.superview == nil {
                addSubview(thoughtTextView)
            }
            thoughtTextView.isHidden = false
            thoughtTextView.alphaValue = 1
        } else {
            thoughtTextView.isHidden = true
            thoughtTextView.alphaValue = 0
            thoughtTextView.removeFromSuperview()
        }
        invalidateLayoutCache()
        onToggleThought?()
    }

    func updateThoughtHeaderAppearance() {
        let textColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
        thoughtHeaderButton.attributedTitle = NSAttributedString(string: "Thoughts", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: textColor
        ])
        thoughtHeaderButton.contentTintColor = textColor
        let symbolName = isThoughtExpanded ? "chevron.down" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        thoughtHeaderButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isThoughtExpanded ? "Collapse thoughts" : "Expand thoughts"
        )?.withSymbolConfiguration(configuration)
    }

    func animateThoughtVisibility() {
        thoughtTextView.animator().alphaValue = isThoughtExpanded ? 1 : 0
    }

    func finishThoughtVisibilityAnimation() {
        if isThoughtExpanded {
            if thoughtTextView.superview == nil {
                addSubview(thoughtTextView)
            }
            thoughtTextView.isHidden = false
            thoughtTextView.alphaValue = 1
        } else {
            thoughtTextView.alphaValue = 0
            thoughtTextView.isHidden = true
            thoughtTextView.removeFromSuperview()
        }
    }
    var canRestoreCheckpoint: Bool {
        message.role == .user &&
        !message.isQueued &&
        message.checkpointSnapshot?.isGitRepository == true &&
        onRestoreCheckpoint != nil
    }

    var canUndoRestoreCheckpoint: Bool {
        message.role == .user &&
        !message.isQueued &&
        message.undoRestoreSnapshot?.isGitRepository == true &&
        onUndoRestoreCheckpoint != nil
    }

    func makeCheckpointMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if canUndoRestoreCheckpoint {
            let undoItem = NSMenuItem(
                title: "Undo Restore",
                action: #selector(handleContextUndoRestoreCheckpoint(_:)),
                keyEquivalent: ""
            )
            undoItem.target = self
            undoItem.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Undo Restore")
            items.append(undoItem)
        }
        if canRestoreCheckpoint {
            let item = NSMenuItem(
                title: "Restore Checkpoint",
                action: #selector(handleContextRestoreCheckpoint(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Restore Checkpoint")
            items.append(item)
        }
        return items
    }

    @objc private func handleContextRestoreCheckpoint(_ sender: Any?) {
        onRestoreCheckpoint?(message.id)
    }

    @objc private func handleContextUndoRestoreCheckpoint(_ sender: Any?) {
        onUndoRestoreCheckpoint?(message.id)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let items = makeCheckpointMenuItems()
        if !items.isEmpty {
            let menu = NSMenu()
            for item in items {
                menu.addItem(item)
            }
            return menu
        }
        return super.menu(for: event)
    }
}

extension AgentMessageCell {
    /// Keeps the avatar pinned to the top of the viewport while the message is scrolled,
    /// without leaving the cell bounds.
    func updateStickyAvatar(viewportTopInDocument clipTop: CGFloat) {
        stickyViewportTop = clipTop - frame.minY
        applyStickyAvatar()
    }

    /// Returns true if the message contains only a single visual line of text without
    /// images, quotes, tools, code blocks, or thoughts.
    var isSingleLineMessage: Bool {
        if message.role == .user {
            guard !message.isQueued,
                  userImageViews.isEmpty,
                  userContentViews.count == 1,
                  let tv = userContentViews.first as? AgentSelectableTextView else {
                return false
            }
            return isSingleLineTextView(tv)
        } else {
            let hasTopThought = (message.thought?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            guard message.toolCalls.isEmpty,
                  !hasTopThought,
                  !hasInlineThoughtParts,
                  inlineThoughtViews.isEmpty,
                  !message.isStreaming,
                  orderedAssistantViews.count == 1,
                  let tv = orderedAssistantViews.first as? AgentSelectableTextView else {
                return false
            }
            return isSingleLineTextView(tv)
        }
    }

    private func isSingleLineTextView(_ tv: NSTextView) -> Bool {
        guard let layoutManager = tv.layoutManager,
              let textContainer = tv.textContainer else {
            return !tv.string.contains("\n")
        }
        if tv.string.contains("\n") { return false }
        layoutManager.ensureLayout(for: textContainer)
        let numberOfGlyphs = layoutManager.numberOfGlyphs
        guard numberOfGlyphs > 0 else { return true }
        var lineRange = NSRange(location: 0, length: 0)
        layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lineRange)
        return NSMaxRange(lineRange) >= numberOfGlyphs
    }

    func applyStickyAvatar() {
        guard !roleIconView.isHidden, stickyViewportTop > -.greatestFiniteMagnitude / 2 else { return }
        if isSingleLineMessage {
            if roleIconView.frame.origin.y != stickyAvatarBaseY {
                roleIconView.frame.origin.y = stickyAvatarBaseY
            }
            syncAvatarAuraFrame()
            return
        }
        let size = roleIconView.frame.height
        let maxY = max(stickyAvatarBaseY, bounds.height - size - 2)
        let topInset = max(Self.stickyAvatarInset, ceil(AgentAvatarAuraView.maxAuraOutset(forAvatarSize: size)))
        let y = min(maxY, max(stickyAvatarBaseY, stickyViewportTop + topInset))
        if abs(roleIconView.frame.origin.y - y) > 0.01 {
            roleIconView.frame.origin.y = y
        }
        syncAvatarAuraFrame()
    }

    func syncAvatarAuraFrame() {
        let targetFrame = AgentAvatarAuraView.frame(around: roleIconView.frame)
        if avatarAuraView.frame != targetFrame {
            avatarAuraView.frame = targetFrame
        }
    }
}
