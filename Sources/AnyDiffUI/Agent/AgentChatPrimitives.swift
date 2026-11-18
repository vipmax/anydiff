import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public class AgentFlippedView: NSView {
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

/// Read-only labels in the chat must never advertise text editing.
public final class AgentStaticTextField: NSTextField {
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
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public override func updateTrackingAreas() {
        // Static read-only labels never need NSControl/NSCell mouse tracking.
        // Suppressing super avoids expensive -[NSView _interactiveBounds] walks
        // across every tool card label during scroll.
    }

    public override func resetCursorRects() {
        discardCursorRects()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Non-interactive image view that never participates in cursor-rect or tracking-area passes.
public final class AgentStaticImageView: NSImageView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = false
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public override func updateTrackingAreas() {}

    public override func resetCursorRects() {
        discardCursorRects()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

public final class AgentDividerView: AgentFlippedView {
    public let lineView = NSView()

    public init(theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        lineView.wantsLayer = true
        let borderColor = NSColor(cgColor: theme.excerptHeaderBorder.cgColor)?.withAlphaComponent(0.35) ?? NSColor.separatorColor
        lineView.layer?.backgroundColor = borderColor.cgColor
        addSubview(lineView)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public func applyLayout(width: CGFloat) {
        let h: CGFloat = 16
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: h)
        lineView.frame = NSRect(x: 0, y: (h - 1) / 2, width: width, height: 1)
    }
}

public final class AgentInlineImageHoverBarView: NSView {
    public var attachment: AgentImageAttachment?
    public var imageOrdinal: Int = 0
    public var onCopy: ((AgentImageAttachment?, Int) -> Void)?
    public var onDelete: ((Int) -> Void)?

    private let copyButton = NSButton()
    private let deleteButton = NSButton()
    private let showsDelete: Bool
    private var resetCopyWorkItem: DispatchWorkItem?

    public override var isFlipped: Bool { true }

    public init(showsDelete: Bool) {
        self.showsDelete = showsDelete
        let width: CGFloat = showsDelete ? 56 : 30
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        configureButton(copyButton, symbol: "doc.on.doc", tooltip: "Copy image", action: #selector(handleCopy))
        copyButton.frame = NSRect(x: 3, y: 1, width: 24, height: 24)
        addSubview(copyButton)

        if showsDelete {
            configureButton(deleteButton, symbol: "xmark", tooltip: "Remove image", action: #selector(handleDelete))
            deleteButton.frame = NSRect(x: 29, y: 1, width: 24, height: 24)
            addSubview(deleteButton)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.isBordered = false
        button.refusesFirstResponder = true
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        setSymbol(symbol, on: button, tint: .white.withAlphaComponent(0.92))
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return }
        if showsDelete && pt.x >= bounds.width / 2 {
            handleDelete()
        } else {
            handleCopy()
        }
    }

    private func setSymbol(_ name: String, on button: NSButton, tint: NSColor) {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            button.image = img.withSymbolConfiguration(config)
        }
        button.contentTintColor = tint
    }

    @objc private func handleCopy() {
        if let attachment {
            ImageAttachmentHelpers.copyToPasteboard(attachment)
        }
        onCopy?(attachment, imageOrdinal)
        resetCopyWorkItem?.cancel()
        setSymbol("checkmark", on: copyButton, tint: NSColor.systemGreen)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setSymbol("doc.on.doc", on: self.copyButton, tint: .white.withAlphaComponent(0.92))
        }
        resetCopyWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @objc private func handleDelete() {
        onDelete?(imageOrdinal)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

public final class AgentSelectableTextView: NSTextView, NSTextStorageDelegate {
    public static let userInlineImageIndexKey = NSAttributedString.Key("AnyDiff.UserInlineImageIndex")
    public weak var parentCell: AgentMessageCell?
    public var cellId: UUID?
    public var tvKey: String = ""

    public var hasLinks: Bool {
        if !hasLinksChecked {
            hasLinksChecked = true
            _hasLinks = false
            if let ts = textStorage, ts.length > 0 {
                ts.enumerateAttribute(.link, in: NSRange(location: 0, length: ts.length), options: [.longestEffectiveRangeNotRequired]) { val, _, stop in
                    if val != nil {
                        self._hasLinks = true
                        stop.pointee = true
                    }
                }
            }
        }
        return _hasLinks
    }
    private var hasLinksChecked: Bool = false
    private var _hasLinks: Bool = false
    private var hasAttachmentsChecked: Bool = false
    private var _hasAttachments: Bool = false
    private var inlineImageTrackingArea: NSTrackingArea?
    private var inlineImageHoverBar: AgentInlineImageHoverBarView?
    private var hoveredInlineImageIndex: Int?
    private var cachedLinkRects: [NSRect]?
    private var lastCalculatedBoundsWidth: CGFloat = -1

    public var hasInlineAttachments: Bool {
        if !hasAttachmentsChecked {
            hasAttachmentsChecked = true
            _hasAttachments = false
            if let ts = textStorage, ts.length > 0 {
                ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: [.longestEffectiveRangeNotRequired]) { val, _, stop in
                    if val is NSTextAttachment {
                        self._hasAttachments = true
                        stop.pointee = true
                    }
                }
            }
            syncInlineImageTrackingArea()
        }
        return _hasAttachments
    }

    private func syncInlineImageTrackingArea() {
        if _hasAttachments {
            if inlineImageTrackingArea == nil {
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: ["anyDiffInlineImageHover": true]
                )
                super.addTrackingArea(area)
                inlineImageTrackingArea = area
            }
        } else if let area = inlineImageTrackingArea {
            removeTrackingArea(area)
            inlineImageTrackingArea = nil
            inlineImageHoverBar?.isHidden = true
            hoveredInlineImageIndex = nil
        }
    }

    public func invalidateLinksCache() {
        hasLinksChecked = false
        hasAttachmentsChecked = false
        cachedLinkRects = nil
        lastCalculatedBoundsWidth = -1
        inlineImageHoverBar?.isHidden = true
        hoveredInlineImageIndex = nil
        _ = hasInlineAttachments
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        invalidateLinksCache()
    }

    public init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        textStorage.delegate = self

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
        self.layer?.masksToBounds = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.drawsAsynchronously = false
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = bounds.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged {
            invalidateLinksCache()
            needsDisplay = true
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if !drawsBackground {
            NSGraphicsContext.current?.cgContext.clear(bounds)
        }
        super.draw(dirtyRect)
    }

    public override func addTrackingArea(_ trackingArea: NSTrackingArea) {
        if trackingArea.userInfo?["anyDiffInlineImageHover"] != nil {
            super.addTrackingArea(trackingArea)
            return
        }
        // AppKit's NSTextView automatically adds a tracking area with
        // .cursorUpdate | .mouseEnteredAndExited | .mouseMoved (rawValue 551),
        // which forces NSCursor.iBeam over all text and causes rapid cursor flickering
        // between arrow and I-beam during hover and scroll.
        if trackingArea.options.contains(.cursorUpdate) || trackingArea.options.contains(.mouseEnteredAndExited) {
            return
        }
        super.addTrackingArea(trackingArea)
    }

    public override func updateTrackingAreas() {
        // Do not call super.updateTrackingAreas() — NSTextView's default implementation
        // adds and removes cursorUpdate / mouseEnteredAndExited tracking areas on every
        // scroll tick across all text views in the document.
    }

    public override func mouseEntered(with event: NSEvent) {
        // Suppress NSTextView's default behavior of setting NSCursor.iBeam
    }

    public override func mouseExited(with event: NSEvent) {
        let pInTV = convert(event.locationInWindow, from: nil)
        if bounds.contains(pInTV), inlineImageHit(at: pInTV) != nil {
            return
        }
        inlineImageHoverBar?.isHidden = true
        hoveredInlineImageIndex = nil
    }

    public override func cursorUpdate(with event: NSEvent) {
        if hasLinks {
            let mouseLoc = window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow
            let pInTV = convert(mouseLoc, from: nil)
            if isOverLink(at: pInTV) {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let pInTV = convert(event.locationInWindow, from: nil)
        if hasInlineAttachments {
            updateInlineImageHover(at: pInTV)
        }
        if hasLinks {
            if isOverLink(at: pInTV) {
                NSCursor.pointingHand.set()
                return
            }
        }
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.contains(pInTV) {
            NSCursor.pointingHand.set()
            return
        }
        NSCursor.arrow.set()
    }

    private func inlineImageHit(at pInTV: NSPoint) -> (index: Int, rect: NSRect)? {
        guard hasInlineAttachments,
              let lm = layoutManager,
              let tc = textContainer,
              let ts = textStorage,
              ts.length > 0 else { return nil }
        let glyphIdx = lm.glyphIndex(for: pInTV, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        guard rect.contains(pInTV) else { return nil }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < ts.length,
              ts.attribute(.attachment, at: charIdx, effectiveRange: nil) is NSTextAttachment else { return nil }

        if let explicitIdx = ts.attribute(Self.userInlineImageIndexKey, at: charIdx, effectiveRange: nil) as? Int {
            return (explicitIdx, rect)
        }
        var ordinal = 0
        if charIdx > 0 {
            ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: charIdx)) { value, _, _ in
                if value is NSTextAttachment {
                    ordinal += 1
                }
            }
        }
        return (ordinal, rect)
    }

    private func updateInlineImageHover(at pInTV: NSPoint) {
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.insetBy(dx: -4, dy: -4).contains(pInTV) {
            return
        }
        guard let hit = inlineImageHit(at: pInTV),
              let parentCell,
              parentCell.message.role == .user,
              hit.index < parentCell.message.images.count else {
            inlineImageHoverBar?.isHidden = true
            hoveredInlineImageIndex = nil
            return
        }
        hoveredInlineImageIndex = hit.index
        let bar: AgentInlineImageHoverBarView
        if let existing = inlineImageHoverBar {
            bar = existing
        } else {
            let created = AgentInlineImageHoverBarView(showsDelete: false)
            addSubview(created)
            inlineImageHoverBar = created
            bar = created
        }
        bar.imageOrdinal = hit.index
        bar.attachment = parentCell.message.images[hit.index]
        let barSize = bar.bounds.size
        bar.frame = NSRect(
            x: max(hit.rect.minX + 4, hit.rect.maxX - barSize.width - 6),
            y: hit.rect.minY + 6,
            width: barSize.width,
            height: barSize.height
        )
        bar.isHidden = false
    }

    private func isOverLink(at pInTV: NSPoint) -> Bool {
        guard hasLinks, let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return false }
        let glyphIdx = lm.glyphIndex(for: pInTV, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { return false }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < ts.length else { return false }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        return rect.contains(pInTV) && ts.attribute(.link, at: charIdx, effectiveRange: nil) != nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let pInTV = convert(point, from: superview)
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.contains(pInTV) {
            return bar
        }
        if hasLinks {
            if isOverLink(at: pInTV) {
                return self
            }
        }
        if hasInlineAttachments, inlineImageHit(at: pInTV) != nil {
            return self
        }
        if enclosingScrollView != nil {
            return super.hitTest(point)
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.contains(pt) {
            bar.mouseDown(with: event)
            return
        }
        var inlineImageIndex: Int?
        if event.clickCount >= 2,
           let lm = layoutManager,
           let tc = textContainer,
           let ts = textStorage {
            let glyphIdx = lm.glyphIndex(for: pt, in: tc)
            if glyphIdx < lm.numberOfGlyphs {
                let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
                let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
                if rect.contains(pt),
                   charIdx < ts.length,
                   ts.attribute(.attachment, at: charIdx, effectiveRange: nil) is NSTextAttachment {
                    if let explicitIdx = ts.attribute(Self.userInlineImageIndexKey, at: charIdx, effectiveRange: nil) as? Int {
                        inlineImageIndex = explicitIdx
                    } else {
                        var ordinal = 0
                        if charIdx > 0 {
                            ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: charIdx)) { value, _, _ in
                                if value is NSTextAttachment {
                                    ordinal += 1
                                }
                            }
                        }
                        inlineImageIndex = ordinal
                    }
                }
            }
        }
        if hasLinks, let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            let glyphIdx = lm.glyphIndex(for: pt, in: tc)
            if glyphIdx < lm.numberOfGlyphs {
                let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
                if charIdx < ts.length {
                    let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
                    if rect.contains(pt), let linkVal = ts.attribute(.link, at: charIdx, effectiveRange: nil) {
                        let url: URL?
                        if let u = linkVal as? URL {
                            url = u
                        } else if let s = linkVal as? String {
                            url = URL(string: s)
                        } else {
                            url = nil
                        }
                        if let url {
                            findEnclosingOpenURLHandler()?(url)
                            return
                        }
                    }
                }
            }
        }
        super.mouseDown(with: event)
        if let inlineImageIndex,
           let parentCell,
           parentCell.message.role == .user,
           inlineImageIndex < parentCell.message.images.count {
            parentCell.onPreviewImages?(parentCell.message.images, inlineImageIndex)
        }
        checkAndPublishQuote(for: selectedRange())
    }

    public override func copy(_ sender: Any?) {
        if let ts = textStorage,
           let parentCell,
           parentCell.message.role == .user,
           !parentCell.message.images.isEmpty {
            let sel = selectedRange()
            if sel.length > 0, sel.location + sel.length <= ts.length {
                var foundIndex: Int?
                ts.enumerateAttribute(.attachment, in: sel) { val, range, stop in
                    if val is NSTextAttachment {
                        if let explicitIdx = ts.attribute(Self.userInlineImageIndexKey, at: range.location, effectiveRange: nil) as? Int {
                            foundIndex = explicitIdx
                        } else {
                            foundIndex = 0
                        }
                        stop.pointee = true
                    }
                }
                let plainWithoutMarkers = AgentImageAttachment
                    .removingInlineTextMarkers(from: (ts.string as NSString).substring(with: sel))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let idx = foundIndex, plainWithoutMarkers.isEmpty, idx < parentCell.message.images.count {
                    ImageAttachmentHelpers.copyToPasteboard(parentCell.message.images[idx])
                    return
                }
            }
        }
        super.copy(sender)
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return ImageAttachmentHelpers.hasImages(in: .general) || NSPasteboard.general.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    public override func paste(_ sender: Any?) {
        let images = ImageAttachmentHelpers.extractImages(from: .general)
        if !images.isEmpty {
            NotificationCenter.default.post(
                name: Notification.Name("anyDiffAttachImages"),
                object: nil,
                userInfo: ["images": images]
            )
            NotificationCenter.default.post(name: Notification.Name("anyDiffFocusAgentInput"), object: nil)
            return
        }
        NotificationCenter.default.post(name: Notification.Name("anyDiffFocusAgentInput"), object: nil)
    }

    @objc private func handleContextCopyImage() {
        guard let idx = hoveredInlineImageIndex,
              let cell = parentCell,
              idx < cell.message.images.count else { return }
        ImageAttachmentHelpers.copyToPasteboard(cell.message.images[idx])
    }

    @objc private func handleContextCopyText() {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        checkAndPublishQuote(for: selectedRange())
    }

    public override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        checkAndPublishQuote(for: selectedRange())
    }

    public override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        checkAndPublishQuote(for: selectedRange())
    }

    public override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !stillSelectingFlag else { return }
        checkAndPublishQuote(for: charRange)
    }

    private func checkAndPublishQuote(for range: NSRange) {
        let quoteId = "agent:\(cellId?.uuidString ?? "msg"):\(tvKey)"
        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= (string as NSString).length else {
            SelectionQuoteStore.shared.clearQuote(scopedToId: quoteId)
            return
        }

        let text = (string as NSString).substring(with: range)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            SelectionQuoteStore.shared.clearQuote(scopedToId: quoteId)
            return
        }

        let isUser = parentCell?.message.role == .user
        let label = isUser ? "Quote from You" : "Quote from Assistant"
        let quote = SelectionQuote(
            id: quoteId,
            text: text,
            source: .agent,
            label: label
        )
        SelectionQuoteStore.shared.setQuote(quote)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = inlineImageHit(at: pt),
           let parentCell,
           parentCell.message.role == .user,
           hit.index < parentCell.message.images.count {
            hoveredInlineImageIndex = hit.index
            let menu = NSMenu()
            let copyItem = NSMenuItem(title: "Copy Image", action: #selector(handleContextCopyImage), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
            let items = parentCell.makeCheckpointMenuItems()
            if !items.isEmpty {
                menu.addItem(NSMenuItem.separator())
                for item in items {
                    menu.addItem(item)
                }
            }
            return menu
        }
        let priorRange = selectedRange()
        guard priorRange.location != NSNotFound, priorRange.length > 0 else {
            let menu = NSMenu()
            for item in parentCell?.makeCheckpointMenuItems() ?? [] {
                menu.addItem(item)
            }
            if !string.isEmpty {
                if !menu.items.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
                let copyItem = NSMenuItem(title: "Copy", action: #selector(handleContextCopyText), keyEquivalent: "")
                copyItem.target = self
                menu.addItem(copyItem)
                let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
                selectAllItem.target = self
                menu.addItem(selectAllItem)
            }
            return menu.items.isEmpty ? nil : menu
        }

        let menu = super.menu(for: event) ?? NSMenu()
        var insertIndex = 0
        var addedTopItem = false
        checkAndPublishQuote(for: priorRange)
        if SelectionQuoteStore.shared.currentQuote != nil {
            let quoteItem = NSMenuItem(title: "Quote Selection", action: #selector(contextMenuQuoteSelection(_:)), keyEquivalent: "")
            quoteItem.target = self
            quoteItem.image = NSImage(systemSymbolName: "quote.opening", accessibilityDescription: "Quote Selection")
            menu.insertItem(quoteItem, at: insertIndex)
            insertIndex += 1
            addedTopItem = true
        }
        for item in parentCell?.makeCheckpointMenuItems() ?? [] {
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
            addedTopItem = true
        }
        if addedTopItem, menu.items.count > insertIndex {
            menu.insertItem(NSMenuItem.separator(), at: insertIndex)
        }
        return menu
    }

    @objc private func contextMenuQuoteSelection(_ sender: Any?) {
        let range = selectedRange()
        checkAndPublishQuote(for: range)
        NotificationCenter.default.post(name: Notification.Name("anyDiffAgentAddCurrentQuote"), object: nil)
    }

    public override func cancelOperation(_ sender: Any?) {
        if selectedRange().length > 0 {
            setSelectedRange(NSRange(location: 0, length: 0))
            checkAndPublishQuote(for: NSRange(location: 0, length: 0))
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    public override func resetCursorRects() {
        // Do not register legacy cursor rects: registering cursor rects inside a scroll view
        // causes AppKit to invalidate the window's structural regions and recursively traverse
        // all subviews with _updateTrackingAreasWithInvalidCursorRects on every scroll frame.
        // Link hover is handled dynamically via mouseMoved and hitTest.
        discardCursorRects()
    }

    private func findEnclosingOpenURLHandler() -> ((URL) -> Void)? {
        var curr: NSView? = self
        while let v = curr {
            if let doc = v as? AgentChatDocumentView {
                return doc.onOpenURL
            }
            curr = v.superview
        }
        return nil
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
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = defaultBackgroundColor.cgColor
        contentTintColor = .white
    }

    public override func updateTrackingAreas() {
        // Do NOT call super.updateTrackingAreas() to prevent NSButtonCell's rollover
        // tracking from creating overhead on every scroll tick.
        guard !isHidden && alphaValue > 0.01 && window != nil && bounds.width > 0 && bounds.height > 0 else {
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            return
        }
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func resetCursorRects() {
        discardCursorRects()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01 && !isHidden else { return nil }
        return super.hitTest(point)
    }

    public override func mouseEntered(with event: NSEvent) {
        guard alphaValue > 0.01 && !isHidden else { return }
        super.mouseEntered(with: event)
        isHovered = true
        NSCursor.pointingHand.set()
        layer?.backgroundColor = hoverBackgroundColor.cgColor
    }

    public override func mouseExited(with event: NSEvent) {
        guard alphaValue > 0.01 && !isHidden else { return }
        super.mouseExited(with: event)
        isHovered = false
        NSCursor.arrow.set()
        layer?.backgroundColor = defaultBackgroundColor.cgColor
    }
}

func measureAttributedTextHeight(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
    guard attr.length > 0 else { return 18 }
    let rect = attr.boundingRect(
        with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return max(18, ceil(rect.height))
}

func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    return ceil(attr.size().width)
}

extension Theme {
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
