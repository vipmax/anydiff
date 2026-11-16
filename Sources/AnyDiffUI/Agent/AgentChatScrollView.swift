import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public struct AgentChatScrollRepresentable: NSViewRepresentable {
    public var messages: [AgentMessage]
    public var theme: Theme
    public var accentColor: Color
    public var agentIcon: String
    public var agentId: String
    public var toolcallColorMode: ToolcallColorMode
    public var isCompactMode: Bool
    public var scrollToBottomTrigger: Int
    public var onNearBottomChanged: (Bool) -> Void
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public var onDeleteQueuedMessage: ((UUID) -> Void)?
    public var onEditQueuedMessage: ((UUID) -> Void)?
    public var onUpdateQueuedMessage: ((UUID, String) -> Void)?
    public var onMoveQueuedMessage: ((UUID, QueueMoveDirection) -> Void)?
    public var inputView: AnyView?
    public var inputContentHeight: CGFloat = 0

    public init(
        messages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        agentIcon: String = "sparkles",
        agentId: String = "default",
        toolcallColorMode: ToolcallColorMode = .full,
        isCompactMode: Bool = false,
        scrollToBottomTrigger: Int,
        onNearBottomChanged: @escaping (Bool) -> Void = { _ in },
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRevert: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRestore: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int) -> Void)? = nil,
        onOpenURL: ((URL) -> Void)? = nil,
        onDeleteQueuedMessage: ((UUID) -> Void)? = nil,
        onEditQueuedMessage: ((UUID) -> Void)? = nil,
        onUpdateQueuedMessage: ((UUID, String) -> Void)? = nil,
        onMoveQueuedMessage: ((UUID, QueueMoveDirection) -> Void)? = nil,
        inputView: AnyView? = nil,
        inputContentHeight: CGFloat = 0
    ) {
        self.messages = messages
        self.theme = theme
        self.accentColor = accentColor
        self.agentIcon = agentIcon
        self.agentId = agentId
        self.toolcallColorMode = toolcallColorMode
        self.isCompactMode = isCompactMode
        self.scrollToBottomTrigger = scrollToBottomTrigger
        self.onNearBottomChanged = onNearBottomChanged
        self.onReview = onReview
        self.onRevert = onRevert
        self.onRestore = onRestore
        self.onPreviewImages = onPreviewImages
        self.onOpenURL = onOpenURL
        self.onDeleteQueuedMessage = onDeleteQueuedMessage
        self.onEditQueuedMessage = onEditQueuedMessage
        self.onUpdateQueuedMessage = onUpdateQueuedMessage
        self.onMoveQueuedMessage = onMoveQueuedMessage
        self.inputView = inputView
        self.inputContentHeight = inputContentHeight
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        struct MessageItemKey: Equatable {
            let id: UUID
            let contentCount: Int
            let isStreaming: Bool
            let toolCallsCount: Int
            let queuePosition: Int?
            let queueTotal: Int?
        }
        var lastItemKeys: [MessageItemKey] = []
        var lastMessageCount: Int = -1
        var lastLastMessageId: UUID? = nil
        var lastLastMessageContentCount: Int = -1
        var lastLastMessageStreaming: Bool = false
        var lastLastMessageToolCallsCount: Int = -1
        var lastThemeId: String = ""
        var lastAccentColor: Color = .accentColor
        var lastAgentIcon: String = "sparkles"
        var lastAgentId: String = "default"
        var lastToolcallColorMode: ToolcallColorMode = .full
        var lastIsCompactMode: Bool = false
        var lastScrollToBottomTrigger: Int = -1

        func hasStyleOrTriggerChange(
            theme: Theme,
            accentColor: Color,
            agentIcon: String,
            agentId: String = "default",
            toolcallColorMode: ToolcallColorMode,
            isCompactMode: Bool,
            trigger: Int
        ) -> Bool {
            theme.id != lastThemeId ||
                accentColor != lastAccentColor ||
                agentIcon != lastAgentIcon ||
                agentId != lastAgentId ||
                toolcallColorMode != lastToolcallColorMode ||
                isCompactMode != lastIsCompactMode ||
                trigger != lastScrollToBottomTrigger
        }

        func needsUpdate(
            messages: [AgentMessage],
            theme: Theme,
            accentColor: Color,
            agentIcon: String,
            agentId: String = "default",
            toolcallColorMode: ToolcallColorMode,
            isCompactMode: Bool,
            trigger: Int
        ) -> Bool {
            if hasStyleOrTriggerChange(
                theme: theme,
                accentColor: accentColor,
                agentIcon: agentIcon,
                agentId: agentId,
                toolcallColorMode: toolcallColorMode,
                isCompactMode: isCompactMode,
                trigger: trigger
            ) {
                record(messages: messages, theme: theme, accentColor: accentColor, agentIcon: agentIcon, agentId: agentId, toolcallColorMode: toolcallColorMode, isCompactMode: isCompactMode, trigger: trigger)
                return true
            }
            let currentItemKeys = messages.map {
                MessageItemKey(
                    id: $0.id,
                    contentCount: $0.content.count,
                    isStreaming: $0.isStreaming,
                    toolCallsCount: $0.toolCalls.count,
                    queuePosition: $0.queuePosition,
                    queueTotal: $0.queueTotal
                )
            }
            if currentItemKeys != lastItemKeys {
                record(messages: messages, theme: theme, accentColor: accentColor, agentIcon: agentIcon, agentId: agentId, toolcallColorMode: toolcallColorMode, isCompactMode: isCompactMode, trigger: trigger)
                return true
            }
            return false
        }

        func record(
            messages: [AgentMessage],
            theme: Theme,
            accentColor: Color,
            agentIcon: String,
            agentId: String = "default",
            toolcallColorMode: ToolcallColorMode,
            isCompactMode: Bool,
            trigger: Int
        ) {
            lastItemKeys = messages.map {
                MessageItemKey(
                    id: $0.id,
                    contentCount: $0.content.count,
                    isStreaming: $0.isStreaming,
                    toolCallsCount: $0.toolCalls.count,
                    queuePosition: $0.queuePosition,
                    queueTotal: $0.queueTotal
                )
            }
            lastMessageCount = messages.count
            lastAgentId = agentId
            lastLastMessageId = messages.last?.id
            lastLastMessageContentCount = messages.last?.content.count ?? -1
            lastLastMessageStreaming = messages.last?.isStreaming ?? false
            lastLastMessageToolCallsCount = messages.last?.toolCalls.count ?? -1
            lastThemeId = theme.id
            lastAccentColor = accentColor
            lastAgentIcon = agentIcon
            lastToolcallColorMode = toolcallColorMode
            lastIsCompactMode = isCompactMode
            lastScrollToBottomTrigger = trigger
        }
    }

    public func makeNSView(context: Context) -> AgentChatScrollView {
        let scrollView = AgentChatScrollView()
        scrollView.onNearBottomChanged = onNearBottomChanged
        scrollView.onReview = onReview
        scrollView.onRevert = onRevert
        scrollView.onRestore = onRestore
        scrollView.onPreviewImages = onPreviewImages
        scrollView.onOpenURL = onOpenURL
        scrollView.onDeleteQueuedMessage = onDeleteQueuedMessage
        scrollView.onEditQueuedMessage = onEditQueuedMessage
        scrollView.onUpdateQueuedMessage = onUpdateQueuedMessage
        scrollView.onMoveQueuedMessage = onMoveQueuedMessage
        scrollView.setInputView(inputView, inputHeight: inputContentHeight)
        scrollView.agentId = agentId
        context.coordinator.record(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            agentIcon: agentIcon,
            agentId: agentId,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            trigger: scrollToBottomTrigger
        )
        scrollView.update(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            agentIcon: agentIcon,
            agentId: agentId,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            animated: false,
            scrollToBottomTrigger: scrollToBottomTrigger
        )
        return scrollView
    }

    public func updateNSView(_ scrollView: AgentChatScrollView, context: Context) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.updateNSView(scrollView, context: context)
            }
            return
        }
        scrollView.onNearBottomChanged = onNearBottomChanged
        scrollView.onReview = onReview
        scrollView.onRevert = onRevert
        scrollView.onRestore = onRestore
        scrollView.onPreviewImages = onPreviewImages
        scrollView.onOpenURL = onOpenURL
        scrollView.onDeleteQueuedMessage = onDeleteQueuedMessage
        scrollView.onEditQueuedMessage = onEditQueuedMessage
        scrollView.onUpdateQueuedMessage = onUpdateQueuedMessage
        scrollView.onMoveQueuedMessage = onMoveQueuedMessage
        scrollView.agentId = agentId
        // If SwiftUI called updateNSView purely because of an unrelated UI state change
        // (like isChatNearBottom button appearing or parent view re-evaluating during scroll),
        // skip the update so scrolling is 100% free of layout passes and main-thread work.
        let styleOrTriggerChanged = context.coordinator.hasStyleOrTriggerChange(
            theme: theme,
            accentColor: accentColor,
            agentIcon: agentIcon,
            agentId: agentId,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            trigger: scrollToBottomTrigger
        )
        guard context.coordinator.needsUpdate(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            agentIcon: agentIcon,
            agentId: agentId,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            trigger: scrollToBottomTrigger
        ) else {
            if scrollView.needsInputHeightUpdate(inputContentHeight) {
                scrollView.setInputView(inputView, inputHeight: inputContentHeight)
            }
            return
        }

        let isStreaming = messages.last(where: { !$0.isQueued })?.isStreaming == true
        if !isStreaming || styleOrTriggerChanged || scrollView.needsInputHeightUpdate(inputContentHeight) {
            scrollView.setInputView(inputView, inputHeight: inputContentHeight)
        }

        scrollView.update(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            agentIcon: agentIcon,
            agentId: agentId,
            toolcallColorMode: toolcallColorMode,
            isCompactMode: isCompactMode,
            animated: true,
            scrollToBottomTrigger: scrollToBottomTrigger
        )
    }
}

public final class AgentChatScrollView: NSScrollView {
    private let documentViewCustom = AgentChatDocumentView()
    private var lastScrollToBottomTrigger = 0
    private var lastNearBottom: Bool?
    private var pendingMessages: [AgentMessage]?
    private var pendingTheme: Theme?
    private var pendingAccentColor: Color = .accentColor
    public var agentId: String = "default"
    private var pendingAgentIcon: String = "sparkles"
    private var pendingAgentId: String = "default"
    private var pendingToolcallColorMode: ToolcallColorMode = .full
    private var pendingIsCompactMode: Bool = false
    private var pendingAnimated = false
    private var pendingScrollToBottomTrigger = 0
    private var pendingBottomInset: CGFloat = 0
    private var streamingUpdateWorkItem: DispatchWorkItem?
    private var resizeLayoutWorkItem: DispatchWorkItem?
    private var pendingResizeWidth: CGFloat?
    private var isResizing = false
    fileprivate var isUpdatingLayout = false
    fileprivate var followsBottom = true
    fileprivate var lastObservedClipOriginY: CGFloat = 0
    fileprivate var isUserLiveScrolling = false
    private var bottomOverscrollFloorY: CGFloat?
    public var onNearBottomChanged: ((Bool) -> Void)?
    public var onReview: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            documentViewCustom.onReview = onReview
        }
    }
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            documentViewCustom.onRevert = onRevert
        }
    }
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            documentViewCustom.onRestore = onRestore
        }
    }
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)? {
        didSet {
            documentViewCustom.onPreviewImages = onPreviewImages
        }
    }
    public var onOpenURL: ((URL) -> Void)? {
        didSet {
            documentViewCustom.onOpenURL = onOpenURL
        }
    }
    public var onDeleteQueuedMessage: ((UUID) -> Void)? {
        didSet {
            documentViewCustom.onDeleteQueuedMessage = onDeleteQueuedMessage
        }
    }
    public var onEditQueuedMessage: ((UUID) -> Void)? {
        didSet {
            documentViewCustom.onEditQueuedMessage = onEditQueuedMessage
        }
    }
    public var onUpdateQueuedMessage: ((UUID, String) -> Void)? {
        didSet {
            documentViewCustom.onUpdateQueuedMessage = onUpdateQueuedMessage
        }
    }
    public var onMoveQueuedMessage: ((UUID, QueueMoveDirection) -> Void)? {
        didSet {
            documentViewCustom.onMoveQueuedMessage = onMoveQueuedMessage
        }
    }

    public func setInputView(_ view: AnyView?, inputHeight: CGFloat = 0) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setInputView(view, inputHeight: inputHeight)
            }
            return
        }
        documentViewCustom.setInputView(view, inputHeight: inputHeight)
    }

    public func needsInputHeightUpdate(_ inputHeight: CGFloat) -> Bool {
        documentViewCustom.needsInputHeightUpdate(inputHeight)
    }

    public override var isOpaque: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = NSColor(cgColor: Theme.zedDark.background.cgColor) ?? .windowBackgroundColor
        borderType = .noBorder
        scrollsDynamically = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        clipView.postsBoundsChangedNotifications = false
        self.contentView = clipView

        documentView = documentViewCustom

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: self
        )

        registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL
        ])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if ImageAttachmentHelpers.hasImages(in: pb) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let images = ImageAttachmentHelpers.extractImages(from: pb)
        if !images.isEmpty {
            NotificationCenter.default.post(
                name: Notification.Name("anyDiffAttachImages"),
                object: nil,
                userInfo: ["images": images]
            )
            return true
        }
        return false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        streamingUpdateWorkItem?.cancel()
        resizeLayoutWorkItem?.cancel()
    }

    @objc private func handleWillStartLiveScroll(_ notification: Notification) {
        isUserLiveScrolling = true
        lastObservedClipOriginY = contentView.bounds.origin.y
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        let maxScrollY = max(0, docHeight - clipBounds.height)
        let distFromBottom = docHeight - clipBounds.maxY
        if followsBottom || distFromBottom <= 2.0 {
            bottomOverscrollFloorY = maxScrollY
        } else {
            bottomOverscrollFloorY = nil
        }
        print(String(format: "[ScrollLog] LIVE_SCROLL_START originY=%.1f docH=%.1f clipH=%.1f distFromBottom=%.1f overscroll=%.1f followsBottom=%@",
                     clipBounds.origin.y, docHeight, clipBounds.height, distFromBottom, currentBottomOverscroll,
                     followsBottom ? "true" : "false"))
        fflush(stdout)
    }

    @objc private func handleDidEndLiveScroll(_ notification: Notification) {
        isUserLiveScrolling = false
        bottomOverscrollFloorY = nil
        lastObservedClipOriginY = contentView.bounds.origin.y
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        let distFromBottom = docHeight - clipBounds.maxY
        if docHeight <= clipBounds.height || distFromBottom <= 2.0 {
            followsBottom = true
        }
        if followsBottom && distFromBottom > 0.5 {
            scrollToBottom(animated: false)
        }
        notifyNearBottomChanged()
        let finalBounds = contentView.bounds
        let finalDist = docHeight - finalBounds.maxY
        print(String(format: "[ScrollLog] LIVE_SCROLL_END   originY=%.1f docH=%.1f clipH=%.1f distFromBottom=%.1f overscroll=%.1f followsBottom=%@",
                     finalBounds.origin.y, docHeight, finalBounds.height, finalDist, currentBottomOverscroll,
                     followsBottom ? "true" : "false"))
        fflush(stdout)
    }

    fileprivate var currentBottomOverscroll: CGFloat {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        let maxScrollY = max(0, docHeight - clipBounds.height)
        return max(0, clipBounds.origin.y - maxScrollY)
    }

    fileprivate var currentTopOverscroll: CGFloat {
        min(0, contentView.bounds.origin.y)
    }

    public func update(
        messages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        agentIcon: String = "sparkles",
        agentId: String = "default",
        toolcallColorMode: ToolcallColorMode = .full,
        isCompactMode: Bool = false,
        animated: Bool,
        scrollToBottomTrigger: Int = 0,
        bottomInset: CGFloat = 0
    ) {
        pendingMessages = messages
        pendingTheme = theme
        pendingAccentColor = accentColor
        pendingAgentIcon = agentIcon
        pendingAgentId = agentId
        pendingToolcallColorMode = toolcallColorMode
        pendingIsCompactMode = isCompactMode
        pendingAnimated = animated
        pendingScrollToBottomTrigger = scrollToBottomTrigger
        pendingBottomInset = bottomInset

        let visibleCount = messages.filter { $0.hasVisibleContent }.count
        let isCountChanged = visibleCount != documentViewCustom.currentMessageCount

        if messages.last(where: { !$0.isQueued })?.isStreaming == true && !isCountChanged {
            guard streamingUpdateWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.streamingUpdateWorkItem = nil
                self.flushPendingUpdate()
            }
            streamingUpdateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
            return
        }

        streamingUpdateWorkItem?.cancel()
        streamingUpdateWorkItem = nil
        flushPendingUpdate()
    }

    private func flushPendingUpdate() {
        guard let messages = pendingMessages, let theme = pendingTheme else { return }
        pendingMessages = nil
        pendingTheme = nil

        let shouldScrollToBottom = pendingScrollToBottomTrigger != lastScrollToBottomTrigger
        lastScrollToBottomTrigger = pendingScrollToBottomTrigger
        if shouldScrollToBottom {
            followsBottom = true
        }
        let themeBgColor = NSColor(cgColor: theme.background.cgColor) ?? .windowBackgroundColor
        if backgroundColor != themeBgColor {
            backgroundColor = themeBgColor
        }
        documentViewCustom.setBottomInset(pendingBottomInset)
        let didScrollInUpdate = documentViewCustom.updateMessages(
            messages,
            theme: theme,
            accentColor: pendingAccentColor,
            agentIcon: pendingAgentIcon,
            agentId: pendingAgentId,
            toolcallColorMode: pendingToolcallColorMode,
            isCompactMode: pendingIsCompactMode,
            in: self,
            animated: pendingAnimated,
            forceScrollToBottom: shouldScrollToBottom
        )

        if shouldScrollToBottom && !didScrollInUpdate {
            let isStreaming = messages.last(where: { !$0.isQueued })?.isStreaming == true
            self.scrollToBottom(
                animated: !isStreaming,
                preservingBottomOverscroll: currentBottomOverscroll,
                preservingTopOverscroll: currentTopOverscroll
            )
            self.notifyNearBottomChanged()
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        isResizing = true
        defer {
            isResizing = false
            notifyNearBottomChanged()
        }
        let oldHeight = contentView.bounds.height
        super.setFrameSize(newSize)
        let width = contentView.bounds.width
        let heightChanged = abs(contentView.bounds.height - oldHeight) > 0.5
        let widthChanged = abs(width - documentViewCustom.lastLayoutWidth) > 0.5

        guard width > 50 else { return }

        if widthChanged {
            if inLiveResize {
                pendingResizeWidth = width
                resizeLayoutWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, let width = self.pendingResizeWidth else { return }
                    self.pendingResizeWidth = nil
                    let overscroll = self.currentBottomOverscroll
                    self.documentViewCustom.layoutContent(for: width)
                    if self.followsBottom {
                        self.scrollToBottom(animated: false, preservingBottomOverscroll: overscroll)
                    }
                }
                resizeLayoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
            } else {
                resizeLayoutWorkItem?.cancel()
                resizeLayoutWorkItem = nil
                pendingResizeWidth = nil
                let overscroll = currentBottomOverscroll
                documentViewCustom.layoutContent(for: width)
                if followsBottom {
                    scrollToBottom(animated: false, preservingBottomOverscroll: overscroll)
                }
            }
        } else if heightChanged {
            let overscroll = currentBottomOverscroll
            documentViewCustom.layoutContent(for: width)
            if followsBottom {
                scrollToBottom(animated: false, preservingBottomOverscroll: overscroll)
            } else {
                let docHeight = documentViewCustom.bounds.height
                let clipHeight = contentView.bounds.height
                if docHeight <= clipHeight, contentView.bounds.origin.y != 0 {
                    performProgrammaticScroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0), allowOverscroll: false)
                }
            }
        }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizeLayoutWorkItem?.cancel()
        resizeLayoutWorkItem = nil
        let width = contentView.bounds.width
        if width > 50, abs(width - documentViewCustom.lastLayoutWidth) > 0.5 || pendingResizeWidth != nil {
            pendingResizeWidth = nil
            let overscroll = currentBottomOverscroll
            documentViewCustom.layoutContent(for: width)
            if followsBottom {
                scrollToBottom(animated: false, preservingBottomOverscroll: overscroll)
            }
        }
    }

    public func scrollToBottom(
        animated: Bool = true,
        duration: TimeInterval = 0.2,
        preservingBottomOverscroll: CGFloat = 0,
        preservingTopOverscroll: CGFloat = 0
    ) {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        let baseTargetY = max(0, docHeight - clipBounds.height)
        let shouldAnimate = animated && !isUserLiveScrolling && preservingBottomOverscroll <= 0 && preservingTopOverscroll >= 0
        let targetY: CGFloat
        if shouldAnimate {
            targetY = baseTargetY
        } else if preservingBottomOverscroll > 0 {
            targetY = baseTargetY + preservingBottomOverscroll
        } else if baseTargetY == 0 && preservingTopOverscroll < 0 {
            targetY = preservingTopOverscroll
        } else {
            targetY = baseTargetY
        }
        let effectiveOverscroll = targetY - baseTargetY
        let targetPoint = NSPoint(x: clipBounds.origin.x, y: targetY)
        if shouldAnimate {
            guard abs(clipBounds.origin.y - targetY) > 0.5 || abs(clipBounds.origin.x - targetPoint.x) > 0.5 else {
                lastObservedClipOriginY = clipBounds.origin.y
                return
            }
            print(String(format: "[ScrollLog] SCROLL_TO_BOTTOM(anim) fromY=%.1f -> targetY=%.1f docH=%.1f clipH=%.1f",
                         clipBounds.origin.y, targetY, docHeight, clipBounds.height))
            fflush(stdout)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(targetPoint)
            }
        } else {
            if contentView.layer?.animationKeys()?.isEmpty == false {
                contentView.layer?.removeAllAnimations()
            }
            guard abs(clipBounds.origin.y - targetY) > 0.5 || abs(clipBounds.origin.x - targetPoint.x) > 0.5 else {
                lastObservedClipOriginY = clipBounds.origin.y
                print(String(format: "[ScrollLog] SCROLL_TO_BOTTOM(skip) originY=%.1f == targetY=%.1f (base=%.1f overscroll=%.1f) docH=%.1f",
                             clipBounds.origin.y, targetY, baseTargetY, effectiveOverscroll, docHeight))
                fflush(stdout)
                return
            }
            print(String(format: "[ScrollLog] SCROLL_TO_BOTTOM(sync) fromY=%.1f -> targetY=%.1f (base=%.1f overscroll=%.1f) docH=%.1f clipH=%.1f",
                         clipBounds.origin.y, targetY, baseTargetY, effectiveOverscroll, docHeight, clipBounds.height))
            fflush(stdout)
            performProgrammaticScroll(to: targetPoint, allowOverscroll: abs(effectiveOverscroll) > 0)
        }
    }

    private func performProgrammaticScroll(to targetPoint: NSPoint, allowOverscroll: Bool) {
        let wasUpdating = isUpdatingLayout
        isUpdatingLayout = true
        let flippedClip = contentView as? FlippedClipView
        let prevAllow = flippedClip?.allowsVerticalOverscroll ?? false
        if allowOverscroll {
            flippedClip?.allowsVerticalOverscroll = true
            contentView.setBoundsOrigin(targetPoint)
        } else {
            contentView.scroll(to: targetPoint)
        }
        reflectScrolledClipView(contentView)
        flippedClip?.allowsVerticalOverscroll = prevAllow
        lastObservedClipOriginY = contentView.bounds.origin.y
        isUpdatingLayout = wasUpdating
    }

    public override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        documentViewCustom.updateVisibleCells(in: cView)
        documentViewCustom.updateStickyAvatars(clipTop: cView.bounds.minY)
        let newOriginY = cView.bounds.origin.y
        guard !isResizing && !isUpdatingLayout else {
            lastObservedClipOriginY = newOriginY
            return
        }
        let deltaY = newOriginY - lastObservedClipOriginY
        lastObservedClipOriginY = newOriginY

        let clipBounds = cView.bounds
        let docHeight = documentViewCustom.bounds.height
        let maxScrollY = max(0, docHeight - clipBounds.height)
        let prevFollows = followsBottom
        if docHeight <= clipBounds.height {
            followsBottom = true
            if isUserLiveScrolling {
                bottomOverscrollFloorY = 0
            }
        } else {
            let distFromBottom = docHeight - clipBounds.maxY
            if distFromBottom < -0.5 {
                followsBottom = true
                if isUserLiveScrolling && bottomOverscrollFloorY == nil {
                    bottomOverscrollFloorY = maxScrollY
                }
            } else if deltaY < -0.1 && distFromBottom > 0.5 {
                if isUserLiveScrolling, let floorY = bottomOverscrollFloorY, newOriginY >= floorY - 1.0 {
                    // Bottom rubber-band spring is relaxing back toward the pre-growth maxScrollY;
                    // the user has not scrolled above the floor where the bottom bounce started.
                    followsBottom = true
                } else {
                    bottomOverscrollFloorY = nil
                    followsBottom = false
                    if contentView.layer?.animationKeys()?.isEmpty == false {
                        contentView.layer?.removeAllAnimations()
                    }
                }
            } else if distFromBottom <= 2.0 && (deltaY >= -0.1 || distFromBottom < -0.5) {
                // User scrolled down to the bottom or is in bottom rubber-band overscroll.
                followsBottom = true
                if isUserLiveScrolling && bottomOverscrollFloorY == nil {
                    bottomOverscrollFloorY = maxScrollY
                }
            }
        }
        notifyNearBottomChanged()
        let distFromBottom = docHeight - clipBounds.maxY
        print(String(format: "[ScrollLog] REFLECT originY=%.1f deltaY=%+.1f docH=%.1f maxScrollY=%.1f distFromBottom=%.1f overscroll=%.1f follows=%@->%@ nearBottom=%@ live=%@",
                     newOriginY, deltaY, docHeight, max(0, docHeight - clipBounds.height), distFromBottom, currentBottomOverscroll,
                     prevFollows ? "T" : "F", followsBottom ? "T" : "F",
                     (lastNearBottom == true) ? "T" : "F",
                     isUserLiveScrolling ? "T" : "F"))
        fflush(stdout)
    }

    fileprivate func refreshNearBottomState() {
        notifyNearBottomChanged()
    }

    /// Expanding a tool call is an explicit inspection action. Do not let a
    /// later message update pull the user back to the bottom while they read it.
    public func stopFollowingBottom() {
        followsBottom = false
        contentView.layer?.removeAllAnimations()
    }

    @discardableResult
    public func clearAllTextSelections() -> Bool {
        documentViewCustom.clearAllTextSelections()
    }

    public var isNearBottom: Bool {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        guard docHeight > clipBounds.height else { return true }
        let distFromBottom = docHeight - clipBounds.maxY
        if lastNearBottom == true {
            return distFromBottom <= 70
        } else {
            return distFromBottom <= 35
        }
    }

    private func notifyNearBottomChanged() {
        let nearBottom = isNearBottom
        guard lastNearBottom != nearBottom else { return }
        lastNearBottom = nearBottom
        onNearBottomChanged?(nearBottom)
    }
}

public final class AgentChatDocumentView: NSView {
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    // Prevent AppKit's NSISEngine (Auto Layout) from propagating into the manually
    // laid-out chat document subtree. Without this, every addSubview / removeFromSuperview
    // and NSHostingView update recursively traverses all subviews with _setLayoutEngine:.
    @objc(_setLayoutEngine:)
    public func _setLayoutEngine(_ engine: AnyObject?) {}

    public struct CellEntry {
        public let id: UUID
        public let cell: AgentMessageCell
        public var frame: NSRect
    }

    private var cells: [UUID: AgentMessageCell] = [:]
    private var orderedCells: [CellEntry] = []
    fileprivate var currentMessageCount: Int { orderedCells.count }
    private var messagesByID: [UUID: AgentMessage] = [:]
    private var theme: Theme = .zedDark
    private var accentColor: Color = .accentColor
    private var agentIcon: String = "sparkles"
    private var agentId: String = "default"
    private var toolcallColorMode: ToolcallColorMode = .full
    private var isCompactMode: Bool = false
    private var bottomInset: CGFloat = 0
    fileprivate private(set) var lastLayoutWidth: CGFloat = 0
    private var lastCulledOriginY: CGFloat = -.greatestFiniteMagnitude
    private var lastCulledViewportHeight: CGFloat = -1
    private var lastVisibleRange: Range<Int> = 0..<0
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)? = nil
    public var onDeleteQueuedMessage: ((UUID) -> Void)?
    public var onEditQueuedMessage: ((UUID) -> Void)?
    public var onUpdateQueuedMessage: ((UUID, String) -> Void)?
    public var onMoveQueuedMessage: ((UUID, QueueMoveDirection) -> Void)?
    private var inputHostingView: NSHostingView<AnyView>?
    private var lastInputHeight: CGFloat = -1

    public func needsInputHeightUpdate(_ inputHeight: CGFloat) -> Bool {
        inputHostingView == nil || abs(inputHeight - lastInputHeight) >= 1.0
    }

    public func setInputView(_ view: AnyView?, inputHeight: CGFloat = 0) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setInputView(view, inputHeight: inputHeight)
            }
            return
        }

        guard let view = view else {
            if inputHostingView != nil {
                inputHostingView?.removeFromSuperview()
                inputHostingView = nil
                relayoutAndPreserveBottomPin()
            }
            return
        }

        let heightChanged = abs(inputHeight - lastInputHeight) >= 1.0
        lastInputHeight = inputHeight

        if let existing = inputHostingView {
            existing.rootView = view
            if heightChanged {
                relayoutAndPreserveBottomPin()
            }
        } else {
            let hosting = AgentChatInputHostingView(rootView: view)
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = []
            }
            hosting.wantsLayer = true
            hosting.layer?.masksToBounds = false
            hosting.layerContentsRedrawPolicy = .onSetNeedsDisplay
            inputHostingView = hosting
            relayoutAndPreserveBottomPin()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let input = inputHostingView, point.y >= input.frame.minY {
            NotificationCenter.default.post(name: Notification.Name("anyDiffFocusAgentInput"), object: nil)
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAvatarDidChange),
            name: AgentAvatarProvider.avatarDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAvatarDidChange() {
        for entry in orderedCells {
            entry.cell.refreshAvatars()
        }
        relayoutAndPreserveBottomPin()
    }

    @discardableResult
    public func clearAllTextSelections() -> Bool {
        var didClear = false
        for (_, cell) in cells {
            for tv in cell.allSelectableTextViews() {
                if tv.selectedRange().length > 0 {
                    tv.setSelectedRange(NSRange(location: 0, length: 0))
                    didClear = true
                }
            }
            if clearSelectionsRecursively(in: cell) {
                didClear = true
            }
        }
        return didClear
    }

    private func clearSelectionsRecursively(in root: NSView) -> Bool {
        var didClear = false
        for subview in root.subviews {
            if let tv = subview as? AgentSelectableTextView {
                if tv.selectedRange().length > 0 {
                    tv.setSelectedRange(NSRange(location: 0, length: 0))
                    didClear = true
                }
            } else if let editor = subview as? MultiBufferEditorView {
                if editor.clearSelection() {
                    didClear = true
                }
            }
            if !subview.subviews.isEmpty {
                if clearSelectionsRecursively(in: subview) {
                    didClear = true
                }
            }
        }
        return didClear
    }

    fileprivate func setBottomInset(_ inset: CGFloat) {
        let newInset = ceil(max(0, inset))
        guard abs(newInset - bottomInset) >= 1.0 else { return }

        bottomInset = newInset
        relayoutAndPreserveBottomPin()
    }

    private func relayoutAndPreserveBottomPin() {
        let scrollView = enclosingScrollView as? AgentChatScrollView
        let clipWidth = scrollView?.contentView.bounds.width ?? 0
        let width = max(100, clipWidth > 50 ? clipWidth : lastLayoutWidth)
        let overscroll = scrollView?.currentBottomOverscroll ?? 0
        let topOverscroll = scrollView?.currentTopOverscroll ?? 0
        layoutContent(for: width)
        if let scrollView {
            if scrollView.followsBottom && (!scrollView.isUserLiveScrolling || overscroll > 1.5 || topOverscroll < -1.5) {
                scrollView.scrollToBottom(
                    animated: false,
                    preservingBottomOverscroll: overscroll,
                    preservingTopOverscroll: topOverscroll
                )
            }
            scrollView.refreshNearBottomState()
        }
    }

    @discardableResult
    fileprivate func updateMessages(
        _ incomingMessages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        agentIcon: String = "sparkles",
        agentId: String = "default",
        toolcallColorMode: ToolcallColorMode,
        isCompactMode: Bool,
        in scrollView: AgentChatScrollView,
        animated: Bool,
        forceScrollToBottom: Bool = false
    ) -> Bool {
        let updateStartTime = CACurrentMediaTime()
        let newMessages = incomingMessages.filter { $0.hasVisibleContent }
        let wasStreamingTurn = orderedCells.last(where: { !$0.cell.message.isQueued })?.cell.message.isStreaming == true
        let newIds = newMessages.map(\.id)
        let oldIds = orderedCells.map(\.id)
        let themeChanged = theme.id != self.theme.id
        let accentChanged = accentColor != self.accentColor
        let iconChanged = agentIcon != self.agentIcon
        let agentIdChanged = agentId != self.agentId
        let displayModeChanged = toolcallColorMode != self.toolcallColorMode || isCompactMode != self.isCompactMode
        let messagesChanged = newIds != oldIds || newMessages.contains { message in
            messagesByID[message.id] != message
        }
        guard messagesChanged || themeChanged || accentChanged || iconChanged || agentIdChanged || displayModeChanged else {
            let width = max(100, scrollView.contentView.bounds.width)
            if abs(width - lastLayoutWidth) > 0.5 {
                layoutContent(for: width)
            }
            return false
        }

        self.theme = theme
        self.accentColor = accentColor
        self.agentIcon = agentIcon
        self.agentId = agentId
        self.toolcallColorMode = toolcallColorMode
        self.isCompactMode = isCompactMode

        let newIDSet = Set(newIds)
        for (id, cell) in cells where !newIDSet.contains(id) {
            cell.removeFromSuperview()
            cells.removeValue(forKey: id)
        }

        var newOrdered: [CellEntry] = []
        for message in newMessages {
            let cell: AgentMessageCell
            if let existing = cells[message.id] {
                cell = existing
                cell.onReview = onReview
                cell.onRevert = onRevert
                cell.onRestore = onRestore
                cell.onPreviewImages = { [weak self] imgs, idx in
                    self?.onPreviewImages?(imgs, idx)
                }
                cell.onDeleteQueuedMessage = onDeleteQueuedMessage
                cell.onEditQueuedMessage = onEditQueuedMessage
                cell.onUpdateQueuedMessage = onUpdateQueuedMessage
                cell.onMoveQueuedMessage = onMoveQueuedMessage
                cell.onRequestLayout = { [weak self] in
                    self?.relayoutAndPreserveBottomPin()
                }
                if themeChanged || accentChanged || iconChanged || agentIdChanged || displayModeChanged || messagesByID[message.id] != message {
                    cell.configure(
                        message: message,
                        theme: theme,
                        accentColor: accentColor,
                        toolcallColorMode: toolcallColorMode,
                        isCompactMode: isCompactMode,
                        agentIconName: agentIcon,
                        agentId: agentId
                    )
                }
            } else {
                cell = AgentMessageCell(
                    message: message,
                    theme: theme,
                    accentColor: accentColor,
                    toolcallColorMode: toolcallColorMode,
                    isCompactMode: isCompactMode,
                    nativeTextSelectionEnabled: true,
                    agentIconName: agentIcon,
                    agentId: agentId
                )
                cell.onReview = onReview
                cell.onRevert = onRevert
                cell.onRestore = onRestore
                cell.onPreviewImages = { [weak self] imgs, idx in
                    self?.onPreviewImages?(imgs, idx)
                }
                cell.onDeleteQueuedMessage = onDeleteQueuedMessage
                cell.onEditQueuedMessage = onEditQueuedMessage
                cell.onUpdateQueuedMessage = onUpdateQueuedMessage
                cell.onMoveQueuedMessage = onMoveQueuedMessage
                cell.onRequestLayout = { [weak self] in
                    self?.relayoutAndPreserveBottomPin()
                }
                cell.onToggleThought = { [weak self] in
                    guard let self else { return }
                    scrollView.stopFollowingBottom()
                    self.layoutContent(for: max(100, scrollView.contentView.bounds.width))
                }
                cell.onToggleTool = { [weak self] in
                    guard let self else { return }
                    scrollView.stopFollowingBottom()
                    self.layoutContent(for: max(100, scrollView.contentView.bounds.width))
                }
                cells[message.id] = cell
            }

            newOrdered.append(CellEntry(id: message.id, cell: cell, frame: .zero))
        }

        orderedCells = newOrdered
        messagesByID = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })

        let effectiveWidth = scrollView.contentView.bounds.width > 50 ? scrollView.contentView.bounds.width : 400
        let preDocHeight = bounds.height
        let preOriginY = scrollView.contentView.bounds.origin.y
        let overscroll = scrollView.currentBottomOverscroll
        let topOverscroll = scrollView.currentTopOverscroll
        if oldIds.isEmpty {
            scrollView.followsBottom = true
        }
        layoutContent(for: max(100, effectiveWidth))
        let postDocHeight = bounds.height
        let isStreamingTurn = newMessages.last(where: { !$0.isQueued })?.isStreaming == true
        var didPerformScroll = false
        if scrollView.followsBottom && (!scrollView.isUserLiveScrolling || forceScrollToBottom || overscroll > 1.5 || topOverscroll < -1.5) {
            scrollView.scrollToBottom(
                animated: animated && !isStreamingTurn && !wasStreamingTurn,
                preservingBottomOverscroll: oldIds.isEmpty ? 0 : overscroll,
                preservingTopOverscroll: oldIds.isEmpty ? 0 : topOverscroll
            )
            didPerformScroll = true
        }
        scrollView.refreshNearBottomState()
        let postOriginY = scrollView.contentView.bounds.origin.y
        let lastCellFrame = orderedCells.last?.frame ?? .zero
        let inputFrame = inputHostingView?.frame ?? .zero
        let elapsedMs = (CACurrentMediaTime() - updateStartTime) * 1000.0
        print(String(format: "[ScrollLog] UPDATE_MESSAGES ms=%.2f originY=%.1f->%.1f (dY=%+.1f) docH=%.1f->%.1f (dH=%+.1f) overscroll=%.1f follows=%@ stream=%@ lastCellY=%.1f..%.1f inputY=%.1f..%.1f",
                     elapsedMs,
                     preOriginY, postOriginY, postOriginY - preOriginY,
                     preDocHeight, postDocHeight, postDocHeight - preDocHeight,
                     overscroll,
                     scrollView.followsBottom ? "T" : "F",
                     isStreamingTurn ? "T" : "F",
                     lastCellFrame.minY, lastCellFrame.maxY,
                     inputFrame.minY, inputFrame.maxY))
        fflush(stdout)
        for item in orderedCells {
            item.cell.animatePendingAppearances(animated: animated && item.cell.superview != nil && !item.cell.isHidden)
        }
        return didPerformScroll
    }

    fileprivate func layoutContent(for width: CGFloat) {
        let contentWidth = max(100, width)
        lastLayoutWidth = contentWidth

        var currentY: CGFloat = 10

        for i in 0..<orderedCells.count {
            let cell = orderedCells[i].cell
            let height = cell.layout(for: contentWidth)
            let cellFrame = NSRect(x: 0, y: currentY, width: contentWidth, height: height)
            orderedCells[i].frame = cellFrame
            if cell.superview != nil && cell.frame != cellFrame {
                cell.frame = cellFrame
            }
            if cell.isHidden {
                cell.isHidden = false
            }
            currentY += height + 14
        }

        if let inputView = inputHostingView, !orderedCells.isEmpty {
            let minInputHeight = max(AgentMessageCell.userAvatarSize + 8, 38)
            let resolvedInputHeight = max(minInputHeight, lastInputHeight > 0 ? ceil(lastInputHeight) : minInputHeight)
            let inputFrame = NSRect(x: 0, y: currentY, width: contentWidth, height: resolvedInputHeight)
            if inputView.frame != inputFrame {
                inputView.frame = inputFrame
            }
            if inputView.superview == nil {
                addSubview(inputView)
            }
            if inputView.isHidden {
                inputView.isHidden = false
            }
            currentY += resolvedInputHeight + 20
        } else {
            inputHostingView?.removeFromSuperview()
        }

        let minHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let contentHeight = currentY + 6 + bottomInset
        let documentHeight = max(minHeight, contentHeight)
        let scrollView = enclosingScrollView as? AgentChatScrollView
        let flippedClip = scrollView?.contentView as? FlippedClipView
        let preFrameOrigin = scrollView?.contentView.bounds.origin
        let hadOverscroll = (preFrameOrigin?.y ?? 0) < 0 || (scrollView?.currentBottomOverscroll ?? 0) > 0
        let wasUpdating = scrollView?.isUpdatingLayout ?? false
        let prevAllow = flippedClip?.allowsVerticalOverscroll ?? false
        scrollView?.isUpdatingLayout = true
        if hadOverscroll {
            flippedClip?.allowsVerticalOverscroll = true
        }
        if abs(bounds.width - contentWidth) > 0.5 || abs(bounds.height - documentHeight) > 0.5 {
            setFrameSize(NSSize(width: contentWidth, height: documentHeight))
            if let scrollView, let preFrameOrigin, hadOverscroll, scrollView.contentView.bounds.origin.y != preFrameOrigin.y {
                scrollView.contentView.setBoundsOrigin(preFrameOrigin)
            }
        }
        flippedClip?.allowsVerticalOverscroll = prevAllow
        scrollView?.isUpdatingLayout = wasUpdating
        updateVisibleCells(in: enclosingScrollView?.contentView, force: true)
    }

    /// Pins each visible message avatar to the top of the viewport while its message is scrolled.
    public func updateStickyAvatars(clipTop: CGFloat) {
        for i in lastVisibleRange where i < orderedCells.count {
            let cell = orderedCells[i].cell
            if cell.superview != nil {
                cell.updateStickyAvatar(viewportTopInDocument: clipTop)
            }
        }
    }

    public func updateVisibleCells(in clipView: NSClipView?, force: Bool = false) {
        guard !orderedCells.isEmpty else {
            lastVisibleRange = 0..<0
            return
        }
        let targetClip = clipView ?? enclosingScrollView?.contentView
        guard let targetClip else {
            for entry in orderedCells {
                let cell = entry.cell
                if cell.frame != entry.frame {
                    cell.frame = entry.frame
                }
                if cell.superview == nil {
                    addSubview(cell)
                }
                if cell.isHidden {
                    cell.isHidden = false
                }
                cell.animatePendingAppearances(animated: false)
            }
            lastVisibleRange = 0..<orderedCells.count
            return
        }

        let clipBounds = targetClip.bounds
        // Hysteresis: during continuous scroll, skip binary search & DOM checks unless
        // scroll origin moved by >= 96pt or viewport height changed.
        if !force,
           abs(clipBounds.origin.y - lastCulledOriginY) < 96,
           abs(clipBounds.height - lastCulledViewportHeight) < 1 {
            return
        }
        lastCulledOriginY = clipBounds.origin.y
        lastCulledViewportHeight = clipBounds.height

        let buffer: CGFloat = 800
        let minVisibleY = clipBounds.minY - buffer
        let maxVisibleY = clipBounds.maxY + buffer

        // Binary search for first cell with maxY >= minVisibleY
        var low = 0
        var high = orderedCells.count
        while low < high {
            let mid = (low + high) / 2
            if orderedCells[mid].frame.maxY < minVisibleY {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let firstVisibleIdx = low

        // Binary search for first cell with minY > maxVisibleY
        low = firstVisibleIdx
        high = orderedCells.count
        while low < high {
            let mid = (low + high) / 2
            if orderedCells[mid].frame.minY <= maxVisibleY {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let endVisibleIdx = low
        let newRange = firstVisibleIdx..<endVisibleIdx

        if !force && newRange == lastVisibleRange {
            return
        }
        lastVisibleRange = newRange

        if firstVisibleIdx > 0 {
            for i in 0..<firstVisibleIdx {
                let cell = orderedCells[i].cell
                if cell.superview != nil {
                    cell.removeFromSuperview()
                }
            }
        }

        if firstVisibleIdx < endVisibleIdx {
            for i in firstVisibleIdx..<endVisibleIdx {
                let entry = orderedCells[i]
                let cell = entry.cell
                if cell.frame != entry.frame {
                    cell.frame = entry.frame
                }
                if cell.superview == nil {
                    addSubview(cell)
                }
                if cell.isHidden {
                    cell.isHidden = false
                }
                cell.animatePendingAppearances(animated: false)
            }
        }

        if endVisibleIdx < orderedCells.count {
            for i in endVisibleIdx..<orderedCells.count {
                let cell = orderedCells[i].cell
                if cell.superview != nil {
                    cell.removeFromSuperview()
                }
            }
        }
    }
}

public final class FlippedClipView: NSClipView {
    public override var isFlipped: Bool { true }
    public var allowsVerticalOverscroll = false

    public override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        if allowsVerticalOverscroll {
            constrained.origin.y = proposedBounds.origin.y
        }
        return constrained
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
}

private final class AgentChatInputHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override func didChangeValue(forKey key: String) {
        if key == "safeAreaInsets" {
            return
        }
        super.didChangeValue(forKey: key)
    }
}
