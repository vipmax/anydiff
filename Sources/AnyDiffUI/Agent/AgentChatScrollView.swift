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
        onPreviewImages: (([AgentImageAttachment], Int) -> Void)? = nil
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

    public func makeNSView(context: Context) -> AgentNativeStandardChatScrollView {
        let scrollView = AgentNativeStandardChatScrollView()
        scrollView.onNearBottomChanged = onNearBottomChanged
        scrollView.onReview = onReview
        scrollView.onRevert = onRevert
        scrollView.onRestore = onRestore
        scrollView.onPreviewImages = onPreviewImages
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

    public func updateNSView(_ scrollView: AgentNativeStandardChatScrollView, context: Context) {
        scrollView.onNearBottomChanged = onNearBottomChanged
        scrollView.onReview = onReview
        scrollView.onRevert = onRevert
        scrollView.onRestore = onRestore
        scrollView.onPreviewImages = onPreviewImages

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

public final class AgentNativeChatScrollView: NSScrollView {
    private let documentViewCustom = AgentNativeChatDocumentView()
    private var boundsChangeObserver: NSObjectProtocol?
    private var lastScrollToBottomTrigger = 0
    private var lastNearBottom: Bool?
    private var pendingMessages: [AgentMessage]?
    private var pendingTheme: Theme?
    private var pendingAnimated = false
    private var pendingScrollToBottomTrigger = 0
    private var pendingBottomInset: CGFloat = 0
    private var streamingUpdateWorkItem: DispatchWorkItem?
    private var resizeLayoutWorkItem: DispatchWorkItem?
    private var pendingResizeWidth: CGFloat?
    public var onNearBottomChanged: ((Bool) -> Void)?

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
        drawsBackground = false
        borderType = .noBorder
        wantsLayer = true

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        clipView.postsBoundsChangedNotifications = true
        self.contentView = clipView

        boundsChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.notifyNearBottomChanged()
        }

        documentView = documentViewCustom
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if !ImageAttachmentHelpers.extractImages(from: pb).isEmpty {
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
        if let boundsChangeObserver {
            NotificationCenter.default.removeObserver(boundsChangeObserver)
        }
        streamingUpdateWorkItem?.cancel()
        resizeLayoutWorkItem?.cancel()
    }

    public func update(
        messages: [AgentMessage],
        theme: Theme,
        animated: Bool,
        scrollToBottomTrigger: Int = 0,
        bottomInset: CGFloat = 0
    ) {
        // SwiftUI can deliver a new value for every token. Coalesce those
        // values before touching the AppKit hierarchy; the latest snapshot is
        // all the chat needs to render.
        pendingMessages = messages
        pendingTheme = theme
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
        documentViewCustom.setBottomInset(pendingBottomInset, in: self)
        documentViewCustom.updateMessages(
            messages,
            theme: theme,
            in: self,
            animated: pendingAnimated
        )

        if shouldScrollToBottom {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollToBottom(animated: true)
                self.notifyNearBottomChanged()
            }
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = contentView.bounds.width
        guard width > 50, abs(width - documentViewCustom.lastLayoutRequestWidth) > 0.5 else { return }

        pendingResizeWidth = width
        resizeLayoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushResizeLayout()
        }
        resizeLayoutWorkItem = workItem
        // NSSplitView sends a frame update for practically every mouse move.
        // A short debounce keeps the drag responsive while still updating at a
        // useful cadence, and viewDidEndLiveResize flushes the final width.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        flushResizeLayout()
    }

    private func flushResizeLayout() {
        resizeLayoutWorkItem?.cancel()
        resizeLayoutWorkItem = nil
        guard let width = pendingResizeWidth, width > 50 else { return }
        pendingResizeWidth = nil
        documentViewCustom.layoutMessages(width: width, isResize: true)
    }

    public func scrollToBottom(animated: Bool = true, duration: TimeInterval = 0.2) {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        guard docHeight > clipBounds.height else { return }

        let targetPoint = NSPoint(x: 0, y: docHeight - clipBounds.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(targetPoint)
                reflectScrolledClipView(contentView)
            }
        } else {
            contentView.scroll(to: targetPoint)
            reflectScrolledClipView(contentView)
        }
    }

    public var isNearBottom: Bool {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        return docHeight <= clipBounds.height || clipBounds.maxY >= docHeight - 35
    }

    private func notifyNearBottomChanged() {
        let nearBottom = isNearBottom
        guard lastNearBottom != nearBottom else { return }
        lastNearBottom = nearBottom

        guard let callback = onNearBottomChanged else { return }
        DispatchQueue.main.async {
            callback(nearBottom)
        }
    }
}

/// Standard AppKit chat scroller. This intentionally lives next to, rather
/// than replacing, `AgentNativeChatScrollView` so the custom implementation
/// remains available as a quick fallback while the native scroll behavior is
/// evaluated.
public final class AgentNativeStandardChatScrollView: NSScrollView {
    private let documentViewCustom = AgentNativeStandardChatDocumentView()
    private var boundsChangeObserver: NSObjectProtocol?
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
        drawsBackground = false
        borderType = .noBorder
        scrollsDynamically = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        clipView.postsBoundsChangedNotifications = true
        self.contentView = clipView

        documentView = documentViewCustom

        boundsChangeObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.notifyNearBottomChanged()
            self.documentViewCustom.updateVisibleCells(in: self.contentView)
        }

        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if !ImageAttachmentHelpers.extractImages(from: pb).isEmpty {
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
        if let boundsChangeObserver {
            NotificationCenter.default.removeObserver(boundsChangeObserver)
        }
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
        super.setFrameSize(newSize)
        let width = contentView.bounds.width
        guard width > 50, abs(width - documentViewCustom.lastLayoutWidth) > 0.5 else { return }

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
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizeLayoutWorkItem?.cancel()
        resizeLayoutWorkItem = nil
        if let width = pendingResizeWidth, width > 50 {
            pendingResizeWidth = nil
            documentViewCustom.layoutContent(for: width)
            if followsBottom {
                scrollToBottom(animated: false)
            }
        }
    }

    public func scrollToBottom(animated: Bool = true, duration: TimeInterval = 0.2) {
        let targetY = max(0, documentViewCustom.bounds.height - contentView.bounds.height)
        let targetPoint = NSPoint(x: contentView.bounds.origin.x, y: targetY)
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

    /// Expanding a tool call is an explicit inspection action. Do not let a
    /// later message update pull the user back to the bottom while they read it.
    public func stopFollowingBottom() {
        followsBottom = false
        contentView.layer?.removeAllAnimations()
    }

    public var isNearBottom: Bool {
        let clipBounds = contentView.bounds
        let docHeight = documentViewCustom.bounds.height
        return docHeight <= clipBounds.height || clipBounds.maxY >= docHeight - 45
    }

    private func notifyNearBottomChanged() {
        let nearBottom = isNearBottom
        followsBottom = nearBottom
        guard lastNearBottom != nearBottom else { return }
        lastNearBottom = nearBottom
        onNearBottomChanged?(nearBottom)
    }
}

public final class AgentNativeStandardChatDocumentView: NSView {
    public override var isFlipped: Bool { true }

    public struct CellEntry {
        public let id: UUID
        public let cell: AgentNativeMessageCell
        public var frame: NSRect
    }

    private var cells: [UUID: AgentNativeMessageCell] = [:]
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
        in scrollView: AgentNativeStandardChatScrollView,
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
            let cell: AgentNativeMessageCell
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
                cell = AgentNativeMessageCell(
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
            currentY += height + 10
        }

        let contentHeight = currentY + 6 + bottomInset
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let documentHeight = max(contentHeight, viewportHeight)
        setFrameSize(NSSize(width: contentWidth, height: documentHeight))

        updateVisibleCells(in: enclosingScrollView?.contentView)
    }

    public func updateVisibleCells(in clipView: NSClipView?) {
        guard !orderedCells.isEmpty else { return }
        let clip = clipView ?? enclosingScrollView?.contentView
        let vis = clip?.documentVisibleRect ?? bounds
        // 600px buffer above and below for smooth pre-rendering without jank
        let bufferRect = NSRect(
            x: 0,
            y: max(0, vis.minY - 600),
            width: max(vis.width, bounds.width),
            height: vis.height + 1200
        )

        for item in orderedCells {
            let isVisible = item.frame.intersects(bufferRect)
            if isVisible {
                if item.cell.superview == nil {
                    item.cell.frame = item.frame
                    addSubview(item.cell)
                } else if item.cell.frame != item.frame {
                    item.cell.frame = item.frame
                }
            } else {
                if item.cell.superview != nil {
                    item.cell.removeFromSuperview()
                }
            }
        }
    }
}

public final class FlippedClipView: NSClipView {
    public override var isFlipped: Bool { true }
}

public class AgentNativeFlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// Read-only labels in the chat must never advertise text editing.
public final class AgentNativeStaticTextField: NSTextField {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    public convenience init(wrappingLabelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        refusesFirstResponder = true
        focusRingType = .none
    }
}

public final class AgentNativeCodeBlockHeaderView: AgentNativeFlippedView {
    public let langLabel = AgentNativeStaticTextField(labelWithString: "")
    public let toggleButton = NSButton()
    public let copyBtn = NSButton()
    private var trackingArea: NSTrackingArea?
    public private(set) var isExpanded = false
    public var onToggle: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        copyBtn.wantsLayer = true
        copyBtn.alphaValue = 0.0
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        copyBtn.wantsLayer = true
        copyBtn.alphaValue = 0.0
    }


    @objc public func toggleCodeBlock() {
        setExpanded(!isExpanded)
        onToggle?()
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        toggleButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: expanded ? "Collapse code block" : "Expand code block"
        )?.withSymbolConfiguration(configuration)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            // Do not use `.inVisibleRect` here: AppKit rebuilds this tracking
            // area for every scroll tick as the header crosses the clip view.
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyBtn.animator().alphaValue = 1.0
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyBtn.animator().alphaValue = 0.0
        }
    }
}

public final class AgentNativeCodeBlockView: AgentNativeFlippedView {
    public let header = AgentNativeCodeBlockHeaderView()
    public let codeScrollView = NSScrollView()
    public let tv = AgentSelectableTextView()

    public var isExpanded: Bool { header.isExpanded }
}

public final class AgentNativeThoughtBlockView: AgentNativeFlippedView {
    public let headerButton = NSButton()
    public let textView = AgentSelectableTextView()
    public private(set) var isExpanded = false
    public private(set) var isExpandable: Bool
    public var onToggle: (() -> Void)?

    public init(title: String, attributedText: NSAttributedString, isExpandable: Bool = true) {
        self.isExpandable = isExpandable
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        headerButton.isBordered = false
        headerButton.setButtonType(.momentaryPushIn)
        headerButton.alignment = .left
        headerButton.imagePosition = .imageRight
        headerButton.imageHugsTitle = true
        headerButton.imageScaling = .scaleProportionallyDown
        headerButton.target = self
        headerButton.action = #selector(toggle)
        headerButton.isEnabled = isExpandable
        headerButton.toolTip = isExpandable ? "Expand thought" : nil
        addSubview(headerButton)

        textView.isHidden = true
        textView.alphaValue = 0
        addSubview(textView)

        update(title: title, attributedText: attributedText)
        updateHeaderAppearance()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(title: String, attributedText: NSAttributedString) {
        headerButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        textView.textStorage?.setAttributedString(attributedText)
        updateHeaderAppearance()
    }

    @objc public func toggle() {
        guard isExpandable else { return }
        setExpanded(!isExpanded, animated: true)
        onToggle?()
    }

    public func setExpanded(_ expanded: Bool, animated: Bool = false) {
        guard isExpandable else {
            isExpanded = false
            textView.isHidden = true
            textView.alphaValue = 0
            return
        }
        isExpanded = expanded
        headerButton.toolTip = expanded ? "Collapse thought" : "Expand thought"
        updateHeaderAppearance()

        guard animated else {
            textView.isHidden = !expanded
            textView.alphaValue = expanded ? 1 : 0
            return
        }

        if expanded {
            textView.isHidden = false
            textView.alphaValue = 1
        } else {
            textView.alphaValue = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.isExpanded else { return }
                self.textView.isHidden = true
            }
        }
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        let headerHeight: CGFloat = 20
        guard isExpanded, !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return headerHeight
        }
        let textHeight = measuredTextHeight(width: max(1, width - 8))
        return headerHeight + textHeight + 6
    }

    public func applyLayout(width: CGFloat, animated: Bool) {
        let headerHeight: CGFloat = 20
        let headerFrame = NSRect(x: 0, y: 0, width: max(1, width), height: headerHeight)
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let textHeight = isExpanded && hasText ? measuredTextHeight(width: max(1, width - 8)) : 0
        let textFrame = NSRect(x: 8, y: headerHeight + 2, width: max(1, width - 8), height: textHeight)

        if animated {
            headerButton.animator().frame = headerFrame
            textView.animator().frame = textFrame
        } else {
            headerButton.frame = headerFrame
            textView.frame = textFrame
        }
    }

    public func updateColors(theme: Theme) {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
    }

    private func updateHeaderAppearance() {
        guard isExpandable else {
            headerButton.image = nil
            return
        }
        let symbolName = isExpanded ? "chevron.down" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        headerButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isExpanded ? "Collapse thought" : "Expand thought"
        )?.withSymbolConfiguration(configuration)
    }

    private func measuredTextHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 18 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(18, ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2))
    }
}

public final class AgentSelectableTextView: NSTextView {
    public weak var parentCell: AgentNativeMessageCell?
    public var cellId: UUID?
    public var tvKey: String = ""

    public init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        self.isEditable = false
        self.isSelectable = false
        // These views are immutable chat output. Keep AppKit from starting
        // spell/grammar/link and typing-substitution work while a text layer
        // is exposed during scrolling.
        self.isContinuousSpellCheckingEnabled = false
        self.isGrammarCheckingEnabled = false
        self.isAutomaticSpellingCorrectionEnabled = false
        self.isAutomaticTextCompletionEnabled = false
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticLinkDetectionEnabled = false
        self.isAutomaticDataDetectionEnabled = false
        self.enabledTextCheckingTypes = 0
        self.allowsUndo = false
        self.drawsBackground = false
        self.textContainerInset = .zero
        self.alignment = .left
        self.isVerticallyResizable = false
        self.isHorizontallyResizable = false
        self.wantsLayer = true
        self.layer?.drawsAsynchronously = false
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        if let sv = enclosingScrollView, !(sv is AgentNativeChatScrollView) {
            return super.hitTest(point)
        }
        return nil
    }
}

public enum AgentChatSelectionGranularity {
    case character
    case word
    case paragraph
}

func expandChatSelectionRange(_ range: NSRange, in text: String, granularity: AgentChatSelectionGranularity) -> NSRange {
    guard !text.isEmpty, granularity != .character else { return range }
    let ns = text as NSString
    guard ns.length > 0 else { return range }

    let start = max(0, min(range.location, ns.length - 1))
    let end = max(0, min(range.location + range.length, ns.length))

    switch granularity {
    case .character:
        return range

    case .word:
        var wStart = start
        var wEnd = max(start, end)
        let nonWord = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        while wStart > 0 {
            let prev = ns.character(at: wStart - 1)
            if let s = UnicodeScalar(prev), nonWord.contains(s) { break }
            wStart -= 1
        }
        while wEnd < ns.length {
            let curr = ns.character(at: wEnd)
            if let s = UnicodeScalar(curr), nonWord.contains(s) { break }
            wEnd += 1
        }
        return NSRange(location: wStart, length: max(1, wEnd - wStart))

    case .paragraph:
        let lineStartRange = ns.lineRange(for: NSRange(location: start, length: 0))
        let targetEnd = max(start, min(end, ns.length - 1))
        let lineEndRange = ns.lineRange(for: NSRange(location: targetEnd, length: 0))
        let pStart = lineStartRange.location
        let pEnd = lineEndRange.location + lineEndRange.length
        return NSRange(location: pStart, length: max(1, pEnd - pStart))
    }
}

func findNextWordBoundary(after idx: Int, in text: String) -> Int {
    let ns = text as NSString
    guard ns.length > 0 else { return 0 }
    let nonWord = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    var i = max(0, min(idx, ns.length - 1))
    while i < ns.length {
        let c = ns.character(at: i)
        if let s = UnicodeScalar(c), !nonWord.contains(s) { break }
        i += 1
    }
    while i < ns.length {
        let c = ns.character(at: i)
        if let s = UnicodeScalar(c), nonWord.contains(s) { break }
        i += 1
    }
    return min(ns.length, i)
}

func findPrevWordBoundary(before idx: Int, in text: String) -> Int {
    let ns = text as NSString
    guard ns.length > 0 else { return 0 }
    let nonWord = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    var i = max(0, min(idx, ns.length))
    while i > 0 {
        let c = ns.character(at: i - 1)
        if let s = UnicodeScalar(c), !nonWord.contains(s) { break }
        i -= 1
    }
    while i > 0 {
        let c = ns.character(at: i - 1)
        if let s = UnicodeScalar(c), nonWord.contains(s) { break }
        i -= 1
    }
    return max(0, i)
}

func findNextParagraphBoundary(after idx: Int, in text: String) -> Int {
    let ns = text as NSString
    guard ns.length > 0 else { return 0 }
    let lineRange = ns.lineRange(for: NSRange(location: max(0, min(idx, ns.length - 1)), length: 0))
    return min(ns.length, lineRange.location + lineRange.length)
}

func findPrevParagraphBoundary(before idx: Int, in text: String) -> Int {
    let ns = text as NSString
    guard ns.length > 0 else { return 0 }
    let currentLine = ns.lineRange(for: NSRange(location: max(0, min(idx, ns.length - 1)), length: 0))
    if currentLine.location < idx {
        return currentLine.location
    } else if currentLine.location > 0 {
        let prevLine = ns.lineRange(for: NSRange(location: currentLine.location - 1, length: 0))
        return prevLine.location
    } else {
        return 0
    }
}

public final class AgentNativeChatDocumentView: NSView {
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    private var messages: [AgentMessage] = []
    private var theme: Theme = .zedDark
    private var cells: [UUID: AgentNativeMessageCell] = [:]
    private var orderedCells: [(id: UUID, cell: AgentNativeMessageCell)] = []
    private var lastRenderedWidth: CGFloat = 0
    private var lastMessageIds: [UUID] = []

    private let verticalSpacing: CGFloat = 10
    private let topPadding: CGFloat = 8
    private let bottomPadding: CGFloat = 16
    private var bottomInset: CGFloat = 0

    fileprivate var lastLayoutRequestWidth: CGFloat { lastRenderedWidth }

    // Custom Cross-Message Selection State
    private var isDraggingSelection: Bool = false
    private var selectionGranularity: AgentChatSelectionGranularity = .character
    private var selectionAnchorPoint: NSPoint? = nil
    private var selectionStartPoint: NSPoint? = nil
    private var selectionEndPoint: NSPoint? = nil
    private var keyboardSelectedTVIndex: Int? = nil
    private var keyboardSelectedCharIndex: Int? = nil
    private var doubleClickStartPoint: NSPoint? = nil
    private var doubleClickEndPoint: NSPoint? = nil
    private var doubleClickTVIndex: Int? = nil
    private var doubleClickRange: NSRange? = nil
    private var autoScrollTimer: Timer? = nil
    private var lastDragEvent: NSEvent? = nil
    private struct PersistentTextSelection {
        var startCellId: UUID
        var startTVKey: String
        var startCharIndex: Int
        var endCellId: UUID
        var endTVKey: String
        var endCharIndex: Int
    }
    private var persistentSelection: PersistentTextSelection? = nil
    private var selectionHighlightRects: [NSRect] = []
    private var selectedCombinedText: String = ""
    private let selectionHighlightLayer = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        selectionHighlightLayer.name = "selectionHighlightLayer"
        selectionHighlightLayer.zPosition = 9999
        layer?.addSublayer(selectionHighlightLayer)
    }

    public func setBottomInset(_ inset: CGFloat, in scrollView: AgentNativeChatScrollView) {
        let newInset = ceil(max(0, inset))
        guard abs(newInset - bottomInset) >= 2.0 else { return }
        bottomInset = newInset

        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        if width > 50 {
            layoutMessages(width: width, isResize: true)
        }
    }

    public func updateMessages(
        _ newMessages: [AgentMessage],
        theme: Theme,
        in scrollView: AgentNativeChatScrollView,
        animated: Bool
    ) {
        let newIds = newMessages.map(\.id)
        let themeChanged = theme.id != self.theme.id
        let messagesChanged = newIds != lastMessageIds || newMessages.count != self.messages.count || zip(newMessages, self.messages).contains { pair in
            messageNeedsUpdate(old: pair.1, new: pair.0)
        }

        guard newIds != lastMessageIds || messagesChanged || themeChanged else { return }

        // Keep the user's position when they have scrolled away from the bottom.
        // Streaming updates should only follow the latest message if the user was
        // already at the bottom before the update.
        let wasAtBottom = scrollView.isNearBottom
        let isInitialRender = lastMessageIds.isEmpty

        self.messages = newMessages
        self.theme = theme
        self.lastMessageIds = newIds

        // Remove unused cells
        let currentIdSet = Set(newIds)
        for (id, cell) in cells where !currentIdSet.contains(id) {
            cell.removeFromSuperview()
            cells.removeValue(forKey: id)
        }

        // Add or update cells
        var newOrdered: [(id: UUID, cell: AgentNativeMessageCell)] = []
        for message in newMessages {
            if let existing = cells[message.id] {
                // Most updates are streamed into the last assistant message. Do
                // not rebuild every previous message's AppKit view on each chunk.
                if messageNeedsUpdate(old: existing.message, new: message) || themeChanged {
                    existing.configure(message: message, theme: theme)
                }
                newOrdered.append((id: message.id, cell: existing))
            } else {
                let cell = AgentNativeMessageCell(message: message, theme: theme)
                cell.onToggleThought = { [weak self, weak cell] in
                    guard let self = self, let cell = cell else { return }
                    self.layoutMessages(
                        width: self.lastRenderedWidth,
                        isResize: false,
                        anchorCellId: cell.message.id,
                        animated: true
                    )
                }
                cell.onToggleUserExpand = { [weak self, weak cell] in
                    guard let self = self, let cell = cell else { return }
                    self.layoutMessages(
                        width: self.lastRenderedWidth,
                        isResize: false,
                        anchorCellId: cell.message.id,
                        animated: true
                    )
                }
                addSubview(cell)
                cells[message.id] = cell
                newOrdered.append((id: message.id, cell: cell))
            }
        }
        self.orderedCells = newOrdered

        let width = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        layoutMessages(width: max(100, width), isResize: false, anchorCellId: nil)

        if isInitialRender || wasAtBottom {
            let isStreamingUpdate = !isInitialRender && newMessages.last?.isStreaming == true
            scrollView.scrollToBottom(
                // Streaming updates arrive while the document height is
                // changing. Animating every new target makes AppKit chase
                // stale bounds and visibly oscillate up and down.
                animated: animated && !isStreamingUpdate,
                duration: 0.1
            )
        }
    }

    private func messageNeedsUpdate(old: AgentMessage, new: AgentMessage) -> Bool {
        guard old.id == new.id else { return true }
        if old.role != new.role || old.isStreaming != new.isStreaming { return true }

        // During streaming, an append changes the length immediately. Avoid a
        // second full-string comparison for every token; the equality check is
        // only needed for same-length replacement/finalization updates.
        if old.content.count != new.content.count || old.content != new.content { return true }
        if old.thought != new.thought || old.toolCalls != new.toolCalls { return true }
        return false
    }

    public func layoutMessages(
        width: CGFloat,
        isResize: Bool,
        anchorCellId: UUID? = nil,
        animated: Bool = false
    ) {
        guard width > 50 else { return }
        self.lastRenderedWidth = width

        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        let docHeight = bounds.height
        let isAtBottom = docHeight > clipBounds.height && (clipBounds.maxY >= docHeight - 35)

        var anchorId: UUID? = anchorCellId
        var anchorOffset: CGFloat = 0

        if let aId = anchorCellId, let cell = cells[aId] {
            anchorOffset = cell.frame.minY - clipBounds.minY
        } else if isResize && !isAtBottom {
            for item in orderedCells {
                if item.cell.frame.maxY >= clipBounds.minY {
                    anchorId = item.id
                    anchorOffset = item.cell.frame.minY - clipBounds.minY
                    break
                }
            }
        }

        // Sequential deterministic placement of every message
        var currentY: CGFloat = topPadding
        var newFrames: [(cell: AgentNativeMessageCell, frame: NSRect)] = []
        for item in orderedCells {
            let cell = item.cell
            let cellHeight = cell.measureHeight(for: width)
            let newFrame = NSRect(x: 0, y: currentY, width: width, height: cellHeight)
            newFrames.append((cell: cell, frame: newFrame))
            currentY += cellHeight + verticalSpacing
        }

        let totalHeight = currentY + bottomPadding + bottomInset
        let finalDocHeight = max(totalHeight, clipBounds.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            for item in newFrames {
                let previousFrame = item.cell.frame
                item.cell.animator().setFrameOrigin(item.frame.origin)
                item.cell.animator().setFrameSize(item.frame.size)
                let sizeChanged = abs(previousFrame.width - item.frame.width) > 0.5 ||
                    abs(previousFrame.height - item.frame.height) > 0.5
                if item.cell.needsLayoutApplication || sizeChanged {
                    item.cell.applyLayout(for: width, animated: true)
                }
            }
                animator().setFrameSize(NSSize(width: width, height: finalDocHeight))
                if let anchorId, let animatedCell = cells[anchorId] {
                    animatedCell.animateThoughtVisibility()
                }
            } completionHandler: {
                for item in self.orderedCells {
                    item.cell.finishVisibilityAnimation()
                }
            }
        } else {
            for item in newFrames {
                let previousFrame = item.cell.frame
                item.cell.frame = item.frame
                let sizeChanged = abs(previousFrame.width - item.frame.width) > 0.5 ||
                    abs(previousFrame.height - item.frame.height) > 0.5
                if item.cell.needsLayoutApplication || sizeChanged {
                    item.cell.applyLayout(for: width, animated: false)
                }
            }
            super.setFrameSize(NSSize(width: width, height: finalDocHeight))
        }
        selectionHighlightLayer.frame = NSRect(x: 0, y: 0, width: width, height: finalDocHeight)

        // Restore scroll position
        if let aId = anchorId, let anchoredCell = cells[aId] {
            let newY = anchoredCell.frame.minY - anchorOffset
            let clampedY = max(0, min(finalDocHeight - clipBounds.height, newY))
            clipView.scroll(to: NSPoint(x: 0, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
        } else if isResize && isAtBottom {
            let targetY = max(0, finalDocHeight - clipBounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        // Restore persistent selection highlight accurately across resize / reflow / thoughts toggle
        if let sel = persistentSelection {
            if let sTV = findSelectableTextView(cellId: sel.startCellId, tvKey: sel.startTVKey),
               let eTV = findSelectableTextView(cellId: sel.endCellId, tvKey: sel.endTVKey) {
                let sPt = sTV.convert(pointForCharacterIndex(sel.startCharIndex, in: sTV), to: self)
                let ePt = eTV.convert(pointForCharacterIndex(sel.endCharIndex, in: eTV), to: self)
                selectionStartPoint = sPt
                selectionEndPoint = ePt
                if selectionAnchorPoint != nil {
                    selectionAnchorPoint = sPt
                }
                updateSelectionHighlight(updatePersistent: false)
            } else {
                clearSelection()
            }
        }
    }

    private func findSelectableTextView(cellId: UUID, tvKey: String) -> AgentSelectableTextView? {
        guard let cell = cells[cellId] else { return nil }
        return cell.allSelectableTextViews().first(where: { $0.tvKey == tvKey })
    }

    // MARK: - Custom Cross-Message Selection

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        // If clicking on interactive controls (like Buttons, Scrollers), let them handle it
        if let button = view as? NSButton {
            return button
        }
        if let scroller = view as? NSScroller {
            return scroller
        }
        // If inside an inner scroll view (like tool detail scroll view)
        var curr = view
        while curr != nil && curr !== self {
            if let sv = curr as? NSScrollView, !(sv is AgentNativeChatScrollView) {
                return view ?? curr
            }
            curr = curr?.superview
        }
        // Otherwise, this document view handles selection gestures across all messages
        return self
    }

    public override func scrollWheel(with event: NSEvent) {
        // The document view is the hit-test fallback for selectable code blocks.
        // Forward wheel/trackpad events explicitly so large markdown sections do
        // not swallow scrolling when the pointer is over their text view.
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)

        keyboardSelectedTVIndex = nil
        keyboardSelectedCharIndex = nil

        if isShift, let anchor = selectionAnchorPoint ?? selectionStartPoint {
            // Extend existing selection from anchor to new point
            selectionStartPoint = anchor
            selectionEndPoint = pt
            isDraggingSelection = true
            updateSelectionHighlight()
            return
        }

        selectionAnchorPoint = pt
        selectionStartPoint = pt
        selectionEndPoint = pt
        isDraggingSelection = true
        clearSelection()

        if event.clickCount == 2 || event.clickCount >= 3 {
            let gran: AgentChatSelectionGranularity = event.clickCount == 2 ? .word : .paragraph
            selectionGranularity = gran

            let allTVs = getAllSelectableTextViewsInDocument()
            if let bestTVIdx = allTVs.firstIndex(where: { pt.y >= $0.frameInDoc.minY - 2 && pt.y <= $0.frameInDoc.maxY + 2 }) {
                let curTV = allTVs[bestTVIdx].tv
                let pInTV = curTV.convert(pt, from: self)
                let charIdx = curTV.characterIndexForInsertion(at: pInTV)
                let expanded = expandChatSelectionRange(NSRange(location: charIdx, length: 0), in: curTV.string, granularity: gran)

                let leftPtInTV = pointForCharacterIndex(expanded.location, in: curTV)
                let rightPtInTV = pointForCharacterIndex(expanded.location + expanded.length, in: curTV)

                let leftDocPt = curTV.convert(leftPtInTV, to: self)
                let rightDocPt = curTV.convert(rightPtInTV, to: self)

                doubleClickStartPoint = leftDocPt
                doubleClickEndPoint = rightDocPt
                doubleClickTVIndex = bestTVIdx
                doubleClickRange = expanded

                selectionStartPoint = leftDocPt
                selectionEndPoint = rightDocPt
                selectionAnchorPoint = leftDocPt
            }
            updateSelectionHighlight()
        } else {
            selectionGranularity = .character
            doubleClickStartPoint = nil
            doubleClickEndPoint = nil
            doubleClickTVIndex = nil
            doubleClickRange = nil
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection else { return }
        keyboardSelectedTVIndex = nil
        keyboardSelectedCharIndex = nil
        lastDragEvent = event
        let pt = convert(event.locationInWindow, from: nil)
        selectionEndPoint = pt
        updateSelectionHighlight()
        startAutoScrollTimer(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        stopAutoScrollTimer()
        guard isDraggingSelection else { return }
        isDraggingSelection = false

        if selectionGranularity == .character, !event.modifierFlags.contains(.shift), let p1 = selectionStartPoint, let p2 = selectionEndPoint {
            let dist = hypot(p2.x - p1.x, p2.y - p1.y)
            if dist < 4 {
                // Clicked without dragging -> clear highlight but keep anchor point
                clearSelection()
            }
        }
    }

    private func currentScreenFPS() -> Double {
        let maxFPS = Double(window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 120)
        return max(30.0, maxFPS)
    }

    private func startAutoScrollTimer(with event: NSEvent) {
        lastDragEvent = event
        if autoScrollTimer == nil {
            let fps = currentScreenFPS()
            let timer = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
                self?.handleAutoScrollTick()
            }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.add(timer, forMode: .eventTracking)
            autoScrollTimer = timer
        }
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        lastDragEvent = nil
    }

    private func handleAutoScrollTick() {
        guard isDraggingSelection, let event = lastDragEvent, let scrollView = enclosingScrollView else {
            stopAutoScrollTimer()
            return
        }

        let clipView = scrollView.contentView
        let visibleRect = clipView.bounds
        let ptInDoc = convert(event.locationInWindow, from: nil)

        let topThreshold = visibleRect.minY + 25
        let bottomThreshold = visibleRect.maxY - 25

        var baseDeltaY: CGFloat = 0

        if ptInDoc.y < topThreshold {
            let distance = topThreshold - ptInDoc.y
            baseDeltaY = -min(28, max(3, distance * 0.35))
        } else if ptInDoc.y > bottomThreshold {
            let distance = ptInDoc.y - bottomThreshold
            baseDeltaY = min(28, max(3, distance * 0.35))
        }

        guard baseDeltaY != 0 else { return }

        // Scale per-frame movement by (60.0 / currentScreenFPS) for frame-rate independence
        let fps = currentScreenFPS()
        let scrollDeltaY = baseDeltaY * CGFloat(60.0 / fps)

        let maxScrollY = max(0, bounds.height - visibleRect.height)
        let newScrollY = max(0, min(maxScrollY, visibleRect.minY + scrollDeltaY))

        guard newScrollY != visibleRect.minY else { return }

        clipView.scroll(to: NSPoint(x: 0, y: newScrollY))
        scrollView.reflectScrolledClipView(clipView)

        // Update selection endpoint with the updated mouse position in the newly scrolled document
        let updatedPt = convert(event.locationInWindow, from: nil)
        selectionEndPoint = updatedPt
        updateSelectionHighlight()
    }

    private func clearSelection() {
        stopAutoScrollTimer()
        selectionHighlightRects.removeAll()
        selectedCombinedText = ""
        selectionHighlightLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        keyboardSelectedTVIndex = nil
        keyboardSelectedCharIndex = nil
        doubleClickStartPoint = nil
        doubleClickEndPoint = nil
        doubleClickTVIndex = nil
        doubleClickRange = nil
        persistentSelection = nil
    }

    private func updateSelectionHighlight(updatePersistent: Bool = true) {
        guard let p1 = selectionStartPoint, let p2 = selectionEndPoint else { return }

        let isForward = p1.y < p2.y || (abs(p1.y - p2.y) < 2 && p1.x <= p2.x)
        let startPt = isForward ? p1 : p2
        let endPt = isForward ? p2 : p1
        let minY = min(p1.y, p2.y)
        let maxY = max(p1.y, p2.y)

        var allRects: [NSRect] = []
        var textParts: [String] = []

        for item in orderedCells {
            let cell = item.cell
            let res = cell.getSelection(
                startPointInDoc: startPt,
                endPointInDoc: endPt,
                minY: minY,
                maxY: maxY,
                granularity: selectionGranularity
            )
            if !res.rectsInDoc.isEmpty {
                allRects.append(contentsOf: res.rectsInDoc)
            }
            if !res.text.isEmpty {
                textParts.append(res.text)
            }
        }

        self.selectionHighlightRects = allRects
        self.selectedCombinedText = textParts.joined(separator: "\n\n")

        renderSelectionHighlightLayers()

        if updatePersistent {
            let allTVs = getAllSelectableTextViewsInDocument()
            if !allTVs.isEmpty {
                var startTVIdx = 0
                for (i, item) in allTVs.enumerated() {
                    if startPt.y >= item.frameInDoc.minY - 2 && startPt.y <= item.frameInDoc.maxY + 2 {
                        startTVIdx = i
                        break
                    }
                    if startPt.y < item.frameInDoc.minY {
                        startTVIdx = max(0, i - 1)
                        break
                    }
                    startTVIdx = i
                }

                var endTVIdx = allTVs.count - 1
                for (i, item) in allTVs.enumerated() {
                    if endPt.y >= item.frameInDoc.minY - 2 && endPt.y <= item.frameInDoc.maxY + 2 {
                        endTVIdx = i
                        break
                    }
                    if endPt.y < item.frameInDoc.minY {
                        endTVIdx = max(0, i - 1)
                        break
                    }
                    endTVIdx = i
                }

                let sTV = allTVs[startTVIdx].tv
                let eTV = allTVs[endTVIdx].tv
                if let sCellId = sTV.cellId, let eCellId = eTV.cellId {
                    let sChar = sTV.characterIndexForInsertion(at: sTV.convert(startPt, from: self))
                    let eChar = eTV.characterIndexForInsertion(at: eTV.convert(endPt, from: self))

                    persistentSelection = PersistentTextSelection(
                        startCellId: sCellId,
                        startTVKey: sTV.tvKey,
                        startCharIndex: sChar,
                        endCellId: eCellId,
                        endTVKey: eTV.tvKey,
                        endCharIndex: eChar
                    )
                }
            }
        }
    }

    private func renderSelectionHighlightLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionHighlightLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let accentColor = NSColor.controlAccentColor.withAlphaComponent(0.38).cgColor

        for rect in selectionHighlightRects {
            let sublayer = CALayer()
            sublayer.frame = rect
            sublayer.backgroundColor = accentColor
            sublayer.cornerRadius = 3
            selectionHighlightLayer.addSublayer(sublayer)
        }
        CATransaction.commit()
    }

    public func selectAllMessages() {
        var allRects: [NSRect] = []
        var textParts: [String] = []

        for item in orderedCells {
            let cell = item.cell
            let res = cell.getAllSelection()
            allRects.append(contentsOf: res.rectsInDoc)
            if !res.text.isEmpty {
                textParts.append(res.text)
            }
        }

        self.selectionHighlightRects = allRects
        self.selectedCombinedText = textParts.joined(separator: "\n\n")
        renderSelectionHighlightLayers()
    }

    private func getAllSelectableTextViewsInDocument() -> [(tv: AgentSelectableTextView, frameInDoc: NSRect)] {
        var result: [(tv: AgentSelectableTextView, frameInDoc: NSRect)] = []
        for item in orderedCells {
            let tvs = item.cell.allSelectableTextViews()
            for tv in tvs {
                let frameInDoc = tv.convert(tv.bounds, to: self)
                result.append((tv: tv, frameInDoc: frameInDoc))
            }
        }
        return result
    }

    private func pointForCharacterIndex(_ idx: Int, in tv: AgentSelectableTextView) -> NSPoint {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return NSPoint(x: 0, y: 10) }
        let textLen = tv.string.count
        guard textLen > 0 else { return NSPoint(x: 0, y: 10) }

        let safeIdx = max(0, min(idx, textLen))
        if safeIdx == 0 {
            let glyphIdx = lm.glyphIndexForCharacter(at: 0)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
            return NSPoint(x: rect.minX, y: rect.midY)
        } else if safeIdx < textLen {
            let glyphIdx = lm.glyphIndexForCharacter(at: safeIdx)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
            return NSPoint(x: rect.minX, y: rect.midY)
        } else {
            let lastGlyph = lm.glyphIndexForCharacter(at: textLen - 1)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: tc)
            return NSPoint(x: rect.maxX, y: rect.midY)
        }
    }

    public override func keyDown(with event: NSEvent) {
        let isShift = event.modifierFlags.contains(.shift)
        let isCmd = event.modifierFlags.contains(.command)
        let isOption = event.modifierFlags.contains(.option)

        let leftArrow = 123
        let rightArrow = 124
        let downArrow = 125
        let upArrow = 126

        if isShift {
            let allTVs = getAllSelectableTextViewsInDocument()
            guard !allTVs.isEmpty else { return }

            if let dcLeft = doubleClickStartPoint, let dcRight = doubleClickEndPoint, let dcTV = doubleClickTVIndex, let dcRange = doubleClickRange {
                if Int(event.keyCode) == rightArrow || Int(event.keyCode) == downArrow {
                    selectionAnchorPoint = dcLeft
                    selectionStartPoint = dcLeft
                    selectionEndPoint = dcRight
                    keyboardSelectedTVIndex = dcTV
                    keyboardSelectedCharIndex = dcRange.location + dcRange.length
                } else if Int(event.keyCode) == leftArrow || Int(event.keyCode) == upArrow {
                    selectionAnchorPoint = dcRight
                    selectionStartPoint = dcRight
                    selectionEndPoint = dcLeft
                    keyboardSelectedTVIndex = dcTV
                    keyboardSelectedCharIndex = dcRange.location
                }
                doubleClickStartPoint = nil
                doubleClickEndPoint = nil
                doubleClickTVIndex = nil
                doubleClickRange = nil
            }

            // Always reset granularity to character for plain Shift+Arrows
            if !isOption {
                selectionGranularity = .character
            }

            if selectionAnchorPoint == nil {
                let firstTV = allTVs[0].tv
                let pt = firstTV.convert(pointForCharacterIndex(0, in: firstTV), to: self)
                selectionAnchorPoint = pt
                selectionStartPoint = pt
                selectionEndPoint = pt
                keyboardSelectedTVIndex = 0
                keyboardSelectedCharIndex = 0
            }

            guard var endPt = selectionEndPoint ?? selectionAnchorPoint else { return }

            var tvIdx: Int
            var charIdx: Int

            if let kTV = keyboardSelectedTVIndex, let kChar = keyboardSelectedCharIndex, kTV < allTVs.count {
                tvIdx = kTV
                charIdx = kChar
            } else {
                var bestIdx = 0
                var minDist: CGFloat = .greatestFiniteMagnitude
                for (i, item) in allTVs.enumerated() {
                    let f = item.frameInDoc
                    let midPt = NSPoint(x: f.midX, y: f.midY)
                    let dist = hypot(endPt.x - midPt.x, endPt.y - midPt.y)
                    if endPt.y >= f.minY - 2 && endPt.y <= f.maxY + 2 {
                        bestIdx = i
                        break
                    }
                    if dist < minDist {
                        minDist = dist
                        bestIdx = i
                    }
                }
                tvIdx = bestIdx
                let curTV = allTVs[tvIdx].tv
                let pInTV = curTV.convert(endPt, from: self)
                charIdx = curTV.characterIndexForInsertion(at: pInTV)
            }

            let curTV = allTVs[tvIdx].tv

            let isWordGranular = isOption && (Int(event.keyCode) == rightArrow || Int(event.keyCode) == leftArrow)
            let isParaGranular = isOption && (Int(event.keyCode) == downArrow || Int(event.keyCode) == upArrow)

            switch Int(event.keyCode) {
            case rightArrow:
                if isCmd {
                    let ns = curTV.string as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: max(0, min(charIdx, ns.length - 1)), length: 0))
                    charIdx = min(ns.length, lineRange.location + lineRange.length)
                } else if isWordGranular {
                    let nextBound = findNextWordBoundary(after: charIdx, in: curTV.string)
                    if nextBound > charIdx {
                        charIdx = nextBound
                    } else if tvIdx + 1 < allTVs.count {
                        tvIdx += 1
                        charIdx = min(allTVs[tvIdx].tv.string.count, findNextWordBoundary(after: 0, in: allTVs[tvIdx].tv.string))
                    } else {
                        charIdx = curTV.string.count
                    }
                } else {
                    charIdx += 1
                    if charIdx > curTV.string.count {
                        if tvIdx + 1 < allTVs.count {
                            tvIdx += 1
                            charIdx = min(1, allTVs[tvIdx].tv.string.count)
                        } else {
                            charIdx = curTV.string.count
                        }
                    }
                }

            case leftArrow:
                if isCmd {
                    let ns = curTV.string as NSString
                    let lineRange = ns.lineRange(for: NSRange(location: max(0, min(charIdx, ns.length - 1)), length: 0))
                    charIdx = lineRange.location
                } else if isWordGranular {
                    let prevBound = findPrevWordBoundary(before: charIdx, in: curTV.string)
                    if prevBound < charIdx {
                        charIdx = prevBound
                    } else if tvIdx > 0 {
                        tvIdx -= 1
                        let prevText = allTVs[tvIdx].tv.string
                        charIdx = findPrevWordBoundary(before: prevText.count, in: prevText)
                    } else {
                        charIdx = 0
                    }
                } else {
                    charIdx -= 1
                    if charIdx < 0 {
                        if tvIdx > 0 {
                            tvIdx -= 1
                            charIdx = max(0, allTVs[tvIdx].tv.string.count - 1)
                        } else {
                            charIdx = 0
                        }
                    }
                }

            case downArrow:
                if isCmd {
                    tvIdx = allTVs.count - 1
                    charIdx = allTVs[tvIdx].tv.string.count
                } else if isParaGranular {
                    let nextBound = findNextParagraphBoundary(after: charIdx, in: curTV.string)
                    if nextBound > charIdx {
                        charIdx = nextBound
                    } else if tvIdx + 1 < allTVs.count {
                        tvIdx += 1
                        charIdx = min(allTVs[tvIdx].tv.string.count, findNextParagraphBoundary(after: 0, in: allTVs[tvIdx].tv.string))
                    } else {
                        charIdx = curTV.string.count
                    }
                } else {
                    let targetTV = allTVs[tvIdx].tv
                    let p = targetTV.convert(endPt, from: self)
                    let newP = NSPoint(x: p.x, y: p.y + 18)
                    if newP.y > targetTV.bounds.height && tvIdx + 1 < allTVs.count {
                        tvIdx += 1
                        let nextTV = allTVs[tvIdx].tv
                        charIdx = nextTV.characterIndexForInsertion(at: NSPoint(x: p.x, y: 10))
                    } else {
                        charIdx = targetTV.characterIndexForInsertion(at: newP)
                    }
                }

            case upArrow:
                if isCmd {
                    tvIdx = 0
                    charIdx = 0
                } else if isParaGranular {
                    let prevBound = findPrevParagraphBoundary(before: charIdx, in: curTV.string)
                    if prevBound < charIdx {
                        charIdx = prevBound
                    } else if tvIdx > 0 {
                        tvIdx -= 1
                        let prevText = allTVs[tvIdx].tv.string
                        charIdx = findPrevParagraphBoundary(before: prevText.count, in: prevText)
                    } else {
                        charIdx = 0
                    }
                } else {
                    let targetTV = allTVs[tvIdx].tv
                    let p = targetTV.convert(endPt, from: self)
                    let newP = NSPoint(x: p.x, y: p.y - 18)
                    if newP.y < 0 && tvIdx > 0 {
                        tvIdx -= 1
                        let prevTV = allTVs[tvIdx].tv
                        charIdx = prevTV.characterIndexForInsertion(at: NSPoint(x: p.x, y: prevTV.bounds.height - 10))
                    } else {
                        charIdx = targetTV.characterIndexForInsertion(at: newP)
                    }
                }

            default:
                super.keyDown(with: event)
                return
            }

            // Save discrete character location
            keyboardSelectedTVIndex = tvIdx
            keyboardSelectedCharIndex = charIdx

            let finalTV = allTVs[tvIdx].tv
            let ptInTV = pointForCharacterIndex(charIdx, in: finalTV)
            endPt = finalTV.convert(ptInTV, to: self)

            selectionEndPoint = endPt
            selectionStartPoint = selectionAnchorPoint
            updateSelectionHighlight()
            ensurePointVisible(endPt)
            return
        } else {
            // Arrow keys without shift: clear selection
            switch Int(event.keyCode) {
            case leftArrow, rightArrow, upArrow, downArrow:
                clearSelection()
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    private func ensurePointVisible(_ pt: NSPoint) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let visibleRect = clipView.bounds
        if pt.y < visibleRect.minY + 20 {
            let targetY = max(0, pt.y - 20)
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            enclosingScrollView?.reflectScrolledClipView(clipView)
        } else if pt.y > visibleRect.maxY - 20 {
            let targetY = min(bounds.height - visibleRect.height, pt.y - visibleRect.height + 20)
            clipView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCmd = event.modifierFlags.contains(.command)
        if isCmd {
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let isC = event.keyCode == 8 || chars == "c" || chars == "с" // Key C (Latin & Cyrillic)
            let isA = event.keyCode == 0 || chars == "a" || chars == "ф" // Key A (Latin & Cyrillic)

            if isC {
                if !selectedCombinedText.isEmpty {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(selectedCombinedText, forType: .string)
                    return true
                }
            } else if isA {
                selectAllMessages()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc public func copy(_ sender: Any?) {
        if !selectedCombinedText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(selectedCombinedText, forType: .string)
        }
    }

    public override func selectAll(_ sender: Any?) {
        selectAllMessages()
    }
}

/// Lightweight, non-interactive tool output used while the chat scrolling path
/// is being tuned. The expandable color card remains implemented below and can
/// be restored by flipping `usesSimpleToolCalls` in `AgentNativeMessageCell`.
public final class AgentNativeSimpleToolCallView: AgentNativeFlippedView {
    private let textLabel = AgentNativeStaticTextField(wrappingLabelWithString: "")
    private let text: NSAttributedString

    public init(item: ToolCallItem, theme: Theme) {
        let typeFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let titleFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let typeColor = NSColor(cgColor: theme.keyword.cgColor) ?? .controlAccentColor
        let titleColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        let detailColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: item.shortToolName, attributes: [
            .font: typeFont,
            .foregroundColor: typeColor,
            .paragraphStyle: paragraphStyle
        ]))
        result.append(NSAttributedString(string: "  ", attributes: [
            .font: detailFont,
            .foregroundColor: detailColor,
            .paragraphStyle: paragraphStyle
        ]))
        result.append(NSAttributedString(string: item.displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraphStyle
        ]))

        if let detail = item.descriptionText ?? item.summary, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: detailFont,
                .foregroundColor: detailColor,
                .paragraphStyle: paragraphStyle
            ]))
        }

        if item.status == .running {
            result.append(NSAttributedString(string: "\nRunning…", attributes: [
                .font: detailFont,
                .foregroundColor: detailColor,
                .paragraphStyle: paragraphStyle
            ]))
        } else if item.status == .failed {
            result.append(NSAttributedString(string: "\nFailed", attributes: [
                .font: detailFont,
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: paragraphStyle
            ]))
        }

        self.text = result
        super.init(frame: .zero)

        textLabel.attributedStringValue = result
        textLabel.isBezeled = false
        textLabel.drawsBackground = false
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.usesSingleLineMode = false
        addSubview(textLabel)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        let measured = measureAttributedTextHeight(text, maxWidth: max(50, width - 16))
        return min(58, max(20, measured + 2))
    }

    public func applyLayout(width: CGFloat) {
        let height = measureHeight(width: width)
        textLabel.frame = NSRect(x: 8, y: 2, width: max(50, width - 16), height: height - 2)
    }
}

public final class AgentNativeDiffStatsButton: NSButton {
    private var trackingArea: NSTrackingArea?
    public let badgeLabel = AgentNativeStaticTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        isBordered = false
        title = ""
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.alignment = .center
        badgeLabel.usesSingleLineMode = true
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.cell?.wraps = false
        badgeLabel.cell?.truncatesLastVisibleLine = false
        addSubview(badgeLabel)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    public override func layout() {
        super.layout()
        badgeLabel.frame = NSRect(x: 4, y: 1, width: max(0, bounds.width - 8), height: bounds.height - 2)
    }
}

public final class AgentNativeToolCardView: AgentNativeFlippedView {
    public private(set) var item: ToolCallItem
    private var theme: Theme
    private var toolcallColorMode: ToolcallColorMode
    public var isExpanded: Bool = false
    public var onToggle: (() -> Void)?
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    private let headerContainer = AgentNativeFlippedView()
    private let headerButton = NSButton()
    private let openInEditorButton = AgentHoverButton(frame: .zero)
    private let diffStatsButton = AgentNativeDiffStatsButton()
    private let actionPillView = AgentNativeFlippedView()
    private let actionIconView = NSImageView()
    private let actionTextLabel = AgentNativeStaticTextField(labelWithString: "")
    private let titleLabel = AgentNativeStaticTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let errorLabel = AgentNativeStaticTextField(labelWithString: "")
    private let chevronImageView = NSImageView()
    private let descriptionLabel = AgentNativeStaticTextField(wrappingLabelWithString: "")
    public let detailContainer = NSView()
    public let detailScrollView = NSScrollView()
    public let detailTextView = AgentSelectableTextView()
    private var virtualizedDetailView: CustomMultiBufferEditorView?
    private var cachedDetailAttributedString: NSAttributedString?
    private var cachedDetailHeightWidth: CGFloat = -1
    private var cachedDetailHeight: CGFloat = 0
    private var cachedDescriptionHeightWidth: CGFloat = -1
    private var cachedDescriptionHeight: CGFloat = 0
    private var cachedLayoutWidth: CGFloat = -1
    private var cachedLayoutHeight: CGFloat = 0
    private var cachedTitleText: String?
    private var cachedTitleWidth: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var isCardHovered = false

    public init(
        item: ToolCallItem,
        theme: Theme,
        index: Int,
        parentCell: AgentNativeMessageCell,
        toolcallColorMode: ToolcallColorMode = .full,
        initiallyExpanded: Bool = false
    ) {
        self.item = item
        self.theme = theme
        self.toolcallColorMode = toolcallColorMode
        self.isExpanded = initiallyExpanded
        super.init(frame: .zero)
        setup(index: index, parentCell: parentCell)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var hasExpandableContent: Bool {
        hasExpandableContent(for: item)
    }

    private func hasExpandableContent(for item: ToolCallItem) -> Bool {
        if item.oldContent != nil || item.newContent != nil { return true }
        if item.shortToolName == "Run" { return true }
        if let cmd = item.command, !cmd.isEmpty { return true }
        if let out = item.output, !out.isEmpty { return true }
        if let sum = item.summary, !sum.isEmpty { return true }
        if let desc = item.descriptionText, !desc.isEmpty { return true }
        return false
    }

    private var hasDiffStats: Bool {
        (item.additionsCount ?? 0) > 0 || (item.deletionsCount ?? 0) > 0
    }

    private var shouldShowOpenInEditorButton: Bool {
        hasExpandableContent && !hasDiffStats
    }

    private func updateOpenInEditorButtonVisibility() {
        openInEditorButton.isHidden = !isCardHovered || !shouldShowOpenInEditorButton
    }

    private func updateCardHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let isInside = bounds.contains(point)
        guard isCardHovered != isInside else { return }
        isCardHovered = isInside
        updateOpenInEditorButtonVisibility()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateCardHover(for: event)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateCardHover(for: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCardHover(for: event)
    }

    public func canUpdateInPlace(with newItem: ToolCallItem) -> Bool {
        if item.id == newItem.id { return true }
        return item.toolName == newItem.toolName &&
            item.path == newItem.path &&
            item.command == newItem.command
    }

    public func update(item newItem: ToolCallItem, theme newTheme: Theme) {
        let titleChanged = item.displayTitle != newItem.displayTitle
        let (bgCol, fgCol, symbolName) = actionColorsAndSymbol(for: newItem.shortToolName)
        item = newItem
        theme = newTheme

        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        cachedDescriptionHeightWidth = -1
        cachedDescriptionHeight = 0
        cachedDetailHeightWidth = -1
        cachedDetailHeight = 0
        cachedDetailAttributedString = nil
        if titleChanged {
            cachedTitleText = nil
            cachedTitleWidth = 0
        }

        virtualizedDetailView?.removeFromSuperview()
        virtualizedDetailView = nil

        // Action badge update
        applyActionAppearance(background: bgCol, foreground: fgCol)
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        actionIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        actionTextLabel.stringValue = newItem.shortToolName

        titleLabel.stringValue = newItem.displayTitle
        titleLabel.textColor = NSColor(cgColor: newTheme.foreground.cgColor) ?? .textColor

        if let description = newItem.descriptionText, !description.isEmpty {
            descriptionLabel.stringValue = description
        } else {
            descriptionLabel.stringValue = ""
        }

        // Diff stats (+ / -)
        if newItem.additionsCount != nil || newItem.deletionsCount != nil {
            let statsAttr = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

            if let adds = newItem.additionsCount, adds > 0 {
                statsAttr.append(NSAttributedString(string: "+\(adds)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemGreen : neutralToolColor
                ]))
            }
            if let dels = newItem.deletionsCount, dels > 0 {
                if statsAttr.length > 0 {
                    statsAttr.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                statsAttr.append(NSAttributedString(string: "-\(dels)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemRed : neutralToolColor
                ]))
            }

            if statsAttr.length > 0 {
                diffStatsButton.badgeLabel.attributedStringValue = statsAttr
                diffStatsButton.isHidden = false
                if diffStatsButton.superview == nil {
                    headerContainer.addSubview(diffStatsButton)
                }
            } else {
                diffStatsButton.isHidden = true
                diffStatsButton.removeFromSuperview()
            }
        } else {
            diffStatsButton.isHidden = true
            diffStatsButton.removeFromSuperview()
        }

        if let progressIndicator = headerContainer.subviews.compactMap({ $0 as? NSProgressIndicator }).first {
            progressIndicator.isHidden = newItem.status != .running
            if newItem.status == .running {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
        }
        if newItem.status == .failed {
            errorLabel.stringValue = "✕"
            if errorLabel.superview == nil {
                headerContainer.addSubview(errorLabel)
            }
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        if hasExpandableContent {
            let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            chevronImageView.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(chevConfig)
            chevronImageView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.8) ?? .secondaryLabelColor
            chevronImageView.imageScaling = .scaleProportionallyDown
            if chevronImageView.superview == nil {
                headerContainer.addSubview(chevronImageView)
            }
            if shouldShowOpenInEditorButton, openInEditorButton.superview == nil {
                headerContainer.addSubview(openInEditorButton)
            } else if !shouldShowOpenInEditorButton {
                openInEditorButton.removeFromSuperview()
            }
            updateOpenInEditorButtonVisibility()
        } else {
            chevronImageView.removeFromSuperview()
            openInEditorButton.removeFromSuperview()
        }

        applyCardAppearance(foreground: fgCol, isRunning: newItem.status == .running)
    }

    private func setup(index: Int, parentCell: AgentNativeMessageCell) {
        // Action badge (pill with SF Symbol + text)
        let (bgCol, fgCol, symbolName) = actionColorsAndSymbol(for: item.shortToolName)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        applyCardAppearance(foreground: fgCol, isRunning: item.status == .running)

        // Header Container
        headerContainer.wantsLayer = true
        addSubview(headerContainer)

        actionPillView.wantsLayer = true
        applyActionAppearance(background: bgCol, foreground: fgCol)
        actionPillView.layer?.cornerRadius = 6

        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        actionIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        actionIconView.imageScaling = .scaleProportionallyDown
        actionPillView.addSubview(actionIconView)

        actionTextLabel.stringValue = item.shortToolName
        actionTextLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        actionTextLabel.usesSingleLineMode = true
        actionTextLabel.lineBreakMode = .byClipping
        actionTextLabel.isBezeled = false
        actionTextLabel.drawsBackground = false
        actionTextLabel.isEditable = false
        actionTextLabel.isSelectable = false
        actionPillView.addSubview(actionTextLabel)

        headerContainer.addSubview(actionPillView)

        // Title
        titleLabel.stringValue = item.displayTitle
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.truncatesLastVisibleLine = true
        headerContainer.addSubview(titleLabel)

        // Diff stats (+ / -)
        if item.additionsCount != nil || item.deletionsCount != nil {
            let statsAttr = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

            if let adds = item.additionsCount, adds > 0 {
                statsAttr.append(NSAttributedString(string: "+\(adds)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemGreen : neutralToolColor
                ]))
            }
            if let dels = item.deletionsCount, dels > 0 {
                if statsAttr.length > 0 {
                    statsAttr.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                statsAttr.append(NSAttributedString(string: "-\(dels)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemRed : neutralToolColor
                ]))
            }

            if statsAttr.length > 0 {
                diffStatsButton.badgeLabel.attributedStringValue = statsAttr
                diffStatsButton.isHidden = false
                headerContainer.addSubview(diffStatsButton)
            }
        }

        // Status indicator: spinner when running, ✕ when failed, none when completed
        switch item.status {
        case .running:
            progressIndicator.style = .spinning
            progressIndicator.controlSize = .small
            progressIndicator.startAnimation(nil)
            headerContainer.addSubview(progressIndicator)
        case .failed:
            errorLabel.stringValue = "✕"
            errorLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            errorLabel.textColor = isFullColorMode ? .systemRed : neutralToolColor
            errorLabel.isBezeled = false
            errorLabel.drawsBackground = false
            errorLabel.isEditable = false
            errorLabel.isSelectable = false
            headerContainer.addSubview(errorLabel)
        case .completed:
            break
        }

        // Chevron
        if hasExpandableContent {
            let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            chevronImageView.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(chevConfig)
            chevronImageView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.8) ?? .secondaryLabelColor
            chevronImageView.imageScaling = .scaleProportionallyDown
            headerContainer.addSubview(chevronImageView)
        }

        // Clickable header button
        headerButton.isBordered = false
        headerButton.title = ""
        headerButton.target = self
        headerButton.action = #selector(headerClicked)
        headerContainer.addSubview(headerButton)

        // Open the complete tool buffer in the main Review editor.
        if shouldShowOpenInEditorButton {
            openInEditorButton.isBordered = false
            openInEditorButton.title = ""
            openInEditorButton.imagePosition = .imageOnly
            openInEditorButton.image = NSImage(
                systemSymbolName: "arrow.left",
                accessibilityDescription: "Open in editor"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            openInEditorButton.contentTintColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
                .withAlphaComponent(0.7)
            openInEditorButton.imageScaling = .scaleProportionallyDown
            openInEditorButton.target = self
            openInEditorButton.action = #selector(openInEditorClicked)
            openInEditorButton.toolTip = "Open in editor"
            headerContainer.addSubview(openInEditorButton)
            openInEditorButton.isHidden = true
        }

        // Clickable diff stats button
        diffStatsButton.isBordered = false
        diffStatsButton.title = ""
        diffStatsButton.target = self
        diffStatsButton.action = #selector(diffStatsClicked)
        diffStatsButton.toolTip = "Review this file in MultiBuffer"
        headerContainer.addSubview(diffStatsButton)

        // Description
        if let desc = item.descriptionText, !desc.isEmpty {
            descriptionLabel.stringValue = desc
            descriptionLabel.font = NSFont.systemFont(ofSize: 11)
            descriptionLabel.textColor = NSColor(cgColor: theme.foreground.cgColor)?.withAlphaComponent(0.85) ?? .textColor
            addSubview(descriptionLabel)
        } else if let summary = item.summary, !summary.isEmpty, !hasExpandableContent {
            descriptionLabel.stringValue = summary
            descriptionLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            descriptionLabel.textColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
            addSubview(descriptionLabel)
        }

        // Detail Container & ScrollView
        if hasExpandableContent {
            detailContainer.wantsLayer = true
            // Keep the expanded output on the toolcall surface. A second
            // filled rounded container made the card look double-framed.
            detailContainer.layer?.backgroundColor = NSColor.clear.cgColor
            detailContainer.layer?.cornerRadius = 8
            detailContainer.layer?.borderWidth = 0
            detailContainer.layer?.borderColor = NSColor.clear.cgColor
            detailContainer.layer?.masksToBounds = true
            detailContainer.isHidden = !isExpanded
            detailContainer.alphaValue = isExpanded ? 1 : 0

            detailScrollView.hasVerticalScroller = true
            detailScrollView.hasHorizontalScroller = false
            detailScrollView.autohidesScrollers = false
            detailScrollView.scrollerStyle = .overlay
            detailScrollView.drawsBackground = false
            detailScrollView.borderType = .noBorder

            detailTextView.parentCell = parentCell
            detailTextView.cellId = parentCell.message.id
            detailTextView.tvKey = "tool_detail_\(index)"
            detailTextView.isEditable = false
            detailTextView.isVerticallyResizable = true
            detailTextView.isHorizontallyResizable = false
            detailTextView.autoresizingMask = [.width]
            detailTextView.textContainer?.widthTracksTextView = true
            detailTextView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
            detailTextView.textContainerInset = NSSize(width: 4, height: 4)

            detailScrollView.documentView = detailTextView
            detailContainer.addSubview(detailScrollView)
            addSubview(detailContainer)

            if isExpanded {
                installVirtualizedDetailView()
            }
        }
    }

    @objc private func headerClicked() {
        guard hasExpandableContent else { return }
        isExpanded.toggle()
        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        if isExpanded {
            installVirtualizedDetailView()
        }
        let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
        chevronImageView.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(chevConfig)
        onToggle?()
    }

    @objc private func diffStatsClicked() {
        guard let summary = item.createEditedFilesSummary() else { return }
        onReview?(summary)
    }

    @objc private func openInEditorClicked() {
        let content = virtualizedDetailContent()
        guard !content.lines.isEmpty else { return }

        let path = item.path ?? "agent/\(item.shortToolName.lowercased())-\(item.id.prefix(8)).txt"

        let summary = AgentEditedFilesSummary(
            files: [AgentEditedFileItem(path: path, additions: 0, deletions: 0)],
            rawTextData: Data(content.lines.joined(separator: "\n").utf8),
            contentMode: .text
        )
        onReview?(summary)
    }

    private func installVirtualizedDetailView() {
        guard virtualizedDetailView == nil else { return }

        let content = virtualizedDetailContent()
        let lines = content.lines
        let buffer = Buffer(
            filePath: item.path ?? item.displayTitle,
            lines: lines,
            language: Buffer.detectLanguage(for: item.path ?? item.displayTitle),
            baselineLines: content.hunk == nil ? [] : nil,
            startLineNumber: 1,
            diskFileLineCount: lines.count
        )
        let multiBuffer = MultiBuffer()
        multiBuffer.setContentMode(content.hunk == nil ? .text : .diff)
        multiBuffer.addBuffer(buffer)
        multiBuffer.addExcerpt(Excerpt(
            bufferId: buffer.id,
            filePath: buffer.filePath,
            fileStatus: .modified,
            bufferRange: 0..<max(1, buffer.lineCount),
            hunk: content.hunk,
            isFileStart: true
        ))

        let displayMap = DisplayMap(
            multiBuffer: multiBuffer,
            reviewManager: ReviewManager()
        )
        let editor = CustomMultiBufferEditorView(displayMap: displayMap, theme: displayTheme)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 8
        editor.layer?.masksToBounds = true
        editor.contentCornerRadius = 8
        editor.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        editor.isEditable = false
        editor.ignoreEdits = true
        editor.invalidateLayout()

        detailScrollView.isHidden = true
        detailContainer.addSubview(editor)
        virtualizedDetailView = editor
    }

    private func virtualizedDetailContent() -> (lines: [String], hunk: DiffHunk?) {
        if let new = item.newContent, let old = item.oldContent {
            let oLines = old.components(separatedBy: "\n")
            let nLines = new.components(separatedBy: "\n")
            let diff = LineDiffEngine.shared.diffLines(oldLines: oLines, newLines: nLines)
            let changedDiff = diff.filter { $0.kind != .unchanged }
            if !changedDiff.isEmpty {
                let adds = changedDiff.filter { $0.kind == .added }.count
                let dels = changedDiff.filter { $0.kind == .deleted }.count
                let hunk = DiffHunk(
                    oldRange: 1..<(dels + 1),
                    newRange: 1..<(adds + 1),
                    header: "@@ -1,\(dels) +1,\(adds) @@",
                    lines: changedDiff,
                    status: .modified
                )
                return (changedDiff.filter { $0.kind != .deleted }.map(\.text), hunk)
            }
        }

        var diffLines: [DiffLine] = []

        if let old = item.oldContent, !old.isEmpty {
            diffLines.append(contentsOf: old
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(10_000)
                .enumerated()
                .map { index, line in
                    DiffLine(kind: .deleted, text: String(line), oldLineNumber: index + 1)
                })
        }
        if let new = item.newContent, !new.isEmpty {
            diffLines.append(contentsOf: new
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(10_000)
                .enumerated()
                .map { index, line in
                    DiffLine(kind: .added, text: String(line), newLineNumber: index + 1)
                })
        }

        if !diffLines.isEmpty {
            let oldCount = diffLines.reduce(into: 0) { count, line in
                if line.kind == .deleted { count += 1 }
            }
            let newCount = diffLines.reduce(into: 0) { count, line in
                if line.kind != .deleted { count += 1 }
            }
            let hunk = DiffHunk(
                oldRange: 1..<(oldCount + 1),
                newRange: 1..<(newCount + 1),
                header: "@@ -1,\(oldCount) +1,\(newCount) @@",
                lines: diffLines,
                status: .modified
            )
            return (
                diffLines.filter { $0.kind != .deleted }.map(\.text),
                hunk
            )
        }

        var lines: [String] = []
        if lines.isEmpty {
            if let command = item.command, !command.isEmpty {
                lines.append("$ \(command)")
            } else if item.shortToolName == "Run", !item.displayTitle.isEmpty {
                lines.append("$ \(item.displayTitle)")
            }
            if let output = item.output, !output.isEmpty {
                let boundedOutput = output.count > 200_000
                    ? String(output.prefix(180_000)) + "\n\n... output truncated ...\n"
                    : output
                lines.append(contentsOf: boundedOutput.components(separatedBy: "\n"))
            }
        }

        if lines.isEmpty, let summary = item.summary, !summary.isEmpty {
            lines = summary.components(separatedBy: "\n")
        }
        if lines.isEmpty, let description = item.descriptionText, !description.isEmpty {
            lines = description.components(separatedBy: "\n")
        }
        return (lines.isEmpty ? [""] : lines, nil)
    }

    private func actionColorsAndSymbol(for name: String) -> (bg: NSColor, fg: NSColor, symbol: String) {
        if toolcallColorMode == .none {
            let symbol: String
            switch name {
            case "Edit": symbol = "pencil"
            case "Create": symbol = "doc.badge.plus"
            case "Run": symbol = "terminal"
            case "Search": symbol = "magnifyingglass"
            case "Read": symbol = "doc.text"
            default: symbol = "gearshape"
            }
            return (.clear, neutralToolColor, symbol)
        }

        switch name {
        case "Edit":
            return (NSColor.systemOrange.withAlphaComponent(0.24), .systemOrange, "pencil")
        case "Create":
            return (NSColor.systemBlue.withAlphaComponent(0.24), .systemBlue, "doc.badge.plus")
        case "Run":
            return (NSColor.systemPurple.withAlphaComponent(0.24), .systemPurple, "terminal")
        case "Search":
            return (NSColor.systemYellow.withAlphaComponent(0.24), .systemYellow, "magnifyingglass")
        case "Read":
            return (NSColor.systemTeal.withAlphaComponent(0.24), .systemTeal, "doc.text")
        default:
            return (NSColor.systemGray.withAlphaComponent(0.24), .systemGray, "gearshape")
        }
    }

    private var neutralToolColor: NSColor {
        NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
    }

    private var isFullColorMode: Bool {
        toolcallColorMode == .full
    }

    private var shouldColorEditStats: Bool {
        isFullColorMode || item.shortToolName == "Edit"
    }

    private var showsBadgeBackground: Bool {
        toolcallColorMode == .badge || toolcallColorMode == .full
    }

    private var showsActionIconColor: Bool {
        toolcallColorMode != .none
    }

    private var showsActionLabelColor: Bool {
        toolcallColorMode == .label || showsBadgeBackground
    }

    private func applyActionAppearance(background: NSColor, foreground: NSColor) {
        actionPillView.layer?.backgroundColor = showsBadgeBackground
            ? background.cgColor
            : NSColor.clear.cgColor
        actionIconView.contentTintColor = showsActionIconColor ? foreground : neutralToolColor
        actionTextLabel.textColor = showsActionLabelColor ? foreground : neutralToolColor
    }

    private var displayTheme: Theme {
        isFullColorMode ? theme : theme.monochromeForAgent
    }

    private func applyCardAppearance(foreground: NSColor, isRunning: Bool) {
        layer?.removeAnimation(forKey: "pulseBg")
        layer?.removeAnimation(forKey: "pulseBorder")

        if !isFullColorMode {
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            return
        }

        // Temporarily keep toolcall cards borderless in every color mode.
        layer?.borderWidth = 0
        if isRunning {
            layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
            layer?.borderColor = foreground.withAlphaComponent(0.26).cgColor

            let pulseBg = CABasicAnimation(keyPath: "backgroundColor")
            pulseBg.fromValue = foreground.withAlphaComponent(0.07).cgColor
            pulseBg.toValue = foreground.withAlphaComponent(0.22).cgColor
            pulseBg.duration = 0.95
            pulseBg.autoreverses = true
            pulseBg.repeatCount = .infinity
            pulseBg.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulseBg, forKey: "pulseBg")

            let pulseBorder = CABasicAnimation(keyPath: "borderColor")
            pulseBorder.fromValue = foreground.withAlphaComponent(0.24).cgColor
            pulseBorder.toValue = foreground.withAlphaComponent(0.60).cgColor
            pulseBorder.duration = 0.95
            pulseBorder.autoreverses = true
            pulseBorder.repeatCount = .infinity
            pulseBorder.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulseBorder, forKey: "pulseBorder")
        } else {
            layer?.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
            layer?.borderColor = foreground.withAlphaComponent(0.32).cgColor
        }
    }

    private func detailAttributedString() -> NSAttributedString {
        if let cachedDetailAttributedString {
            return cachedDetailAttributedString
        }

        let result = NSMutableAttributedString()
        let language = Buffer.detectLanguage(for: item.path ?? item.displayTitle)
        let renderTheme = displayTheme
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5

        if item.oldContent != nil || item.newContent != nil {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            // Diff semantics stay visible in every toolcall color mode.
            let redColor = NSColor.systemRed.withAlphaComponent(0.92)
            let redBg = NSColor.systemRed.withAlphaComponent(0.12)
            let greenColor = NSColor.systemGreen.withAlphaComponent(0.92)
            let greenBg = NSColor.systemGreen.withAlphaComponent(0.12)

            if let old = item.oldContent, !old.isEmpty {
                let lines = old.components(separatedBy: "\n")
                let displayLines = lines.prefix(350)
                for (lIdx, line) in displayLines.enumerated() {
                    let prefix = NSAttributedString(string: "- ", attributes: [
                        .font: font,
                        .foregroundColor: redColor,
                        .backgroundColor: redBg,
                        .paragraphStyle: style
                    ])
                    let highlighted = lIdx < 150 ? SyntaxHighlighter.shared.highlight(line: line, language: language, font: font, theme: renderTheme) : NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: redColor])
                    let lineAttr = NSMutableAttributedString(attributedString: highlighted)
                    let range = NSRange(location: 0, length: lineAttr.length)
                    lineAttr.addAttribute(NSAttributedString.Key.backgroundColor, value: redBg, range: range)
                    lineAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: range)

                    result.append(prefix)
                    result.append(lineAttr)
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .backgroundColor: redBg,
                        .paragraphStyle: style
                    ]))
                }
                if lines.count > 350 {
                    result.append(NSAttributedString(string: "... (\(lines.count - 350) more deleted lines truncated)\n", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
            if let new = item.newContent, !new.isEmpty {
                let lines = new.components(separatedBy: "\n")
                let displayLines = lines.prefix(350)
                for (lIdx, line) in displayLines.enumerated() {
                    let prefix = NSAttributedString(string: "+ ", attributes: [
                        .font: font,
                        .foregroundColor: greenColor,
                        .backgroundColor: greenBg,
                        .paragraphStyle: style
                    ])
                    let highlighted = lIdx < 150 ? SyntaxHighlighter.shared.highlight(line: line, language: language, font: font, theme: renderTheme) : NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: greenColor])
                    let lineAttr = NSMutableAttributedString(attributedString: highlighted)
                    let range = NSRange(location: 0, length: lineAttr.length)
                    lineAttr.addAttribute(NSAttributedString.Key.backgroundColor, value: greenBg, range: range)
                    lineAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: range)

                    result.append(prefix)
                    result.append(lineAttr)
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .backgroundColor: greenBg,
                        .paragraphStyle: style
                    ]))
                }
                if lines.count > 350 {
                    result.append(NSAttributedString(string: "... (\(lines.count - 350) more added lines truncated)\n", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        } else if item.shortToolName == "Run" || (item.command != nil && !(item.command?.isEmpty ?? true)) || (item.output != nil && !(item.output?.isEmpty ?? true)) {
            let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            let cmdFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let textColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor

            let cmd = item.command ?? (item.shortToolName == "Run" ? item.displayTitle : nil)
            if let cmd, !cmd.isEmpty {
                let prefix = NSAttributedString(string: "$ ", attributes: [
                    .font: cmdFont,
                    .foregroundColor: renderTheme.keyword,
                    .paragraphStyle: style
                ])
                let cmdHighlighted = SyntaxHighlighter.shared.highlight(line: cmd, language: "shell", font: cmdFont, theme: renderTheme)
                result.append(prefix)
                result.append(cmdHighlighted)
                if let out = item.output, !out.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: cmdFont,
                        .paragraphStyle: style
                    ]))
                }
            }
            if let out = item.output, !out.isEmpty {
                // Tool output is diagnostic content; rendering an unbounded
                // command result can monopolize the main thread during a
                // toggle. Keep enough head and tail to inspect the result
                // while bounding TextKit work.
                let maxChars = 24_000
                let safeOut: String
                if out.count > maxChars {
                    let head = out.prefix(16_000)
                    let tail = out.suffix(6_000)
                    safeOut = "\(head)\n\n... [\(out.count - 22_000) characters truncated for performance] ...\n\n\(tail)"
                } else {
                    safeOut = out
                }
                result.append(NSAttributedString(string: safeOut, attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: style
                ]))
            }
        } else if let sum = item.summary, !sum.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let textColor = NSColor(cgColor: theme.foreground.cgColor)?.withAlphaComponent(0.88) ?? .textColor
            result.append(NSAttributedString(string: sum, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ]))
        }

        cachedDetailAttributedString = result
        return result
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        if abs(cachedLayoutWidth - width) < 0.5, cachedLayoutHeight > 0 {
            return cachedLayoutHeight
        }

        let padding: CGFloat = 8
        let innerWidth = max(50, width - (padding * 2))
        var currentY: CGFloat = 32

        if !descriptionLabel.stringValue.isEmpty {
            let descHeight = descriptionHeight(width: innerWidth)
            currentY += descHeight + 6
        }

        if hasExpandableContent && isExpanded {
            let detailTVWidth = max(40, innerWidth - 12)
            let maxDetailHeight: CGFloat = 320
            let rawHeight = detailContentHeight(width: detailTVWidth)
            let containerHeight = min(maxDetailHeight, rawHeight + 12)
            currentY += containerHeight + 8
        } else {
            currentY += 2
        }

        cachedLayoutWidth = width
        cachedLayoutHeight = currentY
        return currentY
    }

    private func descriptionHeight(width: CGFloat) -> CGFloat {
        if abs(cachedDescriptionHeightWidth - width) < 0.5, cachedDescriptionHeight > 0 {
            return cachedDescriptionHeight
        }
        let measured = measureAttributedTextHeight(descriptionLabel.attributedStringValue, maxWidth: width)
        cachedDescriptionHeightWidth = width
        cachedDescriptionHeight = measured
        return measured
    }

    public func applyLayout(width: CGFloat, animated: Bool) {
        let padding: CGFloat = 8
        let innerWidth = max(50, width - (padding * 2))

        // 1. Header Layout (Unified coordinate system with height 22 and center line at y = 11.0)
        headerContainer.frame = NSRect(x: padding, y: 6, width: innerWidth, height: 22)
        headerButton.frame = NSRect(x: 0, y: 0, width: innerWidth, height: 22)

        // Action badge size with icon + text (height 20, y: 1.0 -> center = 11.0)
        let textSize = actionTextLabel.intrinsicContentSize
        let iconWidth: CGFloat = 12
        let pillPaddingH: CGFloat = 6
        let pillSpacing: CGFloat = 4
        // Keep the action badge intact when the command title or right-side
        // metadata gets tight. The title is the expendable part of the row.
        let actionTextWidth = max(ceil(textSize.width) + 2, 28)
        let pillWidth = max(58, pillPaddingH + iconWidth + pillSpacing + actionTextWidth + pillPaddingH)
        let pillHeight: CGFloat = 20
        actionPillView.frame = NSRect(x: 0, y: 1.0, width: pillWidth, height: pillHeight)
        actionIconView.frame = NSRect(x: pillPaddingH, y: 4.0, width: iconWidth, height: 12)
        actionTextLabel.frame = NSRect(x: pillPaddingH + iconWidth + pillSpacing, y: 4.0, width: actionTextWidth + 2, height: 14)

        let leftX = pillWidth + 8

        // Right side metadata items (right-to-left layout to guarantee zero overlaps)
        var rightX = innerWidth
        if hasExpandableContent {
            rightX -= 10
            chevronImageView.frame = NSRect(x: rightX, y: 6.0, width: 10, height: 10)
            rightX -= 6

            if shouldShowOpenInEditorButton {
                rightX -= 18
                openInEditorButton.frame = NSRect(x: rightX, y: 3.0, width: 16, height: 16)
                openInEditorButton.isHidden = !isCardHovered
                rightX -= 6
            } else {
                openInEditorButton.isHidden = true
            }
        } else {
            openInEditorButton.isHidden = true
        }

        if item.status == .running {
            rightX -= 14
            progressIndicator.frame = NSRect(x: rightX, y: 4.0, width: 14, height: 14)
            rightX -= 6
        } else if item.status == .failed {
            rightX -= 14
            errorLabel.frame = NSRect(x: rightX, y: 3.5, width: 14, height: 15)
            rightX -= 6
        }

        // Diff stats (+ / -) (height 18, y: 2.0 -> center = 11.0)
        if diffStatsButton.badgeLabel.attributedStringValue.length > 0 {
            let dsSize = diffStatsButton.badgeLabel.attributedStringValue.size()
            let dsWidth = ceil(dsSize.width) + 12
            rightX -= dsWidth
            diffStatsButton.frame = NSRect(x: rightX, y: 2.0, width: dsWidth, height: 18)
            diffStatsButton.isHidden = false
            if diffStatsButton.superview == nil {
                headerContainer.addSubview(diffStatsButton)
            }
            rightX -= 6
        } else {
            diffStatsButton.isHidden = true
        }

        // Title (takes remaining space between leftX and rightX, height 14, y: 4.0 -> center = 11.0)
        let availableTitleWidth = max(20, rightX - leftX)
        let titleText = titleLabel.attributedStringValue.string
        let measuredTitleWidth: CGFloat
        if cachedTitleText == titleText {
            measuredTitleWidth = cachedTitleWidth
        } else {
            measuredTitleWidth = titleLabel.attributedStringValue.size().width
            cachedTitleText = titleText
            cachedTitleWidth = measuredTitleWidth
        }
        let titleWidth = min(measuredTitleWidth + 4, availableTitleWidth)
        titleLabel.frame = NSRect(x: leftX, y: 4.0, width: titleWidth, height: 14)

        var currentY: CGFloat = 32

        // 2. Description
        if !descriptionLabel.stringValue.isEmpty {
            let descHeight = descriptionHeight(width: innerWidth)
            let descFrame = NSRect(x: padding, y: currentY, width: innerWidth, height: descHeight)
            if animated {
                descriptionLabel.animator().frame = descFrame
            } else {
                descriptionLabel.frame = descFrame
            }
            currentY += descHeight + 6
        }

        // 3. Detail Container & ScrollView
        if hasExpandableContent {
            let detailContentWidth = max(40, innerWidth - 12)
            let maxDetailHeight: CGFloat = 320
            let rawHeight = isExpanded ? detailContentHeight(width: detailContentWidth) : 0
            let containerHeight = min(maxDetailHeight, rawHeight + 12)
            let detailFrame = NSRect(x: padding, y: currentY, width: innerWidth, height: containerHeight)
            let contentFrame = NSRect(x: 6, y: 6, width: detailContentWidth, height: max(10, containerHeight - 12))

            if virtualizedDetailView == nil, isExpanded {
                installVirtualizedDetailView()
            }

            if isExpanded {
                detailContainer.isHidden = false

                // The custom editor owns a small viewport and virtualizes the
                // lines it draws. Keep its frame at the viewport size; its
                // internal scrollOffsetY handles the full output height.
                virtualizedDetailView?.isHidden = false
                virtualizedDetailView?.frame = contentFrame
                virtualizedDetailView?.needsDisplay = true

                if animated {
                    detailContainer.animator().frame = detailFrame
                    detailContainer.animator().alphaValue = 1
                } else {
                    detailContainer.frame = detailFrame
                    detailContainer.alphaValue = 1
                }
                currentY += containerHeight + 8
            } else {
                if animated {
                    detailContainer.animator().alphaValue = 0
                } else {
                    detailContainer.alphaValue = 0
                    detailContainer.isHidden = true
                }
                detailContainer.frame = NSRect(x: padding, y: currentY, width: innerWidth, height: 0)
                virtualizedDetailView?.isHidden = true
                currentY += 2
            }
        }
    }

    public func finishAnimation() {
        if !isExpanded && hasExpandableContent {
            detailContainer.isHidden = true
        }
    }

    private func detailContentHeight(width: CGFloat) -> CGFloat {
        if abs(cachedDetailHeightWidth - width) < 0.5 {
            return cachedDetailHeight
        }

        if let virtualizedDetailView {
            let measured = max(18, virtualizedDetailView.totalDocumentHeight)
            cachedDetailHeightWidth = width
            cachedDetailHeight = measured
            return measured
        }

        // Measure using the same TextKit layout that renders the card. The
        // previous boundingRect call created a second layout pass over the
        // complete tool output on every expansion.
        let measured: CGFloat
        if let textContainer = detailTextView.textContainer,
           let layoutManager = detailTextView.layoutManager {
            textContainer.containerSize = NSSize(
                width: max(1, width),
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            measured = max(
                18,
                ceil(usedHeight + detailTextView.textContainerInset.height * 2)
            )
        } else {
            measured = measureAttributedTextHeight(detailTextView.attributedString(), maxWidth: width)
        }
        cachedDetailHeightWidth = width
        cachedDetailHeight = measured
        return measured
    }
}

public final class AgentHoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    public var defaultBackgroundColor: NSColor = NSColor.clear {
        didSet {
            if !isHovered {
                layer?.backgroundColor = defaultBackgroundColor.cgColor
            }
        }
    }
    public var hoverBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.15) {
        didSet {
            if isHovered {
                layer?.backgroundColor = hoverBackgroundColor.cgColor
            }
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
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = defaultBackgroundColor.cgColor
        contentTintColor = .white
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = hoverBackgroundColor.cgColor
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = defaultBackgroundColor.cgColor
        }
    }
}

public final class AgentNativeEditedFileRowView: AgentNativeFlippedView {
    private let filenameLabel = AgentNativeStaticTextField(labelWithString: "")
    private let directoryLabel = AgentNativeStaticTextField(labelWithString: "")
    private let statsLabel = AgentNativeStaticTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(filenameLabel)
        addSubview(directoryLabel)
        addSubview(statsLabel)
        filenameLabel.lineBreakMode = .byClipping
        directoryLabel.lineBreakMode = .byTruncatingMiddle
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(file: AgentEditedFileItem, theme: Theme) {
        filenameLabel.attributedStringValue = NSAttributedString(
            string: file.filename,
            attributes: [
                .foregroundColor: theme.foreground,
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
            ]
        )

        let dirString = file.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirString.isEmpty {
            directoryLabel.isHidden = false
            directoryLabel.attributedStringValue = NSAttributedString(
                string: dirString,
                attributes: [
                    .foregroundColor: theme.gutterForeground.withAlphaComponent(0.85),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                ]
            )
        } else {
            directoryLabel.isHidden = true
            directoryLabel.stringValue = ""
        }

        let statsAttr = NSMutableAttributedString()
        if file.additions > 0 {
            statsAttr.append(NSAttributedString(
                string: "+\(file.additions)",
                attributes: [
                    .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                ]
            ))
        }
        if file.deletions > 0 {
            if file.additions > 0 {
                statsAttr.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                    ]
                ))
            }
            statsAttr.append(NSAttributedString(
                string: "-\(file.deletions)",
                attributes: [
                    .foregroundColor: NSColor.systemRed.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                ]
            ))
        }
        statsLabel.attributedStringValue = statsAttr
    }

    public func applyLayout(width: CGFloat) {
        let statsSize = statsLabel.sizeThatFits(NSSize(width: 120, height: 18))
        let statsWidth = statsSize.width
        statsLabel.frame = NSRect(x: max(0, width - statsWidth), y: 0, width: statsWidth, height: 18)

        let availableTextWidth = max(0, width - statsWidth - 8)
        let nameSize = filenameLabel.sizeThatFits(NSSize(width: availableTextWidth, height: 18))
        let nameWidth = min(availableTextWidth, nameSize.width)
        filenameLabel.frame = NSRect(x: 0, y: 0, width: nameWidth, height: 18)

        if !directoryLabel.isHidden {
            let dirX = nameWidth + 8
            let dirWidth = max(0, availableTextWidth - dirX)
            directoryLabel.frame = NSRect(x: dirX, y: 0, width: dirWidth, height: 18)
        }
    }
}

public final class AgentNativeEditedFilesCardView: AgentNativeFlippedView {
    public private(set) var summary: AgentEditedFilesSummary
    private var theme: Theme
    private var accentColor: Color
    private var disableAgentColors: Bool
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?

    private let titleLabel = AgentNativeStaticTextField(labelWithString: "")
    private let statsLabel = AgentNativeStaticTextField(labelWithString: "")
    private let restoreButton = AgentHoverButton(frame: .zero)
    private let revertButton = AgentHoverButton(frame: .zero)
    private let reviewButton = AgentHoverButton(frame: .zero)
    private let divider = NSBox()
    private var fileRowViews: [AgentNativeEditedFileRowView] = []

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color = .accentColor,
        disableAgentColors: Bool = false
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.disableAgentColors = disableAgentColors
        super.init(frame: .zero)
        setup()
        configure(summary: summary, theme: theme, accentColor: accentColor, disableAgentColors: disableAgentColors)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)

        statsLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        addSubview(statsLabel)

        restoreButton.target = self
        restoreButton.action = #selector(handleRestoreClicked)
        addSubview(restoreButton)

        revertButton.target = self
        revertButton.action = #selector(handleRevertClicked)
        addSubview(revertButton)

        reviewButton.target = self
        reviewButton.action = #selector(handleReviewClicked)
        addSubview(reviewButton)

        divider.boxType = .separator
        addSubview(divider)
    }

    @objc private func handleRestoreClicked() {
        onRestore?(summary)
    }

    @objc private func handleRevertClicked() {
        onRevert?(summary)
    }

    @objc private func handleReviewClicked() {
        onReview?(summary)
    }

    public func configure(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color,
        disableAgentColors: Bool
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.disableAgentColors = disableAgentColors

        let nsAccent = NSColor(accentColor)
        let fgColor = summary.isReverted ? theme.gutterForeground : theme.foreground
        titleLabel.textColor = fgColor
        titleLabel.stringValue = summary.displayTitle

        layer?.backgroundColor = nsAccent.withAlphaComponent(0.08).cgColor
        layer?.borderColor = nsAccent.withAlphaComponent(0.18).cgColor

        if summary.isReverted {
            restoreButton.isHidden = false
            revertButton.isHidden = true
            reviewButton.isHidden = true
            statsLabel.isHidden = true

            restoreButton.imagePosition = .noImage
            restoreButton.image = nil
            restoreButton.contentTintColor = NSColor.systemBlue
            restoreButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            restoreButton.hoverBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.20)
            restoreButton.attributedTitle = NSAttributedString(
                string: "Redo",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.systemBlue
                ]
            )
        } else {
            restoreButton.isHidden = true
            revertButton.isHidden = false
            reviewButton.isHidden = false
            statsLabel.isHidden = false

            revertButton.imagePosition = .noImage
            revertButton.image = nil
            revertButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.9)
            revertButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            revertButton.hoverBackgroundColor = NSColor.systemRed.withAlphaComponent(0.20)
            revertButton.attributedTitle = NSAttributedString(
                string: "Undo",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.systemRed.withAlphaComponent(0.9)
                ]
            )

            reviewButton.imagePosition = .noImage
            reviewButton.image = nil
            reviewButton.contentTintColor = fgColor
            reviewButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            reviewButton.hoverBackgroundColor = NSColor.white.withAlphaComponent(0.15)
            reviewButton.attributedTitle = NSAttributedString(
                string: "Review",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: fgColor.withAlphaComponent(0.95)
                ]
            )

            let statsAttr = NSMutableAttributedString()
            if summary.totalAdditions > 0 {
                statsAttr.append(NSAttributedString(
                    string: "+\(summary.totalAdditions)",
                    attributes: [.foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95), .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                ))
            }
            if summary.totalDeletions > 0 {
                if summary.totalAdditions > 0 {
                    statsAttr.append(NSAttributedString(
                        string: " ",
                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                    ))
                }
                statsAttr.append(NSAttributedString(
                    string: "-\(summary.totalDeletions)",
                    attributes: [.foregroundColor: NSColor.systemRed.withAlphaComponent(0.95), .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                ))
            }
            statsLabel.attributedStringValue = statsAttr
        }

        while fileRowViews.count < summary.files.count {
            let row = AgentNativeEditedFileRowView()
            addSubview(row)
            fileRowViews.append(row)
        }
        while fileRowViews.count > summary.files.count {
            let row = fileRowViews.removeLast()
            row.removeFromSuperview()
        }

        for (index, file) in summary.files.enumerated() {
            fileRowViews[index].configure(file: file, theme: theme)
        }
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        let headerHeight: CGFloat = 26
        let dividerHeight: CGFloat = 6
        let fileRowsHeight: CGFloat = CGFloat(summary.files.count) * 20
        return 10 + headerHeight + dividerHeight + fileRowsHeight + 8
    }

    public func applyLayout(width: CGFloat) {
        let padding: CGFloat = 10
        let contentWidth = max(50, width - (padding * 2))
        var currentY: CGFloat = padding

        let titleSize = titleLabel.sizeThatFits(NSSize(width: contentWidth * 0.5, height: 22))
        titleLabel.frame = NSRect(x: padding, y: currentY + 1, width: titleSize.width, height: 20)

        var rightX = width - padding

        if !summary.isReverted {
            if summary.totalAdditions > 0 || summary.totalDeletions > 0 {
                let statsSize = statsLabel.sizeThatFits(NSSize(width: 120, height: 20))
                let statsWidth = statsSize.width
                statsLabel.frame = NSRect(x: width - padding - statsWidth, y: currentY + 1, width: statsWidth, height: 20)
                rightX -= (statsWidth + 10)
            }

            let reviewWidth: CGFloat = 58
            rightX -= reviewWidth
            reviewButton.frame = NSRect(x: rightX, y: currentY, width: reviewWidth, height: 22)
            rightX -= 6

            let revertWidth: CGFloat = 52
            rightX -= revertWidth
            revertButton.frame = NSRect(x: rightX, y: currentY, width: revertWidth, height: 22)
        } else {
            let restoreWidth: CGFloat = 52
            rightX -= restoreWidth
            restoreButton.frame = NSRect(x: rightX, y: currentY, width: restoreWidth, height: 22)
        }

        currentY += 26

        divider.frame = NSRect(x: padding, y: currentY, width: contentWidth, height: 1)
        currentY += 5

        for row in fileRowViews {
            row.frame = NSRect(x: padding, y: currentY, width: contentWidth, height: 18)
            row.applyLayout(width: contentWidth)
            currentY += 20
        }
    }
}

public final class AgentNativeMessageCell: NSView {
    public override var isFlipped: Bool { true }

    // Temporary performance switch: keep the code-block implementation in
    // place, but omit these heavy expandable cards from the chat output while
    // the scrolling path is being tuned. Flip back to `true` to restore them.
    private static let showsCodeBlocks = false
    // Keep the colored expandable tool cards implemented, but use compact
    // text-only rows in the current chat while scroll performance is tuned.
    private static let usesSimpleToolCalls = false

    public var onToggleThought: (() -> Void)?
    public var onToggleTool: (() -> Void)?
    public var onToggleUserExpand: (() -> Void)?
    public var onReview: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentNativeEditedFilesCardView)?.onReview = onReview
        }
    }
    public var onRevert: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentNativeEditedFilesCardView)?.onRevert = onRevert
        }
    }
    public var onRestore: ((AgentEditedFilesSummary) -> Void)? {
        didSet {
            (editedFilesCardView as? AgentNativeEditedFilesCardView)?.onRestore = onRestore
        }
    }
    public private(set) var message: AgentMessage
    private var theme: Theme
    private var accentColor: Color
    private var toolcallColorMode: ToolcallColorMode
    private let nativeTextSelectionEnabled: Bool
    private var isThoughtExpanded: Bool = false
    private var isUserTextExpanded: Bool = false
    private let maxUserTextCollapsedHeight: CGFloat = 160
    private let userTextCollapseThreshold: CGFloat = 190
    private var expandedToolIds: Set<String> = []
    private var toolCallIDs: [String] = []
    private var inlineThoughtViews: [AgentNativeThoughtBlockView] = []
    private var markdownViewsByTextPart: [[NSView]] = []
    private var orderedAssistantViews: [NSView] = []
    private var editedFilesCardView: NSView?

    public var enclosingDocumentView: AgentNativeChatDocumentView? {
        var v = superview
        while v != nil {
            if let doc = v as? AgentNativeChatDocumentView { return doc }
            v = v?.superview
        }
        return nil
    }

    private var hasInlineThoughtParts: Bool {
        message.orderedParts.contains { part in
            if case .thought(let str) = part {
                return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    private var hasCompactTopThought: Bool {
        guard !hasInlineThoughtParts,
              let thought = message.thought else { return false }
        return isCompactThought(thought)
    }

    private func isCompactThought(_ thought: String) -> Bool {
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed.count <= 120 &&
            trimmed.split(whereSeparator: { $0.isNewline }).count <= 2
    }

    // Subviews
    private let userBubbleView = AgentNativeFlippedView()
    private let userTextView = AgentSelectableTextView()
    private let userExpandButton = AgentHoverButton()
    private var userImageViews: [NSButton] = []
    public var onPreviewImages: (([AgentImageAttachment], Int) -> Void)?
    private let thoughtHeaderButton = NSButton()
    private let thoughtTextView = AgentSelectableTextView()
    private var toolCallViews: [NSView] = []
    private var pendingToolCallAppearances: [NSView] = []
    private var pendingEditedFilesCardAppearance: NSView?
    private var pendingUserMessageAppearance = false
    private var markdownViews: [NSView] = []
    private var streamingRenderedContent: String = ""
    private var cachedLayoutWidth: CGFloat = -1
    private var cachedLayoutHeight: CGFloat = 0
    private var layoutNeedsApplication = true
    private let maxCodeBlockHeight: CGFloat = 320
    private struct TextMeasurementKey: Hashable {
        let view: ObjectIdentifier
        let width: Int
    }
    private var cachedTextHeights: [TextMeasurementKey: CGFloat] = [:]

    private struct StreamingFadeChunk {
        let range: NSRange
        let startTime: TimeInterval
    }
    private var streamingFadeChunks: [StreamingFadeChunk] = []
    private var streamingFadeTimer: Timer?
    private var thoughtFadeChunks: [StreamingFadeChunk] = []
    private var thoughtFadeTimer: Timer?
    private var previousStreamedLength: Int = 0

    deinit {
        streamingFadeTimer?.invalidate()
        streamingFadeTimer = nil
        thoughtFadeTimer?.invalidate()
        thoughtFadeTimer = nil
    }

    fileprivate var needsLayoutApplication: Bool {
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

    private func setup() {
        wantsLayer = true
        userBubbleView.wantsLayer = true
        userBubbleView.layer?.cornerRadius = 13
        userBubbleView.layer?.borderWidth = 0.0
        userBubbleView.layer?.masksToBounds = false
        userBubbleView.layer?.shadowColor = NSColor(srgbRed: 0.05, green: 0.42, blue: 0.96, alpha: 0.50).cgColor
        userBubbleView.layer?.shadowOpacity = 0.55
        userBubbleView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        userBubbleView.layer?.shadowRadius = 8

        userTextView.parentCell = self
        userTextView.wantsLayer = true
        userTextView.layer?.masksToBounds = true
        userBubbleView.addSubview(userTextView)
        userBubbleView.addSubview(userExpandButton)
        addSubview(userBubbleView)

        userExpandButton.target = self
        userExpandButton.action = #selector(toggleUserTextExpand)
        updateUserExpandButtonAppearance()

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
        addSubview(thoughtTextView)
    }

    @objc private func toggleUserTextExpand() {
        isUserTextExpanded.toggle()
        updateUserExpandButtonAppearance()
        invalidateLayoutCache()
        onToggleUserExpand?()
    }

    private func updateUserExpandButtonAppearance() {
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
        let attr = NSAttributedString(
            string: title + " ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                .paragraphStyle: style
            ]
        )
        userExpandButton.attributedTitle = attr
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
            userBubbleView.layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.46, blue: 0.96, alpha: 0.94).cgColor
            userBubbleView.layer?.borderWidth = 0.0
            userBubbleView.layer?.borderColor = nil

            userImageViews.forEach { $0.removeFromSuperview() }
            userImageViews.removeAll()

            for (index, img) in message.images.enumerated() {
                if let nsImage = NSImage(data: img.data) {
                    let btn = NSButton()
                    btn.image = nsImage
                    btn.imageScaling = .scaleProportionallyUpOrDown
                    btn.isBordered = false
                    btn.wantsLayer = true
                    btn.layer?.cornerRadius = 8
                    btn.layer?.masksToBounds = true
                    btn.layer?.borderWidth = 1
                    btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
                    btn.target = self
                    btn.action = #selector(handleImageClick(_:))
                    btn.tag = index
                    userBubbleView.addSubview(btn)
                    userImageViews.append(btn)
                }
            }

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.alignment = .left
            let attr = NSAttributedString(string: message.content, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style
            ])
            userTextView.textStorage?.setAttributedString(attr)
            userTextView.isHidden = message.content.isEmpty
            clearAssistantViews()
        } else {
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
                    thoughtTextView.isHidden = isCompact ? false : !isThoughtExpanded
                    thoughtTextView.alphaValue = isCompact || isThoughtExpanded ? 1 : 0
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
                }
            }

            // 2. Tool calls. Keep unchanged cards alive while a running tool
            // streams status/output updates. Rebuilding the whole list here
            // made every tool event recreate all headers and nested views.
            if toolCallsChanged || themeChanged || accentChanged || displayModeChanged || toolCallViews.isEmpty {
                updateToolCallViews(
                    previousItems: previousMessage.toolCalls,
                    newItems: message.toolCalls,
                    styleChanged: themeChanged || displayModeChanged
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
                if let card = editedFilesCardView as? AgentNativeEditedFilesCardView {
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
                    let card = AgentNativeEditedFilesCardView(
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

    private func updateNativeTextSelection() {
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

    private func updateToolCallViews(
        previousItems: [ToolCallItem],
        newItems: [ToolCallItem],
        styleChanged: Bool
    ) {
        let previousIDs = previousItems.map(\.id)
        let canReplaceInPlace = !styleChanged &&
            previousItems.count == newItems.count &&
            zip(previousItems, newItems).allSatisfy { representsSameToolCall($0.0, $0.1) } &&
            toolCallViews.count == newItems.count

        guard canReplaceInPlace else {
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
            return
        }

        for index in newItems.indices where previousItems[index] != newItems[index] {
            if let card = toolCallViews[index] as? AgentNativeToolCardView,
               card.canUpdateInPlace(with: newItems[index]) {
                card.update(item: newItems[index], theme: theme)
                toolCallIDs[index] = newItems[index].id
                continue
            }

            let replacement = makeToolCallView(item: newItems[index], index: index)
            toolCallViews[index].removeFromSuperview()
            addSubview(replacement)
            toolCallViews[index] = replacement
            toolCallIDs[index] = newItems[index].id
        }
    }

    private func representsSameToolCall(_ previous: ToolCallItem, _ current: ToolCallItem) -> Bool {
        if previous.id == current.id { return true }
        return previous.toolName == current.toolName &&
            previous.path == current.path &&
            previous.command == current.command
    }

    fileprivate func prepareUserMessageAppearance() {
        pendingUserMessageAppearance = true
        userBubbleView.alphaValue = 0
    }

    fileprivate func animatePendingAppearances(animated: Bool) {
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

    private func animateStreamingTextUpdate() {
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

    private func animateNewThoughtText(startLocation: Int) {
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

    private func updateThoughtFadeAnimation() {
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

    private func clearAssistantViews() {
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
    }

    private func clearInlineThoughtViews() {
        for view in inlineThoughtViews {
            view.removeFromSuperview()
        }
        inlineThoughtViews.removeAll()
    }

    private func rebuildInlineThoughtViews() {
        let expandedStates = inlineThoughtViews.map(\.isExpanded)
        clearInlineThoughtViews()

        var thoughtIndex = 0
        for part in message.orderedParts {
            guard case .thought(let text) = part else { continue }

            let title = thoughtPanelTitle(text)
            let body = thoughtBodyText(text)
            let isExpandable = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                normalizedThoughtText(body) != normalizedThoughtText(title)
            let thoughtView = AgentNativeThoughtBlockView(
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

    private func thoughtPanelTitle(_ text: String) -> String {
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

    private func thoughtBodyText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return "" }

        return lines
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func normalizedThoughtText(_ text: String) -> String {
        formatThoughtMarkdownString(text, fontSize: 11.5, alpha: 1, lineSpacing: 0)
            .string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildMarkdownViews(content: String, highlightCode: Bool) {
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

    private func rebuildAssistantViewOrder() {
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

    private func updateStreamingTextView(content: String, themeChanged: Bool) {
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

    private func updateStreamingFadeAnimation() {
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

    private func buildAssistantViews() {
        // 1. Thought block
        if let thought = message.thought, !thought.isEmpty {
            let isCompact = isCompactThought(thought)
            thoughtHeaderButton.isHidden = isCompact
            updateThoughtHeaderAppearance()
            thoughtHeaderButton.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.85) ?? NSColor.secondaryLabelColor
            thoughtTextView.isHidden = isCompact ? false : !isThoughtExpanded
            thoughtTextView.alphaValue = isCompact || isThoughtExpanded ? 1 : 0
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

    private func makeToolCallView(item: ToolCallItem, index: Int) -> NSView {
        if Self.usesSimpleToolCalls {
            return AgentNativeSimpleToolCallView(item: item, theme: theme)
        }

        let isExp = expandedToolIds.contains(item.id)
        let card = AgentNativeToolCardView(
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

    @objc private func toggleThought() {
        isThoughtExpanded.toggle()
        updateThoughtHeaderAppearance()
        thoughtTextView.isHidden = !isThoughtExpanded
        thoughtTextView.alphaValue = isThoughtExpanded ? 1 : 0
        invalidateLayoutCache()
        onToggleThought?()
    }

    private func updateThoughtHeaderAppearance() {
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

    fileprivate func animateThoughtVisibility() {
        thoughtTextView.animator().alphaValue = isThoughtExpanded ? 1 : 0
    }

    fileprivate func finishThoughtVisibilityAnimation() {
        if isThoughtExpanded {
            thoughtTextView.isHidden = false
            thoughtTextView.alphaValue = 1
        } else {
            thoughtTextView.alphaValue = 0
            thoughtTextView.isHidden = true
        }
    }

    private func invalidateLayoutCache() {
        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        cachedTextHeights.removeAll(keepingCapacity: true)
        layoutNeedsApplication = true
    }

    private func measuredTextHeight(for view: NSView, attributedString: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = TextMeasurementKey(view: ObjectIdentifier(view), width: Int((width * 2).rounded()))
        if let cached = cachedTextHeights[key] {
            return cached
        }
        let measured: CGFloat
        if let textView = view as? AgentSelectableTextView,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            // Reuse TextKit's incremental layout state. This is especially
            // important for the single plain-text view used during streaming:
            // boundingRect would reflow the entire growing response for every
            // appended chunk.
            textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            measured = max(18, ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2))
        } else {
            measured = measureAttributedTextHeight(attributedString, maxWidth: width)
        }
        cachedTextHeights[key] = measured
        return measured
    }

    private enum AssistantContentSection {
        case richText(NSAttributedString)
        case quote(NSAttributedString)
        case codeBlock(language: String?, code: String)
    }

    private func compileSections(
        from content: String,
        splitRichText: Bool = true
    ) -> [AssistantContentSection] {
        let blocks = AgentMarkdownParser.parse(content)
        var sections: [AssistantContentSection] = []
        let currentRichText = NSMutableAttributedString()
        var currentRichTextBlockCount = 0

        // The legacy custom selection path keeps rich-text layers bounded.
        // The active standard chat can opt into one rich-text view per
        // continuous text part so native selection stays contiguous.
        let maxRichTextBlocksPerSection = splitRichText ? 12 : Int.max
        let maxRichTextCharactersPerSection = splitRichText ? 2_048 : Int.max

        func flushRichText() {
            if currentRichText.length > 0 {
                var s = currentRichText.string
                while s.hasSuffix("\n") {
                    currentRichText.deleteCharacters(in: NSRange(location: currentRichText.length - 1, length: 1))
                    s = currentRichText.string
                }
                if currentRichText.length > 0 {
                    sections.append(.richText(NSAttributedString(attributedString: currentRichText)))
                }
                currentRichText.deleteCharacters(in: NSRange(location: 0, length: currentRichText.length))
            }
            currentRichTextBlockCount = 0
        }

        func finishRichTextBlock() {
            currentRichTextBlockCount += 1
            if currentRichTextBlockCount >= maxRichTextBlocksPerSection ||
                currentRichText.length >= maxRichTextCharactersPerSection {
                flushRichText()
            }
        }

        for block in blocks {
            switch block {
            case .header(let level, let text):
                let font = NSFont.systemFont(ofSize: level == 1 ? 15 : (level == 2 ? 14 : 13.5), weight: .bold)
                let color = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 6
                style.paragraphSpacingBefore = currentRichText.length > 0 ? 10 : 0
                style.alignment = .left
                let attr = NSAttributedString(string: "\(text)\n", attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: style
                ])
                currentRichText.append(attr)
                finishRichTextBlock()

            case .bulletItem(let text):
                let bulletAttr = formatMarkdownString("• \(text)")
                let bulletMutable = NSMutableAttributedString(attributedString: bulletAttr)
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 4
                style.alignment = .left
                bulletMutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: bulletMutable.length))
                currentRichText.append(bulletMutable)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                finishRichTextBlock()

            case .paragraph(let text):
                let paraAttr = formatMarkdownString(text)
                let paraMutable = NSMutableAttributedString(attributedString: paraAttr)
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 8
                style.alignment = .left
                paraMutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paraMutable.length))
                currentRichText.append(paraMutable)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                finishRichTextBlock()

            case .quote(let text):
                if splitRichText {
                    flushRichText()
                    sections.append(.quote(formatMarkdownString(text)))
                } else {
                    let quoteText = formatMarkdownString(text)
                    let quoteMutable = NSMutableAttributedString()
                    quoteMutable.append(NSAttributedString(string: "▎ ", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                        .foregroundColor: NSColor.controlAccentColor
                    ]))
                    quoteMutable.append(quoteText)
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 3
                    style.paragraphSpacing = 4
                    quoteMutable.addAttribute(
                        .paragraphStyle,
                        value: style,
                        range: NSRange(location: 0, length: quoteMutable.length)
                    )
                    currentRichText.append(quoteMutable)
                    currentRichText.append(NSAttributedString(string: "\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 13)
                    ]))
                    finishRichTextBlock()
                }

            case .codeBlock(let lang, let code):
                if Self.showsCodeBlocks {
                    flushRichText()
                    sections.append(.codeBlock(language: lang, code: code))
                }
            }
        }

        flushRichText()
        return sections
    }

    private func createSectionView(section: AssistantContentSection, index: Int, highlightCode: Bool = true) -> NSView {
        switch section {
        case .richText(let attr):
            let tv = AgentSelectableTextView()
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "md_\(index)"
            tv.isSelectable = nativeTextSelectionEnabled
            tv.textStorage?.setAttributedString(attr)
            return tv

        case .quote(let attr):
            let container = AgentNativeFlippedView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(cgColor: theme.gutterBackground.cgColor)?.withAlphaComponent(0.4).cgColor
            container.layer?.cornerRadius = 6

            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            bar.layer?.cornerRadius = 1.5
            bar.frame = NSRect(x: 4, y: 4, width: 3, height: 20)
            container.addSubview(bar)

            let tv = AgentSelectableTextView()
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "quote_\(index)"
            tv.isSelectable = nativeTextSelectionEnabled
            tv.textStorage?.setAttributedString(attr)
            container.addSubview(tv)
            return container

        case .codeBlock(let lang, let code):
            let container = AgentNativeCodeBlockView()
            container.wantsLayer = true
            let codeBg = NSColor(cgColor: theme.gutterBackground.cgColor)?.withAlphaComponent(0.40) ?? NSColor.black.withAlphaComponent(0.10)
            let borderColor = NSColor(cgColor: theme.excerptHeaderBorder.cgColor)?.withAlphaComponent(0.35) ?? NSColor.textColor.withAlphaComponent(0.10)
            let headerBg = NSColor(cgColor: theme.gutterBackground.cgColor)?.withAlphaComponent(0.75) ?? NSColor.black.withAlphaComponent(0.15)
            let labelColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor

            container.layer?.backgroundColor = codeBg.cgColor
            container.layer?.cornerRadius = 8
            container.layer?.borderWidth = 1
            container.layer?.borderColor = borderColor.cgColor

            // Header (top bar)
            let header = container.header
            header.wantsLayer = true
            header.layer?.backgroundColor = headerBg.cgColor
            header.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
            header.setExpanded(false)
            header.onToggle = { [weak self, weak container] in
                guard let self, let container else { return }
                self.invalidateLayoutCache()
                container.codeScrollView.isHidden = !container.isExpanded
                self.onToggleThought?()
            }

            let langLabel = container.header.langLabel
            langLabel.stringValue = lang?.uppercased() ?? "CODE"
            langLabel.isBezeled = false
            langLabel.drawsBackground = false
            langLabel.isEditable = false
            langLabel.isSelectable = false
            langLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            langLabel.textColor = labelColor
            langLabel.frame = NSRect(x: 10, y: 5, width: 150, height: 16)
            header.addSubview(langLabel)

            let toggleButton = header.toggleButton
            toggleButton.isBordered = false
            toggleButton.setButtonType(.momentaryPushIn)
            toggleButton.focusRingType = .none
            toggleButton.target = header
            toggleButton.action = #selector(AgentNativeCodeBlockHeaderView.toggleCodeBlock)
            toggleButton.imagePosition = .imageOnly
            toggleButton.imageScaling = .scaleProportionallyDown
            toggleButton.contentTintColor = labelColor.withAlphaComponent(0.75)
            toggleButton.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
            header.addSubview(toggleButton)

            let copyBtn = container.header.copyBtn
            copyBtn.isBordered = false
            copyBtn.target = self
            copyBtn.action = #selector(copyCodeSnippet(_:))
            copyBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            copyBtn.contentTintColor = labelColor
            copyBtn.attributedTitle = NSAttributedString(string: "Copy", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: labelColor
            ])
            copyBtn.identifier = NSUserInterfaceItemIdentifier(code)
            copyBtn.frame = NSRect(x: 240, y: 4, width: 50, height: 18)
            copyBtn.alphaValue = 0.0 // Shown only on hover over header
            header.addSubview(copyBtn)
            container.addSubview(header)

            // Code with syntax highlighting
            let tv = container.tv
            tv.parentCell = self
            tv.cellId = message.id
            tv.tvKey = "code_\(index)"
            tv.isSelectable = nativeTextSelectionEnabled
            let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            let detectedLang = lang ?? "plaintext"
            let lines = code.components(separatedBy: "\n")
            let attr = NSMutableAttributedString()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2.5
            for (i, line) in lines.enumerated() {
                let highlighted = highlightCode
                    ? SyntaxHighlighter.shared.highlight(line: line, language: detectedLang, font: font, theme: theme)
                    : NSAttributedString(string: line, attributes: [
                        .font: font,
                        .foregroundColor: labelColor
                    ])
                let lineAttr = NSMutableAttributedString(attributedString: highlighted)
                lineAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: NSRange(location: 0, length: lineAttr.length))
                attr.append(lineAttr)
                if i < lines.count - 1 {
                    attr.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
                }
            }
            tv.textStorage?.setAttributedString(attr)

            // Keep large outputs inside the message card. The outer chat scroll
            // should remain responsible for messages, while this nested scroll
            // view handles long code blocks independently.
            let codeScrollView = container.codeScrollView
            codeScrollView.hasVerticalScroller = true
            codeScrollView.hasHorizontalScroller = false
            codeScrollView.autohidesScrollers = true
            codeScrollView.scrollerStyle = .overlay
            codeScrollView.drawsBackground = false
            codeScrollView.borderType = .noBorder
            codeScrollView.contentView = FlippedClipView()
            codeScrollView.isHidden = true

            tv.isVerticallyResizable = true
            tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]
            codeScrollView.documentView = tv
            container.addSubview(codeScrollView)

            return container
        }
    }

    @objc private func handleImageClick(_ sender: NSButton) {
        onPreviewImages?(message.images, sender.tag)
    }

    @objc private func copyCodeSnippet(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        sender.attributedTitle = NSAttributedString(string: "Copied!", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak sender] in
            guard let self, let sender else { return }
            let color = NSColor(cgColor: self.theme.gutterForeground.cgColor) ?? .secondaryLabelColor
            sender.attributedTitle = NSAttributedString(string: "Copy", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: color
            ])
        }
    }

    private func formatMarkdownString(_ raw: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return formatInlineMarkdownString(
            raw,
            font: NSFont.systemFont(ofSize: 13),
            color: NSColor(cgColor: theme.foreground.cgColor) ?? .textColor,
            paragraphStyle: style
        )
    }

    private func formatThoughtMarkdownString(
        _ raw: String,
        fontSize: CGFloat,
        alpha: CGFloat,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return formatInlineMarkdownString(
            raw,
            font: NSFont.systemFont(ofSize: fontSize),
            color: (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
                .withAlphaComponent(alpha),
            paragraphStyle: style
        )
    }

    private func formatInlineMarkdownString(
        _ raw: String,
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        guard let parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: raw, attributes: baseAttributes)
        }

        let text = String(parsed.characters)
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)

        // AttributedString removes markdown delimiters and stores emphasis as
        // inline presentation intents. Convert those intents to AppKit fonts
        // so both message text and thoughts render without literal ** markers.
        for run in parsed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let prefix = parsed.characters[parsed.startIndex..<run.range.lowerBound]
            let location = String(prefix).utf16.count
            let length = String(parsed.characters[run.range]).utf16.count
            guard length > 0 else { continue }

            let runFont: NSFont
            if intent.rawValue & 4 != 0 {
                runFont = NSFont.monospacedSystemFont(ofSize: max(11.5, font.pointSize - 0.5), weight: .regular)
                let codeBg = (NSColor(cgColor: theme.gutterBackground.cgColor) ?? NSColor.windowBackgroundColor).withAlphaComponent(0.65)
                result.addAttribute(.backgroundColor, value: codeBg, range: NSRange(location: location, length: length))
            } else if intent.rawValue & 2 != 0 {
                runFont = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
            } else {
                runFont = font
            }
            result.addAttribute(.font, value: runFont, range: NSRange(location: location, length: length))
        }

        return result
    }

    private func assistantViewHeight(_ view: NSView, contentWidth: CGFloat) -> CGFloat {
        guard !view.isHidden, view.alphaValue > 0.01 else { return 0 }
        if let thought = view as? AgentNativeThoughtBlockView {
            return thought.measureHeight(width: contentWidth)
        }
        if let simple = view as? AgentNativeSimpleToolCallView {
            return simple.measureHeight(width: contentWidth)
        }
        if let card = view as? AgentNativeToolCardView {
            return card.measureHeight(width: contentWidth)
        }
        if let card = view as? AgentNativeEditedFilesCardView {
            return card.measureHeight(width: contentWidth)
        }
        if let tv = view as? AgentSelectableTextView {
            return measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: contentWidth)
        }
        if let codeBlock = view as? AgentNativeCodeBlockView {
            let codeHeight = measuredTextHeight(
                for: codeBlock.tv,
                attributedString: codeBlock.tv.attributedString(),
                width: contentWidth - 20
            )
            let visibleCodeHeight = codeBlock.isExpanded ? min(maxCodeBlockHeight, codeHeight) : 0
            return codeBlock.isExpanded ? 26 + 6 + visibleCodeHeight + 10 : 26
        }
        if view.subviews.count >= 2 {
            let quoteTV = view.subviews[1] as? AgentSelectableTextView
            let qHeight = measuredTextHeight(
                for: quoteTV ?? view,
                attributedString: quoteTV?.attributedString() ?? NSAttributedString(),
                width: contentWidth - 24
            )
            return qHeight + 12
        }
        return 28
    }

    @discardableResult
    private func applyAssistantViewLayout(_ view: NSView, width: CGFloat, currentY: CGFloat, animated: Bool) -> CGFloat {
        guard !view.isHidden, view.alphaValue > 0.01 else { return 0 }
        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))
        let height = assistantViewHeight(view, contentWidth: contentWidth)

        if let thought = view as? AgentNativeThoughtBlockView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { thought.animator().frame = frame } else { thought.frame = frame }
            thought.applyLayout(width: contentWidth, animated: animated)
        } else if let simple = view as? AgentNativeSimpleToolCallView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { simple.animator().frame = frame } else { simple.frame = frame }
            simple.applyLayout(width: contentWidth)
        } else if let card = view as? AgentNativeToolCardView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth, animated: animated)
        } else if let card = view as? AgentNativeEditedFilesCardView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth)
        } else if let tv = view as? AgentSelectableTextView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { tv.animator().frame = frame } else { tv.frame = frame }
            if tv.layer?.mask != nil {
                tv.layer?.mask = nil
            }
        } else if let codeBlock = view as? AgentNativeCodeBlockView {
            let codeHeight = measuredTextHeight(
                for: codeBlock.tv,
                attributedString: codeBlock.tv.attributedString(),
                width: contentWidth - 20
            )
            let headerHeight: CGFloat = 26
            let visibleCodeHeight = codeBlock.isExpanded ? min(maxCodeBlockHeight, codeHeight) : 0
            let totalCodeHeight = codeBlock.isExpanded ? headerHeight + 6 + visibleCodeHeight + 10 : headerHeight
            let blockFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: totalCodeHeight)
            let codeScrollFrame = NSRect(x: 10, y: headerHeight + 6, width: contentWidth - 20, height: visibleCodeHeight)
            let codeDocumentFrame = NSRect(x: 0, y: 0, width: contentWidth - 20, height: codeHeight)
            codeBlock.tv.textContainer?.containerSize = NSSize(width: contentWidth - 20, height: .greatestFiniteMagnitude)
            codeBlock.codeScrollView.isHidden = !codeBlock.isExpanded
            if animated {
                codeBlock.animator().frame = blockFrame
                codeBlock.header.animator().frame = NSRect(x: 0, y: 0, width: contentWidth, height: headerHeight)
                codeBlock.codeScrollView.animator().frame = codeScrollFrame
                codeBlock.tv.animator().frame = codeDocumentFrame
            } else {
                codeBlock.frame = blockFrame
                codeBlock.header.frame = NSRect(x: 0, y: 0, width: contentWidth, height: headerHeight)
                codeBlock.codeScrollView.frame = codeScrollFrame
                codeBlock.tv.frame = codeDocumentFrame
            }
        } else if view.subviews.count >= 2 {
            let bar = view.subviews[0]
            let quoteTV = view.subviews[1] as? AgentSelectableTextView
            let qHeight = measuredTextHeight(
                for: quoteTV ?? view,
                attributedString: quoteTV?.attributedString() ?? NSAttributedString(),
                width: contentWidth - 24
            )
            let totalHeight = qHeight + 12
            let blockFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: totalHeight)
            let barFrame = NSRect(x: 4, y: 6, width: 3, height: max(16, totalHeight - 12))
            let quoteFrame = NSRect(x: 14, y: 6, width: contentWidth - 24, height: qHeight)
            if animated {
                view.animator().frame = blockFrame
                bar.animator().frame = barFrame
                quoteTV?.animator().frame = quoteFrame
            } else {
                view.frame = blockFrame
                bar.frame = barFrame
                quoteTV?.frame = quoteFrame
            }
        }

        return height + (view is AgentNativeThoughtBlockView ? 2 : 6)
    }

    public func measureHeight(for width: CGFloat) -> CGFloat {
        if abs(cachedLayoutWidth - width) < 0.5, cachedLayoutHeight > 0 {
            return cachedLayoutHeight
        }

        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))
        let height: CGFloat

        if message.role == .user {
            let maxBubbleWidth = min(contentWidth * 0.85, 480)
            let hasImages = !userImageViews.isEmpty
            let imagesHeight: CGFloat = hasImages ? (userImageViews.count == 1 ? 140 : 54) : 0
            let hasText = !message.content.isEmpty
            let fullTextHeight = hasText ? measuredTextHeight(
                for: userTextView,
                attributedString: userTextView.attributedString(),
                width: maxBubbleWidth - 28
            ) : 0

            let isCollapsible = fullTextHeight > userTextCollapseThreshold
            let displayedTextHeight = (isCollapsible && !isUserTextExpanded) ? maxUserTextCollapsedHeight : fullTextHeight
            let buttonHeight: CGFloat = isCollapsible ? 22 : 0
            let buttonSpacing: CGFloat = isCollapsible ? 4 : 0

            let bubbleHeight = 9 + imagesHeight + (hasImages && hasText ? 8 : 0) + displayedTextHeight + (isCollapsible ? (buttonSpacing + buttonHeight) : 0) + 9
            height = bubbleHeight + 8
        } else {
            var currentY: CGFloat = 4

            if !thoughtHeaderButton.isHidden {
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: contentWidth - 10
                    )
                    currentY += h + 8
                }
            } else if hasCompactTopThought {
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: contentWidth
                )
                currentY += h + 8
            }

            for view in orderedAssistantViews {
                if isEditedFilesCardView(view) {
                    currentY += 8
                }
                currentY += assistantViewHeight(view, contentWidth: contentWidth) + 6
            }

            height = currentY + 4
        }

        cachedLayoutWidth = width
        cachedLayoutHeight = height
        return height
    }

    public func applyLayout(for width: CGFloat, animated: Bool) {
        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))

        if message.role == .user {
            let maxBubbleWidth = min(contentWidth * 0.85, 480)
            let hasImages = !userImageViews.isEmpty
            let imagesHeight: CGFloat = hasImages ? (userImageViews.count == 1 ? 140 : 54) : 0
            let imagesWidth: CGFloat = hasImages ? (userImageViews.count == 1 ? 180 : min(maxBubbleWidth - 28, CGFloat(userImageViews.count) * 54 + CGFloat(max(0, userImageViews.count - 1)) * 6)) : 0
            let hasText = !message.content.isEmpty
            let fullTextHeight = hasText ? measuredTextHeight(
                for: userTextView,
                attributedString: userTextView.attributedString(),
                width: maxBubbleWidth - 28
            ) : 0

            let isCollapsible = fullTextHeight > userTextCollapseThreshold
            let displayedTextHeight = (isCollapsible && !isUserTextExpanded) ? maxUserTextCollapsedHeight : fullTextHeight
            let buttonHeight: CGFloat = isCollapsible ? 22 : 0
            let buttonSpacing: CGFloat = isCollapsible ? 4 : 0

            let textWidth = hasText ? measureTextWidth(userTextView.attributedString().string, font: NSFont.systemFont(ofSize: 13)) : 0
            let minWidthForButton: CGFloat = isCollapsible ? 110 : 0
            let bubbleWidth = min(maxBubbleWidth, max(max(textWidth, imagesWidth), minWidthForButton) + 28)
            let bubbleHeight = 9 + imagesHeight + (hasImages && hasText ? 8 : 0) + displayedTextHeight + (isCollapsible ? (buttonSpacing + buttonHeight) : 0) + 9

            let bubbleFrame = NSRect(
                x: width - horizontalPadding - bubbleWidth,
                y: 4,
                width: bubbleWidth,
                height: bubbleHeight
            )
            if animated {
                userBubbleView.animator().frame = bubbleFrame
            } else {
                userBubbleView.frame = bubbleFrame
            }

            var currentInsideY: CGFloat = 9
            if hasImages {
                if userImageViews.count == 1, let singleBtn = userImageViews.first {
                    let imgW = min(bubbleWidth - 28, 180)
                    let imgFrame = NSRect(x: 14, y: currentInsideY, width: imgW, height: 140)
                    if animated { singleBtn.animator().frame = imgFrame } else { singleBtn.frame = imgFrame }
                } else {
                    for (i, btn) in userImageViews.enumerated() {
                        let btnFrame = NSRect(x: 14 + CGFloat(i) * 60, y: currentInsideY, width: 54, height: 54)
                        if animated { btn.animator().frame = btnFrame } else { btn.frame = btnFrame }
                    }
                }
                currentInsideY += imagesHeight + (hasText ? 8 : 0)
            }

            if hasText {
                let tvFrame = NSRect(x: 14, y: currentInsideY, width: bubbleWidth - 28, height: displayedTextHeight)
                userTextView.isHidden = false
                if animated {
                    userTextView.animator().frame = tvFrame
                } else {
                    userTextView.frame = tvFrame
                }

                if isCollapsible {
                    userExpandButton.isHidden = false
                    updateUserExpandButtonAppearance()

                    let btnWidth: CGFloat = 92
                    let btnFrame = NSRect(
                        x: bubbleWidth - 14 - btnWidth,
                        y: currentInsideY + displayedTextHeight + buttonSpacing,
                        width: btnWidth,
                        height: buttonHeight
                    )
                    if animated {
                        userExpandButton.animator().frame = btnFrame
                    } else {
                        userExpandButton.frame = btnFrame
                    }
                } else {
                    userExpandButton.isHidden = true
                }
            } else {
                userTextView.isHidden = true
                userExpandButton.isHidden = true
            }
        } else {
            var currentY: CGFloat = 4

            if !thoughtHeaderButton.isHidden {
                let thFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: 20)
                if animated {
                    thoughtHeaderButton.animator().frame = thFrame
                } else {
                    thoughtHeaderButton.frame = thFrame
                }
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: contentWidth - 10
                    )
                    let tvFrame = NSRect(x: horizontalPadding + 8, y: currentY, width: contentWidth - 10, height: h)
                    if animated {
                        thoughtTextView.animator().frame = tvFrame
                    } else {
                        thoughtTextView.frame = tvFrame
                    }
                    currentY += h + 8
                }
            } else if hasCompactTopThought {
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: contentWidth
                )
                let tvFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: h)
                thoughtTextView.isHidden = false
                if animated {
                    thoughtTextView.animator().frame = tvFrame
                } else {
                    thoughtTextView.frame = tvFrame
                }
                currentY += h + 8
            }

            for view in orderedAssistantViews {
                if isEditedFilesCardView(view) {
                    currentY += 8
                }
                currentY += applyAssistantViewLayout(
                    view,
                    width: width,
                    currentY: currentY,
                    animated: animated
                )
            }
        }

        layoutNeedsApplication = false
    }

    private func isEditedFilesCardView(_ view: NSView) -> Bool {
        guard let editedFilesCardView else { return false }
        return editedFilesCardView === view
    }

    public func finishVisibilityAnimation() {
        finishThoughtVisibilityAnimation()
        for toolView in toolCallViews {
            (toolView as? AgentNativeToolCardView)?.finishAnimation()
        }
    }

    public func layout(for width: CGFloat) -> CGFloat {
        let widthChanged = abs(cachedLayoutWidth - width) >= 0.5
        let h = measureHeight(for: width)
        // `layoutContent` visits every cell when the document height changes,
        // but most cells are immutable during streaming. Their cached height
        // is still needed for the stack calculation; applying every frame
        // again would remeasure and reposition all of their subviews.
        if layoutNeedsApplication || widthChanged {
            applyLayout(for: width, animated: false)
        }
        return h
    }

    // MARK: - Custom Selection Calculation

    public struct CellSelectionResult {
        public var rectsInDoc: [NSRect]
        public var text: String
    }

    func allSelectableTextViews() -> [AgentSelectableTextView] {
        if message.role == .user {
            return [userTextView]
        }
        var views: [AgentSelectableTextView] = []
        if isThoughtExpanded || hasCompactTopThought {
            views.append(thoughtTextView)
        }
        for item in orderedAssistantViews {
            if let thought = item as? AgentNativeThoughtBlockView {
                if thought.isExpanded {
                    views.append(thought.textView)
                }
            } else if item is AgentNativeToolCardView {
                // Tool details use their own virtualized editor and handle
                // local selection/copy directly inside that viewport.
            } else if let tv = item as? AgentSelectableTextView {
                views.append(tv)
            } else if let codeBlock = item as? AgentNativeCodeBlockView {
                if codeBlock.isExpanded {
                    views.append(codeBlock.tv)
                }
            } else if let tv = item.subviews.first(where: { $0 is AgentSelectableTextView }) as? AgentSelectableTextView {
                views.append(tv)
            } else if item.subviews.count > 1, let tv = item.subviews[1] as? AgentSelectableTextView {
                views.append(tv)
            }
        }
        return views
    }

    public func getSelection(
        startPointInDoc: NSPoint,
        endPointInDoc: NSPoint,
        minY: CGFloat,
        maxY: CGFloat,
        granularity: AgentChatSelectionGranularity
    ) -> CellSelectionResult {
        var rects: [NSRect] = []
        var textParts: [String] = []

        guard let docView = enclosingDocumentView else {
            return CellSelectionResult(rectsInDoc: [], text: "")
        }

        let cellFrame = self.frame
        guard cellFrame.maxY >= minY && cellFrame.minY <= maxY else {
            return CellSelectionResult(rectsInDoc: [], text: "")
        }

        let textViews = allSelectableTextViews()
        for tv in textViews {
            let tvFrameInDoc = tv.convert(tv.bounds, to: docView)
            guard tvFrameInDoc.maxY >= minY && tvFrameInDoc.minY <= maxY else { continue }

            let text = tv.string
            guard !text.isEmpty else { continue }

            let isStartInThisTV = startPointInDoc.y >= tvFrameInDoc.minY - 2 && startPointInDoc.y <= tvFrameInDoc.maxY + 2
            let isEndInThisTV = endPointInDoc.y >= tvFrameInDoc.minY - 2 && endPointInDoc.y <= tvFrameInDoc.maxY + 2

            let nsRange: NSRange

            if isStartInThisTV && isEndInThisTV {
                let p1 = tv.convert(startPointInDoc, from: docView)
                let p2 = tv.convert(endPointInDoc, from: docView)
                let idx1 = tv.characterIndexForInsertion(at: p1)
                let idx2 = tv.characterIndexForInsertion(at: p2)
                let startIdx = min(idx1, idx2)
                let endIdx = max(idx1, idx2)
                let rawRange = NSRange(location: startIdx, length: max(0, endIdx - startIdx))
                nsRange = expandChatSelectionRange(rawRange, in: text, granularity: granularity)
            } else if isStartInThisTV {
                let p1 = tv.convert(startPointInDoc, from: docView)
                let idx1 = tv.characterIndexForInsertion(at: p1)
                let rawRange = NSRange(location: min(idx1, text.count), length: max(0, text.count - idx1))
                nsRange = expandChatSelectionRange(rawRange, in: text, granularity: granularity)
            } else if isEndInThisTV {
                let p2 = tv.convert(endPointInDoc, from: docView)
                let idx2 = tv.characterIndexForInsertion(at: p2)
                let rawRange = NSRange(location: 0, length: min(idx2, text.count))
                nsRange = expandChatSelectionRange(rawRange, in: text, granularity: granularity)
            } else if tvFrameInDoc.minY >= startPointInDoc.y && tvFrameInDoc.maxY <= endPointInDoc.y {
                nsRange = NSRange(location: 0, length: text.count)
            } else if tvFrameInDoc.minY <= startPointInDoc.y && tvFrameInDoc.maxY >= endPointInDoc.y {
                // TV completely wraps the selection range vertically
                let p1 = tv.convert(startPointInDoc, from: docView)
                let p2 = tv.convert(endPointInDoc, from: docView)
                let idx1 = tv.characterIndexForInsertion(at: p1)
                let idx2 = tv.characterIndexForInsertion(at: p2)
                let startIdx = min(idx1, idx2)
                let endIdx = max(idx1, idx2)
                let rawRange = NSRange(location: startIdx, length: max(0, endIdx - startIdx))
                nsRange = expandChatSelectionRange(rawRange, in: text, granularity: granularity)
            } else {
                nsRange = NSRange(location: 0, length: text.count)
            }

            if nsRange.length > 0 {
                if let sub = (text as NSString?)?.substring(with: nsRange) {
                    textParts.append(sub)
                }
                if let lm = tv.layoutManager, let tc = tv.textContainer {
                    let glyphRange = lm.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
                    lm.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: glyphRange, in: tc) { rect, _ in
                        let docR = tv.convert(rect, to: docView)
                        rects.append(docR)
                    }
                } else {
                    rects.append(tvFrameInDoc)
                }
            }
        }

        return CellSelectionResult(rectsInDoc: rects, text: textParts.joined(separator: "\n"))
    }

    public func getAllSelection() -> CellSelectionResult {
        var rects: [NSRect] = []
        var textParts: [String] = []

        guard let docView = enclosingDocumentView else {
            return CellSelectionResult(rectsInDoc: [], text: "")
        }

        let textViews = allSelectableTextViews()
        for tv in textViews {
            let tvFrameInDoc = tv.convert(tv.bounds, to: docView)
            rects.append(tvFrameInDoc)
            if !tv.string.isEmpty {
                textParts.append(tv.string)
            }
        }

        return CellSelectionResult(rectsInDoc: rects, text: textParts.joined(separator: "\n"))
    }
}

fileprivate func measureAttributedTextHeight(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
    guard attr.length > 0 else { return 18 }
    let rect = attr.boundingRect(
        with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return max(18, ceil(rect.height))
}

fileprivate func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    return ceil(attr.size().width)
}

private extension Theme {
    var monochromeForAgent: Theme {
        func gray(_ color: NSColor) -> NSColor {
            color.usingColorSpace(.deviceGray) ?? color
        }

        return Theme(
            id: "\(id)-agent-monochrome",
            name: "\(name) Agent Monochrome",
            isDark: isDark,
            background: gray(background),
            gutterBackground: gray(gutterBackground),
            currentLineBackground: gray(currentLineBackground),
            selectionBackground: gray(selectionBackground),
            excerptHeaderBackground: gray(excerptHeaderBackground),
            excerptHeaderBorder: gray(excerptHeaderBorder),
            foreground: gray(foreground),
            gutterForeground: gray(gutterForeground),
            gutterActiveForeground: gray(gutterActiveForeground),
            foldPlaceholderForeground: gray(foldPlaceholderForeground),
            keyword: gray(keyword),
            type: gray(type),
            function: gray(function),
            string: gray(string),
            number: gray(number),
            comment: gray(comment),
            property: gray(property),
            operator: gray(`operator`),
            punctuation: gray(punctuation),
            // Diff colors are semantic, so preserve them even when syntax
            // highlighting is switched to the monochrome agent palette.
            diffAddedGutter: diffAddedGutter,
            diffAddedBackground: diffAddedBackground,
            diffAddedWordHighlight: diffAddedWordHighlight,
            diffDeletedGutter: diffDeletedGutter,
            diffDeletedBackground: diffDeletedBackground,
            diffDeletedWordHighlight: diffDeletedWordHighlight,
            diffModifiedGutter: diffModifiedGutter
        )
    }
}
