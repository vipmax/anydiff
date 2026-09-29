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
    public var onToggleUserExpand: (() -> Void)?
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
    public private(set) var message: AgentMessage
    var theme: Theme
    var accentColor: Color
    var toolcallColorMode: ToolcallColorMode
    let nativeTextSelectionEnabled: Bool
    var isThoughtExpanded: Bool = false
    var isUserTextExpanded: Bool = false
    let maxUserTextCollapsedHeight: CGFloat = 180
    let userTextCollapseThreshold: CGFloat = 240
    var expandedToolIds: Set<String> = []
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
    let userBubbleView = AgentFlippedView()
    let userContentContainerView = AgentFlippedView()
    let userTextView = AgentSelectableTextView()
    let userExpandButton = AgentHoverButton()
    var userImageViews: [NSButton] = []
    var userContentViews: [NSView] = []
    var renderedUserContent: String? = nil
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    let thoughtHeaderButton = NSButton()
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
    var streamingFadeChunks: [StreamingFadeChunk] = []
    var streamingFadeTimer: Timer?
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
        nativeTextSelectionEnabled: Bool = false
    ) {
        self.message = message
        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode
        self.nativeTextSelectionEnabled = nativeTextSelectionEnabled
        super.init(frame: .zero)
        setup()
        configure(message: message, theme: theme, accentColor: accentColor, toolcallColorMode: toolcallColorMode)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        userBubbleView.wantsLayer = true
        userBubbleView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        userBubbleView.layer?.cornerRadius = 13
        userBubbleView.layer?.borderWidth = 0.0
        userBubbleView.layer?.masksToBounds = false
        userBubbleView.layer?.shadowColor = nil
        userBubbleView.layer?.shadowOpacity = 0.0

        userContentContainerView.wantsLayer = true
        userContentContainerView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        userContentContainerView.layer?.masksToBounds = true
        userBubbleView.addSubview(userContentContainerView)
        userBubbleView.addSubview(userExpandButton)
        addSubview(userBubbleView)

        userExpandButton.target = self
        userExpandButton.action = #selector(toggleUserTextExpand)
        updateUserExpandButtonAppearance()

        thoughtHeaderButton.wantsLayer = true
        thoughtHeaderButton.layerContentsRedrawPolicy = .onSetNeedsDisplay
        thoughtHeaderButton.isBordered = false
        thoughtHeaderButton.setButtonType(.momentaryPushIn)
        thoughtHeaderButton.alignment = .left
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

    @objc func toggleUserTextExpand() {
        isUserTextExpanded.toggle()
        updateUserExpandButtonAppearance()
        invalidateLayoutCache()
        onToggleUserExpand?()
    }

    func updateUserExpandButtonAppearance() {
        let title = isUserTextExpanded ? "Show less" : "Show more"
        let symbolName = isUserTextExpanded ? "chevron.up" : "chevron.down"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            userExpandButton.image = img.withSymbolConfiguration(config)
        }
        userExpandButton.imagePosition = .imageTrailing
        userExpandButton.imageHugsTitle = true

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let textColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
        let attr = NSAttributedString(
            string: title + " ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: textColor.withAlphaComponent(0.9),
                .paragraphStyle: style
            ]
        )
        userExpandButton.attributedTitle = attr
        userExpandButton.contentTintColor = textColor.withAlphaComponent(0.9)
    }

    public func configure(
        message: AgentMessage,
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode = .full
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
        let displayModeChanged = toolcallColorMode != self.toolcallColorMode
        let thoughtChanged = previousMessage.thought != message.thought
        let toolCallsChanged = message.toolCalls != previousMessage.toolCalls
        let partsChanged = message.orderedParts != previousMessage.orderedParts
        let contentChanged = previousMessage.content.count != message.content.count || previousMessage.content != message.content
        let editedFilesChanged = previousMessage.editedFilesSummary != message.editedFilesSummary
        if editedFilesChanged {
            cachedParsedDiffFiles = nil
            cachedParsedDiffDataCount = -1
        }

        self.message = message
        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode
        invalidateLayoutCache()

        if message.role == .user {
            userTextView.cellId = message.id
            userTextView.tvKey = "user"
            userBubbleView.isHidden = false
            thoughtHeaderButton.isHidden = true
            thoughtTextView.isHidden = true
            thoughtTextView.alphaValue = 0
            thoughtTextView.removeFromSuperview()

            let focusCol = theme.focusColor.usingColorSpace(.deviceRGB) ?? theme.focusColor
            let inputBg = theme.inputBackground.usingColorSpace(.deviceRGB) ?? theme.inputBackground
            let bg = inputBg.blended(withFraction: 0.12, of: focusCol) ?? inputBg

            userBubbleView.layer?.backgroundColor = bg.cgColor
            userBubbleView.layer?.borderWidth = 0.0
            userBubbleView.layer?.borderColor = nil
            userBubbleView.layer?.shadowColor = nil
            userBubbleView.layer?.shadowOpacity = 0.0

            userImageViews.forEach { $0.removeFromSuperview() }
            userImageViews.removeAll()

            for (index, img) in message.images.enumerated() {
                if let nsImage = NSImage(data: img.data) {
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

            rebuildUserContentViews(content: message.content)
            updateUserExpandButtonAppearance()
            clearAssistantViews()
        } else {
            clearUserViews()
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
            if let summary = message.editedFilesSummary {
                if let card = editedFilesCardView as? AgentEditedFilesCardView {
                    card.configure(
                        summary: summary,
                        theme: theme,
                        accentColor: accentColor,
                        disableAgentColors: toolcallColorMode != .full
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
                        disableAgentColors: toolcallColorMode != .full
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
        }

        updateNativeTextSelection()
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
                        addSubview(replacement)
                        nextViews.append(replacement)
                        retainedViewIDs.insert(ObjectIdentifier(replacement))
                    } else {
                        nextViews.append(simple)
                        retainedViewIDs.insert(ObjectIdentifier(simple))
                    }
                } else {
                    let view = makeToolCallView(item: item, index: index)
                    addSubview(view)
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
            addSubview(view)
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
        thoughtFadeChunks.removeAll { now - $0.startTime >= duration }

        let baseColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
            .withAlphaComponent(0.8)
        textStorage.beginEditing()
        if thoughtFadeChunks.isEmpty {
            textStorage.addAttribute(
                .foregroundColor,
                value: baseColor,
                range: NSRange(location: 0, length: textStorage.length)
            )
        } else {
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
        streamingFadeTimer?.invalidate()
        streamingFadeTimer = nil
        streamingFadeChunks.removeAll()
        thoughtFadeTimer?.invalidate()
        thoughtFadeTimer = nil
        thoughtFadeChunks.removeAll()
        previousStreamedLength = 0
        cachedParsedDiffFiles = nil
        cachedParsedDiffDataCount = -1
    }

    func clearUserViews() {
        for v in userContentViews { v.removeFromSuperview() }
        userContentViews.removeAll()
        userImageViews.forEach { $0.removeFromSuperview() }
        userImageViews.removeAll()
        renderedUserContent = nil
    }

    func rebuildUserContentViews(content: String) {
        if renderedUserContent == content && !userContentViews.isEmpty {
            return
        }
        renderedUserContent = content

        for v in userContentViews {
            v.removeFromSuperview()
        }
        userContentViews.removeAll()
        userTextView.isHidden = true

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let blocks = AgentMarkdownParser.parse(trimmed)
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
        bodyStyle.paragraphSpacing = 6

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

            case .paragraph(let text):
                let attr = formatInlineMarkdownString(text, font: bodyFont, color: bodyColor, paragraphStyle: bodyStyle)
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
                }
                currentText.append(attr)

            case .header(let level, let text):
                let hFont = NSFont.systemFont(ofSize: level <= 2 ? 14.5 : 13.5, weight: .bold)
                let attr = formatInlineMarkdownString(text, font: hFont, color: bodyColor, paragraphStyle: bodyStyle)
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
                }
                currentText.append(attr)

            case .bulletItem(let text):
                let bStyle = NSMutableParagraphStyle()
                bStyle.lineSpacing = 3
                bStyle.headIndent = 14
                bStyle.firstLineHeadIndent = 0
                let attr = formatInlineMarkdownString("• \(text)", font: bodyFont, color: bodyColor, paragraphStyle: bStyle)
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
                }
                currentText.append(attr)

            case .numberedItem(let number, let text):
                let nStyle = NSMutableParagraphStyle()
                nStyle.lineSpacing = 3
                nStyle.headIndent = 14
                nStyle.firstLineHeadIndent = 0
                let attr = formatInlineMarkdownString("\(number). \(text)", font: bodyFont, color: bodyColor, paragraphStyle: nStyle)
                if currentText.length > 0 {
                    currentText.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
                }
                currentText.append(attr)

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

    func measureUserContentViewsHeight(width: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (i, view) in userContentViews.enumerated() {
            if let tv = view as? AgentSelectableTextView {
                let h = measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: width)
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
            addSubview(thoughtView)
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
        for v in markdownViews { v.removeFromSuperview() }
        markdownViews.removeAll()
        markdownViewsByTextPart.removeAll()
        streamingRenderedContent = ""

        var sectionIndex = 0
        for part in message.orderedParts {
            guard case .text(let text) = part else { continue }
            let sections = compileSections(from: text, splitRichText: !nativeTextSelectionEnabled)
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

        for part in message.orderedParts {
            switch part {
            case .toolCall(let id):
                if let index = toolCallIDs.firstIndex(of: id) {
                    nextViews.append(toolCallViews[index])
                }
            case .text:
                if textPartIndex < markdownViewsByTextPart.count {
                    nextViews.append(contentsOf: markdownViewsByTextPart[textPartIndex])
                }
                textPartIndex += 1
            case .thought:
                if thoughtPartIndex < inlineThoughtViews.count {
                    nextViews.append(inlineThoughtViews[thoughtPartIndex])
                }
                thoughtPartIndex += 1
            }
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
            case .codeBlock(_, let code):
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
        let newLength = mutable.length
        if newLength > previousStreamedLength {
            let addedRange = NSRange(location: previousStreamedLength, length: newLength - previousStreamedLength)
            streamingFadeChunks.append(StreamingFadeChunk(range: addedRange, startTime: CACurrentMediaTime()))
            if streamingFadeTimer == nil {
                streamingFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                    self?.updateStreamingFadeAnimation()
                }
            }
        }
        previousStreamedLength = newLength

        let now = CACurrentMediaTime()
        let duration: TimeInterval = 0.16
        let baseColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        for chunk in streamingFadeChunks {
            guard chunk.range.location + chunk.range.length <= mutable.length else { continue }
            let progress = min(1.0, max(0.0, (now - chunk.startTime) / duration))
            let alpha = 0.15 + (0.85 * progress)
            mutable.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(alpha), range: chunk.range)
        }
        textView.textStorage?.setAttributedString(mutable)
        streamingRenderedContent = content
    }

    func updateStreamingFadeAnimation() {
        guard let textView = markdownViews.first as? AgentSelectableTextView,
              let textStorage = textView.textStorage,
              textStorage.length > 0 else {
            streamingFadeTimer?.invalidate()
            streamingFadeTimer = nil
            streamingFadeChunks.removeAll()
            return
        }

        let now = CACurrentMediaTime()
        let duration: TimeInterval = 0.16
        streamingFadeChunks.removeAll { now - $0.startTime >= duration }

        let baseColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        textStorage.beginEditing()
        if streamingFadeChunks.isEmpty {
            streamingFadeTimer?.invalidate()
            streamingFadeTimer = nil
            textStorage.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: textStorage.length))
        } else {
            for chunk in streamingFadeChunks {
                guard chunk.range.location + chunk.range.length <= textStorage.length else { continue }
                let progress = min(1.0, max(0.0, (now - chunk.startTime) / duration))
                let alpha = 0.15 + (0.85 * progress)
                textStorage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(alpha), range: chunk.range)
            }
        }
        textStorage.endEditing()
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
}
