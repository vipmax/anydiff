import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public struct AgentChatScrollRepresentable: NSViewRepresentable {
    public var messages: [AgentMessage]
    public var theme: Theme
    public var accentColor: Color
    public var toolcallColorMode: ToolcallColorMode
    public var scrollToBottomTrigger: Int
    public var onNearBottomChanged: (Bool) -> Void
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)?

    public init(
        messages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode = .full,
        scrollToBottomTrigger: Int,
        onNearBottomChanged: @escaping (Bool) -> Void = { _ in },
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRevert: ((AgentEditedFilesSummary) -> Void)? = nil,
        onRestore: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int) -> Void)? = nil,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.messages = messages
        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode
        self.scrollToBottomTrigger = scrollToBottomTrigger
        self.onNearBottomChanged = onNearBottomChanged
        self.onReview = onReview
        self.onRevert = onRevert
        self.onRestore = onRestore
        self.onPreviewImages = onPreviewImages
        self.onOpenURL = onOpenURL
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var lastMessageCount: Int = -1
        var lastLastMessageId: UUID? = nil
        var lastLastMessageContentCount: Int = -1
        var lastLastMessageStreaming: Bool = false
        var lastLastMessageToolCallsCount: Int = -1
        var lastThemeId: String = ""
        var lastAccentColor: Color = .accentColor
        var lastToolcallColorMode: ToolcallColorMode = .full
        var lastScrollToBottomTrigger: Int = -1

        func needsUpdate(
            messages: [AgentMessage],
            theme: Theme,
            accentColor: Color,
            toolcallColorMode: ToolcallColorMode,
            trigger: Int
        ) -> Bool {
            if theme.id != lastThemeId || accentColor != lastAccentColor || toolcallColorMode != lastToolcallColorMode || trigger != lastScrollToBottomTrigger {
                record(messages: messages, theme: theme, accentColor: accentColor, toolcallColorMode: toolcallColorMode, trigger: trigger)
                return true
            }
            if messages.count != lastMessageCount {
                record(messages: messages, theme: theme, accentColor: accentColor, toolcallColorMode: toolcallColorMode, trigger: trigger)
                return true
            }
            if let last = messages.last {
                if last.id != lastLastMessageId ||
                   last.content.count != lastLastMessageContentCount ||
                   last.isStreaming != lastLastMessageStreaming ||
                   last.toolCalls.count != lastLastMessageToolCallsCount {
                    record(messages: messages, theme: theme, accentColor: accentColor, toolcallColorMode: toolcallColorMode, trigger: trigger)
                    return true
                }
            }
            return false
        }

        func record(
            messages: [AgentMessage],
            theme: Theme,
            accentColor: Color,
            toolcallColorMode: ToolcallColorMode,
            trigger: Int
        ) {
            lastMessageCount = messages.count
            lastLastMessageId = messages.last?.id
            lastLastMessageContentCount = messages.last?.content.count ?? -1
            lastLastMessageStreaming = messages.last?.isStreaming ?? false
            lastLastMessageToolCallsCount = messages.last?.toolCalls.count ?? -1
            lastThemeId = theme.id
            lastAccentColor = accentColor
            lastToolcallColorMode = toolcallColorMode
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
        context.coordinator.record(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            toolcallColorMode: toolcallColorMode,
            trigger: scrollToBottomTrigger
        )
        scrollView.update(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            toolcallColorMode: toolcallColorMode,
            animated: false,
            scrollToBottomTrigger: scrollToBottomTrigger
        )
        return scrollView
    }

    public func updateNSView(_ scrollView: AgentChatScrollView, context: Context) {
        scrollView.onNearBottomChanged = onNearBottomChanged
        scrollView.onReview = onReview
        scrollView.onRevert = onRevert
        scrollView.onRestore = onRestore
        scrollView.onPreviewImages = onPreviewImages
        scrollView.onOpenURL = onOpenURL

        // If SwiftUI called updateNSView purely because of an unrelated UI state change
        // (like isChatNearBottom button appearing or parent view re-evaluating during scroll),
        // skip the update so scrolling is 100% free of layout passes and main-thread work.
        guard context.coordinator.needsUpdate(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            toolcallColorMode: toolcallColorMode,
            trigger: scrollToBottomTrigger
        ) else {
            return
        }

        scrollView.update(
            messages: messages,
            theme: theme,
            accentColor: accentColor,
            toolcallColorMode: toolcallColorMode,
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
    private var pendingToolcallColorMode: ToolcallColorMode = .full
    private var pendingAnimated = false
    private var pendingScrollToBottomTrigger = 0
    private var pendingBottomInset: CGFloat = 0
    private var streamingUpdateWorkItem: DispatchWorkItem?
    private var resizeLayoutWorkItem: DispatchWorkItem?
    private var pendingResizeWidth: CGFloat?
    private var isResizing = false
    fileprivate var followsBottom = true
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
        streamingUpdateWorkItem?.cancel()
        resizeLayoutWorkItem?.cancel()
    }

    public func update(
        messages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode = .full,
        animated: Bool,
        scrollToBottomTrigger: Int = 0,
        bottomInset: CGFloat = 0
    ) {
        pendingMessages = messages
        pendingTheme = theme
        pendingAccentColor = accentColor
        pendingToolcallColorMode = toolcallColorMode
        pendingAnimated = animated
        pendingScrollToBottomTrigger = scrollToBottomTrigger
        pendingBottomInset = bottomInset

        if messages.last?.isStreaming == true {
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
        documentViewCustom.updateMessages(
            messages,
            theme: theme,
            accentColor: pendingAccentColor,
            toolcallColorMode: pendingToolcallColorMode,
            in: self,
            animated: pendingAnimated
        )

        if shouldScrollToBottom {
            let isStreaming = messages.last?.isStreaming == true
            self.scrollToBottom(animated: !isStreaming)
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
            pendingResizeWidth = width
            resizeLayoutWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let width = self.pendingResizeWidth else { return }
                self.pendingResizeWidth = nil
                self.documentViewCustom.layoutContent(for: width)
                if self.followsBottom {
                    self.scrollToBottom(animated: false)
                }
            }
            resizeLayoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
        } else if heightChanged {
            if followsBottom {
                scrollToBottom(animated: false)
            } else {
                let docHeight = documentViewCustom.bounds.height
                let clipHeight = contentView.bounds.height
                if docHeight <= clipHeight, contentView.bounds.origin.y != 0 {
                    contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0))
                    reflectScrolledClipView(contentView)
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
            documentViewCustom.layoutContent(for: width)
            if followsBottom {
                scrollToBottom(animated: false)
            }
        }
    }

    public func scrollToBottom(animated: Bool = true, duration: TimeInterval = 0.2) {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        guard docHeight > clipBounds.height else {
            if clipBounds.origin.y != 0 {
                let targetPoint = NSPoint(x: clipBounds.origin.x, y: 0)
                if animated {
                    contentView.animator().setBoundsOrigin(targetPoint)
                } else {
                    contentView.scroll(to: targetPoint)
                    reflectScrolledClipView(contentView)
                }
            }
            return
        }
        let targetY = max(0, docHeight - clipBounds.height)
        let targetPoint = NSPoint(x: clipBounds.origin.x, y: targetY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(targetPoint)
            }
        } else {
            contentView.layer?.removeAllAnimations()
            contentView.scroll(to: targetPoint)
            reflectScrolledClipView(contentView)
        }
    }

    public override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        guard !isResizing else { return }
        notifyNearBottomChanged()
    }

    /// Expanding a tool call is an explicit inspection action. Do not let a
    /// later message update pull the user back to the bottom while they read it.
    public func stopFollowingBottom() {
        followsBottom = false
        contentView.layer?.removeAllAnimations()
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
        followsBottom = nearBottom
        guard lastNearBottom != nearBottom else { return }
        lastNearBottom = nearBottom
        onNearBottomChanged?(nearBottom)
    }
}

public final class AgentChatDocumentView: NSView {
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public struct CellEntry {
        public let id: UUID
        public let cell: AgentMessageCell
        public var frame: NSRect
    }

    private var cells: [UUID: AgentMessageCell] = [:]
    private var orderedCells: [CellEntry] = []
    private var messagesByID: [UUID: AgentMessage] = [:]
    private var theme: Theme = .zedDark
    private var accentColor: Color = .accentColor
    private var toolcallColorMode: ToolcallColorMode = .full
    private var bottomInset: CGFloat = 0
    fileprivate private(set) var lastLayoutWidth: CGFloat = 0
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)? = nil

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
    }

    fileprivate func setBottomInset(_ inset: CGFloat) {
        let newInset = ceil(max(0, inset))
        guard abs(newInset - bottomInset) >= 1.0 else { return }

        bottomInset = newInset
        layoutContent(for: max(100, lastLayoutWidth))
    }

    fileprivate func updateMessages(
        _ newMessages: [AgentMessage],
        theme: Theme,
        accentColor: Color = .accentColor,
        toolcallColorMode: ToolcallColorMode,
        in scrollView: AgentChatScrollView,
        animated: Bool
    ) {
        let newIds = newMessages.map(\.id)
        let oldIds = orderedCells.map(\.id)
        let themeChanged = theme.id != self.theme.id
        let accentChanged = accentColor != self.accentColor
        let displayModeChanged = toolcallColorMode != self.toolcallColorMode
        let messagesChanged = newIds != oldIds || newMessages.contains { message in
            messagesByID[message.id] != message
        }
        guard messagesChanged || themeChanged || accentChanged || displayModeChanged else {
            let width = max(100, scrollView.contentView.bounds.width)
            if abs(width - lastLayoutWidth) > 0.5 {
                layoutContent(for: width)
            }
            return
        }

        self.theme = theme
        self.accentColor = accentColor
        self.toolcallColorMode = toolcallColorMode

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
                if themeChanged || accentChanged || displayModeChanged || messagesByID[message.id] != message {
                    cell.configure(
                        message: message,
                        theme: theme,
                        accentColor: accentColor,
                        toolcallColorMode: toolcallColorMode
                    )
                }
            } else {
                cell = AgentMessageCell(
                    message: message,
                    theme: theme,
                    accentColor: accentColor,
                    toolcallColorMode: toolcallColorMode,
                    nativeTextSelectionEnabled: true
                )
                if message.role == .user {
                    cell.prepareUserMessageAppearance()
                }
                cell.onReview = onReview
                cell.onRevert = onRevert
                cell.onRestore = onRestore
                cell.onPreviewImages = { [weak self] imgs, idx in
                    self?.onPreviewImages?(imgs, idx)
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
                cell.onToggleUserExpand = { [weak self] in
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

        layoutContent(for: max(100, scrollView.contentView.bounds.width))
        for item in orderedCells {
            item.cell.animatePendingAppearances(animated: animated)
        }
        if scrollView.followsBottom || oldIds.isEmpty {
            scrollView.scrollToBottom(animated: animated && newMessages.last?.isStreaming != true)
        }
    }

    fileprivate func layoutContent(for width: CGFloat) {
        let contentWidth = max(100, width)
        lastLayoutWidth = contentWidth

        var currentY: CGFloat = 8

        for i in 0..<orderedCells.count {
            let cell = orderedCells[i].cell
            let height = cell.layout(for: contentWidth)
            let cellFrame = NSRect(x: 0, y: currentY, width: contentWidth, height: height)
            orderedCells[i].frame = cellFrame
            if cell.superview == nil {
                cell.frame = cellFrame
                addSubview(cell)
            } else if cell.frame != cellFrame {
                cell.frame = cellFrame
            }
            if cell.isHidden {
                cell.isHidden = false
            }
            currentY += height + 10
        }

        let contentHeight = currentY + 6 + bottomInset
        let documentHeight = contentHeight
        setFrameSize(NSSize(width: contentWidth, height: documentHeight))
    }

    public func updateVisibleCells(in clipView: NSClipView?) {
        // No-op: AppKit's layer-backed clip view handles GPU-level clipping smoothly.
        // Mutating isHidden during scroll invalidates tracking areas and triggers
        // synchronous main-thread transaction stalls.
    }
}

public final class FlippedClipView: NSClipView {
    public override var isFlipped: Bool { true }

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
