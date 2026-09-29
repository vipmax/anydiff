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

public final class AgentSelectableTextView: NSTextView, NSTextStorageDelegate {
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
    private var cachedLinkRects: [NSRect]?
    private var lastCalculatedBoundsWidth: CGFloat = -1

    public func invalidateLinksCache() {
        hasLinksChecked = false
        cachedLinkRects = nil
        lastCalculatedBoundsWidth = -1
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
            if !isHorizontallyResizable && newSize.width > 0 {
                textContainer?.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    public override func addTrackingArea(_ trackingArea: NSTrackingArea) {
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
        super.updateTrackingAreas()
        for ta in trackingAreas {
            if ta.options.contains(.cursorUpdate) || ta.options.contains(.mouseEnteredAndExited) {
                removeTrackingArea(ta)
            }
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        // Suppress NSTextView's default behavior of setting NSCursor.iBeam
    }

    public override func mouseExited(with event: NSEvent) {
        // Suppress NSTextView's default cursor resetting
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
        if hasLinks {
            let pInTV = convert(event.locationInWindow, from: nil)
            if isOverLink(at: pInTV) {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.arrow.set()
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
        if hasLinks {
            let pInTV = convert(point, from: superview)
            if isOverLink(at: pInTV) {
                return self
            }
        }
        if enclosingScrollView != nil {
            return super.hitTest(point)
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
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
        checkAndPublishQuote(for: selectedRange())
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
