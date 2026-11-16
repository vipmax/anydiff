import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore

private final class AgentInputImageAttachmentBox: NSObject, NSCopying {
    let image: AgentImageAttachment

    init(_ image: AgentImageAttachment) {
        self.image = image
    }

    func copy(with zone: NSZone? = nil) -> Any {
        self
    }
}

private enum AgentInputImageTextSupport {
    static let marker = AgentImageAttachment.inlineTextMarker
    static let attachmentKey = NSAttributedString.Key("AnyDiff.AgentInputImageAttachment")

    static func attributedString(
        from text: String,
        images: [AgentImageAttachment],
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let source = text as NSString
        var imageIndex = 0
        var searchLocation = 0

        while searchLocation < source.length, imageIndex < images.count {
            let markerRange = source.range(of: marker, options: [], range: NSRange(location: searchLocation, length: source.length - searchLocation))
            guard markerRange.location != NSNotFound else { break }
            let item = images[imageIndex]
            let display = ImageAttachmentHelpers.inlineDisplayImage(for: item)
            let textAttachment = NSTextAttachment()
            textAttachment.image = display.image
            textAttachment.bounds = display.bounds

            let richAttachment = NSMutableAttributedString(attachment: textAttachment)
            let attachmentRange = NSRange(location: 0, length: richAttachment.length)
            richAttachment.addAttributes(attributes, range: attachmentRange)
            richAttachment.addAttribute(
                attachmentKey,
                value: AgentInputImageAttachmentBox(item),
                range: attachmentRange
            )
            result.replaceCharacters(in: markerRange, with: richAttachment)
            imageIndex += 1
            searchLocation = markerRange.location + richAttachment.length
        }

        return result
    }

    static func images(in textView: NSTextView) -> [AgentImageAttachment] {
        guard let textStorage = textView.textStorage else { return [] }
        var images: [AgentImageAttachment] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(attachmentKey, in: fullRange) { value, _, _ in
            if let box = value as? AgentInputImageAttachmentBox {
                images.append(box.image)
            }
        }
        return images
    }

    static func containsImages(_ images: [AgentImageAttachment], in textView: NSTextView) -> Bool {
        let currentImages = self.images(in: textView)
        return currentImages.map(\.id) == images.map(\.id)
    }

    static func imageHit(in textView: NSTextView, at point: NSPoint) -> (ordinal: Int, rect: NSRect)? {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let textStorage = textView.textStorage,
              textStorage.length > 0 else { return nil }
        lm.ensureLayout(for: tc)
        let origin = textView.textContainerOrigin
        let tcPoint = NSPoint(
            x: point.x - origin.x,
            y: point.y - origin.y
        )
        let glyphIdx = lm.glyphIndex(for: tcPoint, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { return nil }
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        guard glyphRect.contains(tcPoint) else { return nil }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < textStorage.length,
              textStorage.attribute(attachmentKey, at: charIdx, effectiveRange: nil) is AgentInputImageAttachmentBox else {
            return nil
        }
        var ordinal = 0
        if charIdx > 0 {
            textStorage.enumerateAttribute(attachmentKey, in: NSRange(location: 0, length: charIdx)) { value, _, _ in
                if value is AgentInputImageAttachmentBox {
                    ordinal += 1
                }
            }
        }
        let viewRect = glyphRect.offsetBy(dx: origin.x, dy: origin.y)
        return (ordinal, viewRect)
    }

    static func imageOrdinal(in textView: NSTextView, at point: NSPoint) -> Int? {
        imageHit(in: textView, at: point)?.ordinal
    }

    static func inlineImageString(
        _ images: [AgentImageAttachment],
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for image in images {
            let display = ImageAttachmentHelpers.inlineDisplayImage(for: image)
            let textAttachment = NSTextAttachment()
            textAttachment.image = display.image
            textAttachment.bounds = display.bounds
            let richAttachment = NSMutableAttributedString(attachment: textAttachment)
            let attachmentRange = NSRange(location: 0, length: richAttachment.length)
            richAttachment.addAttributes(attributes, range: attachmentRange)
            richAttachment.addAttribute(
                attachmentKey,
                value: AgentInputImageAttachmentBox(image),
                range: attachmentRange
            )
            result.append(richAttachment)
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return result
    }

    static func removingMarkers(from text: String) -> String {
        AgentImageAttachment.removingInlineTextMarkers(from: text)
    }

    static func markerRange(in text: String, atOrdinal ordinal: Int) -> NSRange? {
        guard ordinal >= 0 else { return nil }
        let source = text as NSString
        var location = 0
        var currentOrdinal = 0
        while location < source.length {
            let range = source.range(of: marker, options: [], range: NSRange(location: location, length: source.length - location))
            guard range.location != NSNotFound else { return nil }
            if currentOrdinal == ordinal { return range }
            currentOrdinal += 1
            location = NSMaxRange(range)
        }
        return nil
    }

    private static func imageBounds(for attachment: AgentImageAttachment, image: NSImage?) -> NSRect {
        let imageSize = image?.size ?? .zero
        let width = imageSize.width > 0 ? imageSize.width : CGFloat(attachment.width ?? 0)
        let height = imageSize.height > 0 ? imageSize.height : CGFloat(attachment.height ?? 0)
        guard width > 0, height > 0 else {
            return NSRect(x: 0, y: 0, width: 240, height: 150)
        }

        let scale = min(1, 420 / width, 220 / height)
        return NSRect(x: 0, y: 0, width: width * scale, height: height * scale)
    }
}

private final class AgentPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if !hasVerticalScroller {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

public struct AgentAutoGrowingTextView: NSViewRepresentable {
    @Binding public var text: String
    public var inlineImages: [AgentImageAttachment]
    public var placeholder: String
    public var theme: Theme
    public var minHeight: CGFloat = 18
    public var maxHeight: CGFloat = .greatestFiniteMagnitude
    public var focusRequest: Int = 0
    public var cursorToEnd: Bool = true
    @Binding public var calculatedHeight: CGFloat
    public var onSend: () -> Void
    public var onFocusChanged: ((Bool) -> Void)?
    public var onInlineImagesChanged: (([AgentImageAttachment]) -> Void)?
    public var onImagePreview: ((Int) -> Void)?
    public var onDeleteBackwardWhenEmpty: (() -> Void)?
    public var onNavigatePrevious: ((_ toEnd: Bool) -> Bool)?
    public var onNavigateNext: ((_ toStart: Bool) -> Bool)?

    public init(
        text: Binding<String>,
        inlineImages: [AgentImageAttachment] = [],
        placeholder: String,
        theme: Theme,
        minHeight: CGFloat = 18,
        maxHeight: CGFloat = .greatestFiniteMagnitude,
        focusRequest: Int = 0,
        cursorToEnd: Bool = true,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping () -> Void,
        onFocusChanged: ((Bool) -> Void)? = nil,
        onInlineImagesChanged: (([AgentImageAttachment]) -> Void)? = nil,
        onImagePreview: ((Int) -> Void)? = nil,
        onDeleteBackwardWhenEmpty: (() -> Void)? = nil,
        onNavigatePrevious: ((_ toEnd: Bool) -> Bool)? = nil,
        onNavigateNext: ((_ toStart: Bool) -> Bool)? = nil
    ) {
        self._text = text
        self.inlineImages = inlineImages
        self.placeholder = placeholder
        self.theme = theme
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.focusRequest = focusRequest
        self.cursorToEnd = cursorToEnd
        self._calculatedHeight = calculatedHeight
        self.onSend = onSend
        self.onFocusChanged = onFocusChanged
        self.onInlineImagesChanged = onInlineImagesChanged
        self.onImagePreview = onImagePreview
        self.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
    }

    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(from: self, heightBinding: _calculatedHeight)

        let scrollView = AgentPassthroughScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.registerForDraggedTypes([.fileURL, .png, .tiff])

        let textView = AgentInputCustomTextView()
        textView.wantsLayer = true
        textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.setupDragDrop()
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = 3
        paraStyle.paragraphSpacing = 0
        textView.customParagraphStyle = paraStyle
        textView.defaultParagraphStyle = paraStyle
        let textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: paraStyle
        ]
        textView.string = text
        textView.textStorage?.setAttributedString(
            AgentInputImageTextSupport.attributedString(
                from: text,
                images: inlineImages,
                attributes: textView.typingAttributes
            )
        )
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.placeholderString = placeholder
        textView.delegate = context.coordinator
        context.coordinator.lastKnownText = text
        context.coordinator.lastObservedText = text
        context.coordinator.lastThemeId = theme.id
        if !text.isEmpty {
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        textView.onSend = onSend
        textView.onFocusChanged = onFocusChanged
        textView.onImagePreview = onImagePreview
        textView.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
        textView.onNavigatePrevious = onNavigatePrevious
        textView.onNavigateNext = onNavigateNext
        textView.onHeightChanged = { [weak coordinator = context.coordinator] newHeight in
            coordinator?.reportHeight(newHeight)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        context.coordinator.focusTextViewIfRequested()

        DispatchQueue.main.async {
            textView.recalculateHeight()
        }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self, heightBinding: _calculatedHeight)

        if let tv = scrollView.documentView as? AgentInputCustomTextView {
            let isFocused = (tv.window?.firstResponder == tv)
            let isTyping = isFocused && tv.string == context.coordinator.lastKnownText
            let externalClear = (text != context.coordinator.lastObservedText && text.isEmpty)
            let externalReplaced = (text != context.coordinator.lastObservedText && !tv.string.hasPrefix(text) && !text.hasPrefix(tv.string))
            let shouldUpdateText: Bool

            if tv.string == text {
                shouldUpdateText = false
            } else if !isFocused {
                shouldUpdateText = true
            } else if externalClear || externalReplaced || !isTyping {
                shouldUpdateText = true
            } else {
                shouldUpdateText = false
            }

            if shouldUpdateText || !AgentInputImageTextSupport.containsImages(inlineImages, in: tv) {
                tv.hideInlineImageHoverBar()
                let selection = tv.selectedRange()
                tv.textStorage?.setAttributedString(
                    AgentInputImageTextSupport.attributedString(
                        from: text,
                        images: inlineImages,
                        attributes: tv.typingAttributes
                    )
                )
                context.coordinator.lastKnownText = text
                context.coordinator.lastObservedText = text
                let maxLocation = (tv.string as NSString).length
                tv.selectedRange = NSRange(location: min(selection.location, maxLocation), length: 0)
                tv.needsDisplay = true
                DispatchQueue.main.async {
                    tv.recalculateHeight()
                }
            } else if tv.string == text {
                context.coordinator.lastObservedText = text
            }
            if context.coordinator.lastThemeId != theme.id {
                context.coordinator.lastThemeId = theme.id
                let textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
                tv.textColor = textColor
                tv.insertionPointColor = textColor
                let pStyle = tv.customParagraphStyle ?? {
                    let p = NSMutableParagraphStyle()
                    p.lineSpacing = 3
                    p.paragraphSpacing = 0
                    return p
                }()
                tv.customParagraphStyle = pStyle
                tv.typingAttributes = [
                    .font: tv.font ?? NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: textColor,
                    .paragraphStyle: pStyle
                ]
            }
            tv.onSend = onSend
            tv.onFocusChanged = onFocusChanged
            tv.onImagePreview = onImagePreview
            tv.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
            tv.onNavigatePrevious = onNavigatePrevious
            tv.onNavigateNext = onNavigateNext
        }

        scrollView.hasVerticalScroller = false

        context.coordinator.focusTextViewIfRequested()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentAutoGrowingTextView
        weak var textView: AgentInputCustomTextView?
        weak var scrollView: NSScrollView?
        private var heightBinding: Binding<CGFloat>?
        private var minHeight: CGFloat = 18
        private var maxHeight: CGFloat = .greatestFiniteMagnitude
        private var lastReportedHeight: CGFloat?
        private var lastFocusRequest: Int?
        var lastKnownText: String = ""
        var lastObservedText: String = ""
        var lastThemeId: String = ""

        init(_ parent: AgentAutoGrowingTextView) {
            self.parent = parent
            self.lastKnownText = parent.text
            self.lastObservedText = parent.text
        }

        func update(from parent: AgentAutoGrowingTextView, heightBinding: Binding<CGFloat>) {
            self.parent = parent
            self.heightBinding = heightBinding
            self.minHeight = parent.minHeight
            self.maxHeight = parent.maxHeight
        }

        func focusTextViewIfRequested() {
            let shouldFocus: Bool
            if let previousFocusRequest = lastFocusRequest {
                shouldFocus = (parent.focusRequest != previousFocusRequest)
            } else {
                shouldFocus = (parent.focusRequest > 0)
            }
            lastFocusRequest = parent.focusRequest
            guard shouldFocus else { return }

            let toEnd = parent.cursorToEnd
            let applyFocus: (NSWindow, AgentInputCustomTextView) -> Void = { window, tv in
                window.makeFirstResponder(tv)
                let loc = toEnd ? (tv.string as NSString).length : 0
                let range = NSRange(location: loc, length: 0)
                tv.selectedRange = range
                tv.scrollRangeToVisible(range)
            }

            if let textView = self.textView {
                textView.needsAutoFocusOnWindowAttachment = true
                if let window = textView.window {
                    applyFocus(window, textView)
                } else {
                    for delay in [0.04, 0.12, 0.25, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, let textView = self.textView, let window = textView.window else { return }
                            applyFocus(window, textView)
                        }
                    }
                }
            }
        }

        func reportHeight(_ rawHeight: CGFloat) {
            let newHeight = ceil(max(minHeight, min(maxHeight, rawHeight)))
            if let lastReportedHeight, abs(lastReportedHeight - newHeight) < 1.0 {
                return
            }
            lastReportedHeight = newHeight

            if let heightBinding = self.heightBinding, abs(heightBinding.wrappedValue - newHeight) >= 1.0 {
                if Thread.isMainThread {
                    heightBinding.wrappedValue = newHeight
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let heightBinding = self.heightBinding else { return }
                        guard abs(heightBinding.wrappedValue - newHeight) >= 1.0 else { return }
                        heightBinding.wrappedValue = newHeight
                    }
                }
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            lastKnownText = tv.string
            parent.onInlineImagesChanged?(AgentInputImageTextSupport.images(in: tv))
            parent.text = tv.string
            tv.recalculateHeight()
            tv.needsDisplay = true
        }

        public func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged?(true)
        }

        public func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged?(false)
        }
    }
}

public final class AgentInputCustomTextView: NSTextView {
    public var placeholderString: String?
    public var onSend: (() -> Void)?
    public var onHeightChanged: ((CGFloat) -> Void)?
    public var onFocusChanged: ((Bool) -> Void)?
    public var onImagePreview: ((Int) -> Void)?
    public var onDeleteBackwardWhenEmpty: (() -> Void)?
    public var onNavigatePrevious: ((_ toEnd: Bool) -> Bool)?
    public var onNavigateNext: ((_ toStart: Bool) -> Bool)?
    public var needsAutoFocusOnWindowAttachment: Bool = false
    private var isInsertingInlineImages: Bool = false
    private var inlineImageHoverBar: AgentInlineImageHoverBarView?
    private var hoveredInlineImageOrdinal: Int?
    private var hoverTrackingArea: NSTrackingArea?

    public func hideInlineImageHoverBar() {
        inlineImageHoverBar?.isHidden = true
        hoveredInlineImageOrdinal = nil
    }

    public func isCursorOnFirstLine() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        if sel.location == 0 { return true }
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        let charIdx = min(sel.location, max(0, (string as NSString).length - 1))
        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let cursorRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let firstLineRect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return cursorRect.minY <= firstLineRect.minY + 2
    }

    public func isCursorOnLastLine() -> Bool {
        let sel = selectedRange()
        let len = (string as NSString).length
        guard sel.length == 0 else { return false }
        if sel.location == len { return true }
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        if lm.extraLineFragmentTextContainer != nil {
            return false
        }
        let charIdx = min(sel.location, max(0, len - 1))
        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let cursorRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let lastGlyph = max(0, lm.numberOfGlyphs - 1)
        let lastLineRect = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        return cursorRect.maxY >= lastLineRect.maxY - 2
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDragDrop()
            if needsAutoFocusOnWindowAttachment {
                needsAutoFocusOnWindowAttachment = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    window.makeFirstResponder(self)
                    let loc = (self.string as NSString).length
                    let range = NSRange(location: loc, length: 0)
                    self.selectedRange = range
                    self.scrollRangeToVisible(range)
                }
            }
        }
    }

    public func setupDragDrop() {
        registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .string
        ])
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }
    }

    public var customParagraphStyle: NSParagraphStyle?

    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get {
            var attrs = super.typingAttributes
            attrs.removeValue(forKey: .attachment)
            attrs.removeValue(forKey: AgentInputImageTextSupport.attachmentKey)
            if attrs[.paragraphStyle] == nil, let p = customParagraphStyle {
                attrs[.paragraphStyle] = p
            }
            return attrs
        }
        set {
            var newAttrs = newValue
            newAttrs.removeValue(forKey: .attachment)
            newAttrs.removeValue(forKey: AgentInputImageTextSupport.attachmentKey)
            if newAttrs[.paragraphStyle] == nil, let p = customParagraphStyle {
                newAttrs[.paragraphStyle] = p
            }
            super.typingAttributes = newAttrs
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChanged?(true)
        }
        return didBecomeFirstResponder
    }

    public override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChanged?(false)
        }
        return didResignFirstResponder
    }

    public override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var caretRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        if caretRect.height <= 0, lm.numberOfGlyphs > 0 {
            let charIdx = min(range.location, max(0, (string as NSString).length - 1))
            let glyphIdx = min(lm.glyphIndexForCharacter(at: charIdx), lm.numberOfGlyphs - 1)
            caretRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        }
        let targetRect = caretRect.insetBy(dx: 0, dy: -24)
        if let outerScrollView = enclosingScrollView?.enclosingScrollView,
           let docView = outerScrollView.documentView {
            let rectInDoc = convert(targetRect, to: docView)
            docView.scrollToVisible(rectInDoc)
        }
    }

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (flags == .command || flags == [.command, .shift]),
           (event.keyCode == 9 || event.charactersIgnoringModifiers?.lowercased() == "v") {
            paste(nil)
            return
        }
        if event.keyCode == 36 { // Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                recalculateHeight()
            } else {
                onSend?()
            }
            return
        }
        if event.keyCode == 51 { // Backspace
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               deleteInlineImageBeforeCaret() {
                return
            }
            if string.isEmpty {
                onDeleteBackwardWhenEmpty?()
                return
            }
        }
        if event.modifierFlags.intersection([.shift, .command, .control]).isEmpty {
            if event.keyCode == 126 { // Up arrow
                if isCursorOnFirstLine() {
                    if let onNavigatePrevious, onNavigatePrevious(true) {
                        return
                    }
                }
            } else if event.keyCode == 125 { // Down arrow
                if isCursorOnLastLine() {
                    if let onNavigateNext, onNavigateNext(true) {
                        return
                    }
                }
            } else if event.keyCode == 123 { // Left arrow
                if selectedRange().location == 0 && selectedRange().length == 0 {
                    if let onNavigatePrevious, onNavigatePrevious(true) {
                        return
                    }
                }
            } else if event.keyCode == 124 { // Right arrow
                let len = (string as NSString).length
                if selectedRange().location == len && selectedRange().length == 0 {
                    if let onNavigateNext, onNavigateNext(true) {
                        return
                    }
                }
            }
        }
        super.keyDown(with: event)
        recalculateHeight()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let pInTV = convert(point, from: superview)
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.contains(pInTV) {
            return bar
        }
        return super.hitTest(point)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.contains(point) {
            bar.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
        guard event.clickCount >= 2,
              let imageIndex = AgentInputImageTextSupport.imageOrdinal(in: self, at: point) else { return }
        onImagePreview?(imageIndex)
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateInlineImageHover(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), AgentInputImageTextSupport.imageHit(in: self, at: point) != nil {
            return
        }
        inlineImageHoverBar?.isHidden = true
        hoveredInlineImageOrdinal = nil
    }

    private func updateInlineImageHover(at point: NSPoint) {
        if let bar = inlineImageHoverBar, !bar.isHidden, bar.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return
        }
        guard let hit = AgentInputImageTextSupport.imageHit(in: self, at: point) else {
            inlineImageHoverBar?.isHidden = true
            hoveredInlineImageOrdinal = nil
            return
        }
        hoveredInlineImageOrdinal = hit.ordinal
        let imgs = AgentInputImageTextSupport.images(in: self)
        let bar: AgentInlineImageHoverBarView
        if let existing = inlineImageHoverBar {
            bar = existing
        } else {
            let created = AgentInlineImageHoverBarView(showsDelete: true)
            created.onCopy = { [weak self] attachment, ordinal in
                guard let self else { return }
                if attachment == nil {
                    self.copyInlineImage(at: ordinal)
                }
            }
            created.onDelete = { [weak self] ordinal in
                guard let self else { return }
                self.deleteInlineImage(at: ordinal)
            }
            addSubview(created)
            inlineImageHoverBar = created
            bar = created
        }
        bar.imageOrdinal = hit.ordinal
        bar.attachment = (hit.ordinal >= 0 && hit.ordinal < imgs.count) ? imgs[hit.ordinal] : nil
        let barSize = bar.bounds.size
        bar.frame = NSRect(
            x: max(hit.rect.minX + 4, hit.rect.maxX - barSize.width - 6),
            y: hit.rect.minY + 6,
            width: barSize.width,
            height: barSize.height
        )
        bar.isHidden = false
    }

    private func copyHoveredInlineImage() {
        guard let ordinal = hoveredInlineImageOrdinal else { return }
        copyInlineImage(at: ordinal)
    }

    private func copyInlineImage(at ordinal: Int) {
        let imgs = AgentInputImageTextSupport.images(in: self)
        guard ordinal >= 0, ordinal < imgs.count else { return }
        ImageAttachmentHelpers.copyToPasteboard(imgs[ordinal])
    }

    private func deleteHoveredInlineImage() {
        guard let ordinal = hoveredInlineImageOrdinal else { return }
        deleteInlineImage(at: ordinal)
    }

    private func deleteInlineImage(at ordinal: Int) {
        guard let textStorage else { return }
        var foundRange: NSRange?
        var current = 0
        textStorage.enumerateAttribute(
            AgentInputImageTextSupport.attachmentKey,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, stop in
            guard value is AgentInputImageAttachmentBox else { return }
            if current == ordinal {
                foundRange = range
                stop.pointee = true
            }
            current += 1
        }
        guard var deleteRange = foundRange else { return }
        let source = string as NSString
        if NSMaxRange(deleteRange) < source.length,
           source.substring(with: NSRange(location: NSMaxRange(deleteRange), length: 1)) == "\n" {
            deleteRange.length += 1
        }
        if source.replacingCharacters(in: deleteRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteRange = NSRange(location: 0, length: source.length)
        }
        inlineImageHoverBar?.isHidden = true
        hoveredInlineImageOrdinal = nil
        insertText("", replacementRange: deleteRange)
        recalculateHeight()
    }

    public override func copy(_ sender: Any?) {
        if let textStorage {
            let sel = selectedRange()
            if sel.length > 0, sel.location + sel.length <= textStorage.length {
                var matchedBox: AgentInputImageAttachmentBox?
                textStorage.enumerateAttribute(AgentInputImageTextSupport.attachmentKey, in: sel) { val, _, stop in
                    if let box = val as? AgentInputImageAttachmentBox {
                        matchedBox = box
                        stop.pointee = true
                    }
                }
                let plainWithoutMarkers = AgentImageAttachment
                    .removingInlineTextMarkers(from: (textStorage.string as NSString).substring(with: sel))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let box = matchedBox, plainWithoutMarkers.isEmpty {
                    ImageAttachmentHelpers.copyToPasteboard(box.image)
                    return
                }
            }
        }
        super.copy(sender)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = AgentInputImageTextSupport.imageHit(in: self, at: pt) {
            hoveredInlineImageOrdinal = hit.ordinal
            let menu = NSMenu()
            let copyItem = NSMenuItem(title: "Copy Image", action: #selector(handleContextCopyInlineImage), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
            let deleteItem = NSMenuItem(title: "Remove Image", action: #selector(handleContextDeleteInlineImage), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func handleContextCopyInlineImage() {
        copyHoveredInlineImage()
    }

    @objc private func handleContextDeleteInlineImage() {
        deleteHoveredInlineImage()
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            .fileURL,
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ]
        for t in imageTypes where !types.contains(t) {
            types.append(t)
        }
        return types
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
            if ImageAttachmentHelpers.hasImages(in: .general) || NSPasteboard.general.string(forType: .string) != nil {
                return true
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    public override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    public override func paste(_ sender: Any?) {
        let images = ImageAttachmentHelpers.extractImages(from: .general)
        if !images.isEmpty {
            insertInlineImages(images)
            if let string = NSPasteboard.general.string(forType: .string),
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertText(string, replacementRange: selectedRange())
            }
            recalculateHeight()
            return
        }
        if let string = NSPasteboard.general.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
            recalculateHeight()
            return
        }
        super.paste(sender)
        recalculateHeight()
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if ImageAttachmentHelpers.hasImages(in: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ImageAttachmentHelpers.extractImages(from: sender.draggingPasteboard)
        if !images.isEmpty {
            let point = convert(sender.draggingLocation, from: nil)
            let location = characterIndexForInsertion(at: point)
            selectedRange = NSRange(location: min(location, (string as NSString).length), length: 0)
            insertInlineImages(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func insertInlineImages(_ images: [AgentImageAttachment]) {
        guard !images.isEmpty else { return }

        let source = string as NSString
        var range = selectedRange()
        if range.length > 0, let textStorage {
            var selectionContainsImage = false
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
            if clamped.length > 0 {
                textStorage.enumerateAttribute(AgentInputImageTextSupport.attachmentKey, in: clamped) { value, _, stop in
                    if value is AgentInputImageAttachmentBox {
                        selectionContainsImage = true
                        stop.pointee = true
                    }
                }
            }
            if selectionContainsImage {
                range = NSRange(location: NSMaxRange(clamped), length: 0)
            }
        }
        var safeLocation = min(range.location, source.length)
        if range.length == 0,
           safeLocation > 0,
           safeLocation < source.length,
           let textStorage,
           textStorage.attribute(AgentInputImageTextSupport.attachmentKey, at: safeLocation - 1, effectiveRange: nil) is AgentInputImageAttachmentBox,
           source.substring(with: NSRange(location: safeLocation, length: 1)) == "\n" {
            safeLocation += 1
        }
        range = NSRange(location: safeLocation, length: min(range.length, source.length - safeLocation))
        let insertions = NSMutableAttributedString()

        if safeLocation > 0, source.substring(with: NSRange(location: safeLocation - 1, length: 1)) != "\n" {
            insertions.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        }
        insertions.append(
            AgentInputImageTextSupport.inlineImageString(images, attributes: typingAttributes)
        )

        isInsertingInlineImages = true
        insertText(insertions, replacementRange: range)
        isInsertingInlineImages = false
        let caretLocation = safeLocation + insertions.length
        selectedRange = NSRange(location: max(0, min(caretLocation, (string as NSString).length)), length: 0)
        scrollRangeToVisible(selectedRange())
        recalculateHeight()
    }

    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if isInsertingInlineImages {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let rawText: String?
        if let s = insertString as? String {
            rawText = s
        } else if let attr = insertString as? NSAttributedString {
            rawText = attr.string
        } else {
            rawText = nil
        }

        guard let rawText, !rawText.isEmpty, let textStorage else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let cleanText = AgentImageAttachment.removingInlineTextMarkers(from: rawText)
        guard !cleanText.isEmpty else { return }

        let source = string as NSString
        var targetRange = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        targetRange.location = min(targetRange.location, source.length)
        targetRange.length = min(targetRange.length, source.length - targetRange.location)

        let isAfterAttachment = targetRange.location > 0
            && targetRange.location <= textStorage.length
            && textStorage.attribute(
                AgentInputImageTextSupport.attachmentKey,
                at: targetRange.location - 1,
                effectiveRange: nil
            ) is AgentInputImageAttachmentBox

        var textToInsert = cleanText
        if isAfterAttachment {
            let afterIdx = NSMaxRange(targetRange)
            if targetRange.length == 0,
               afterIdx < source.length,
               source.substring(with: NSRange(location: afterIdx, length: 1)) == "\n" {
                // Move insertion onto the line below the image instead of typing on the image's line
                targetRange.location += 1
                if textToInsert == "\n" {
                    selectedRange = NSRange(location: targetRange.location, length: 0)
                    scrollRangeToVisible(selectedRange())
                    recalculateHeight()
                    return
                }
            } else if !textToInsert.hasPrefix("\n") {
                textToInsert = "\n" + textToInsert
            }
        }

        let afterIdx = NSMaxRange(targetRange)
        let isBeforeAttachment = afterIdx < textStorage.length
            && textStorage.attribute(
                AgentInputImageTextSupport.attachmentKey,
                at: afterIdx,
                effectiveRange: nil
            ) is AgentInputImageAttachmentBox

        var desiredCaretLocation: Int?
        if isBeforeAttachment {
            if targetRange.location > 0,
               source.substring(with: NSRange(location: targetRange.location - 1, length: 1)) != "\n",
               !textToInsert.hasPrefix("\n") {
                textToInsert = "\n" + textToInsert
            }
            if !textToInsert.hasSuffix("\n") {
                let caretOffset = (textToInsert as NSString).length
                textToInsert += "\n"
                desiredCaretLocation = targetRange.location + caretOffset
            }
        }

        let attributedInsertion = NSAttributedString(string: textToInsert, attributes: typingAttributes)
        super.insertText(attributedInsertion, replacementRange: targetRange)
        if let desiredCaretLocation {
            let clamped = max(0, min(desiredCaretLocation, (string as NSString).length))
            selectedRange = NSRange(location: clamped, length: 0)
        }
        recalculateHeight()
    }

    private func deleteInlineImageBeforeCaret() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0,
              let textStorage,
              selection.location > 0 else { return false }

        let source = string as NSString
        let previousLocation = selection.location - 1

        // If caret is at the start of an image line ("text\n|[image]"), don't delete the "\n"
        // and merge the image onto the text line; move the caret to the end of the text line instead.
        if selection.location < textStorage.length,
           textStorage.attribute(
                AgentInputImageTextSupport.attachmentKey,
                at: selection.location,
                effectiveRange: nil
           ) is AgentInputImageAttachmentBox,
           source.substring(with: NSRange(location: previousLocation, length: 1)) == "\n",
           previousLocation > 0,
           source.substring(with: NSRange(location: previousLocation - 1, length: 1)) != "\n" {
            selectedRange = NSRange(location: previousLocation, length: 0)
            return true
        }

        let imageLocation: Int
        var deleteRange: NSRange
        if source.substring(with: NSRange(location: previousLocation, length: 1)) == "\n",
           previousLocation > 0,
           textStorage.attribute(
                AgentInputImageTextSupport.attachmentKey,
                at: previousLocation - 1,
                effectiveRange: nil
           ) is AgentInputImageAttachmentBox {
            imageLocation = previousLocation - 1
            deleteRange = NSRange(location: imageLocation, length: 2)
        } else if textStorage.attribute(
            AgentInputImageTextSupport.attachmentKey,
            at: previousLocation,
            effectiveRange: nil
        ) is AgentInputImageAttachmentBox {
            imageLocation = previousLocation
            deleteRange = NSRange(location: imageLocation, length: 1)
            if NSMaxRange(deleteRange) < source.length,
               source.substring(with: NSRange(location: NSMaxRange(deleteRange), length: 1)) == "\n" {
                deleteRange.length += 1
            }
        } else {
            return false
        }
        if source.replacingCharacters(in: deleteRange, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteRange = NSRange(location: 0, length: source.length)
        }
        hideInlineImageHoverBar()
        insertText("", replacementRange: deleteRange)
        recalculateHeight()
        return true
    }

    public func recalculateHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let usedRect = lm.usedRect(for: tc)
        onHeightChanged?(ceil(max(18, usedRect.height)))
    }

    public func adjustedInsertionPointRect(_ rect: NSRect) -> NSRect {
        let baseFont = font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        let normalHeight = ceil(layoutManager?.defaultLineHeight(for: baseFont) ?? 16)
        guard rect.height > normalHeight + 4,
              let textStorage,
              let layoutManager else {
            return rect
        }

        let sel = selectedRange()
        if sel.length == 0,
           sel.location > 0,
           sel.location <= textStorage.length,
           textStorage.attribute(
                AgentInputImageTextSupport.attachmentKey,
                at: sel.location - 1,
                effectiveRange: nil
           ) is AgentInputImageAttachmentBox {
            return rect
        }

        let charIdx = min(sel.location, max(0, textStorage.length - 1))
        if layoutManager.numberOfGlyphs > 0 {
            let glyphIdx = min(layoutManager.glyphIndexForCharacter(at: charIdx), layoutManager.numberOfGlyphs - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let baselineY = layoutManager.location(forGlyphAt: glyphIdx).y
            let topY = textContainerOrigin.y + lineRect.minY + baselineY - baseFont.ascender
            return NSRect(x: rect.origin.x, y: floor(topY), width: rect.width, height: normalHeight)
        }

        return NSRect(x: rect.origin.x, y: rect.maxY - normalHeight, width: rect.width, height: normalHeight)
    }

    public override func layout() {
        super.layout()
        syncSystemInsertionIndicatorFrame()
    }

    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        syncSystemInsertionIndicatorFrame()
        needsDisplay = true
    }

    public override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        syncSystemInsertionIndicatorFrame()
    }

    private func syncSystemInsertionIndicatorFrame() {
        for subview in subviews where String(describing: type(of: subview)).contains("InsertionIndicator") {
            let adjusted = adjustedInsertionPointRect(subview.frame)
            if subview.frame != adjusted {
                subview.frame = adjusted
            }
        }
    }

    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if flag {
            super.drawInsertionPoint(in: adjustedInsertionPointRect(rect), color: color, turnedOn: true)
        } else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: false)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let rect = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
            (placeholder as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}

public struct AgentInputTextBlockState: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var inlineImages: [AgentImageAttachment]
    public var height: CGFloat
    public var focusRequest: Int
    public var cursorToEnd: Bool

    public init(
        id: String = UUID().uuidString,
        text: String = "",
        inlineImages: [AgentImageAttachment] = [],
        height: CGFloat = 18,
        focusRequest: Int = 0,
        cursorToEnd: Bool = true
    ) {
        self.id = id
        self.text = text
        self.inlineImages = inlineImages
        self.height = height
        self.focusRequest = focusRequest
        self.cursorToEnd = cursorToEnd
    }
}

public enum AgentInputBlock: Identifiable, Equatable, Sendable {
    case text(AgentInputTextBlockState)
    case quote(id: String, quote: SelectionQuote)

    public var id: String {
        switch self {
        case .text(let state): return state.id
        case .quote(let id, _): return id
        }
    }

    public var isQuote: Bool {
        if case .quote = self { return true }
        return false
    }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var asPromptBlock: PromptBlock {
        switch self {
        case .text(let state): return .text(state.text)
        case .quote(_, let quote): return .quote(quote)
        }
    }
}

public struct AgentInputView: View {
    @Binding public var text: String
    @ObservedObject public var agentManager: AgentSessionManager
    public var theme: Theme
    public var accentColor: Color
    public var onSend: (String, [AgentImageAttachment]) -> Void
    public var onCancel: () -> Void
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)?

    @Binding public var attachedImages: [AgentImageAttachment]
    public var externalFocusRequest: Int = 0
    @State private var previewImageIndex: Int? = nil
    @Binding private var calculatedHeight: CGFloat
    @State private var isInputFocused: Bool = false
    @State private var inputFocusRequest: Int = 0
    @State private var isInputDropTargeted: Bool = false
    @ObservedObject private var quoteStore = SelectionQuoteStore.shared
    @State private var blocks: [AgentInputBlock]
    @State private var focusedBlockId: String
    @State private var maxAvatarWidth: CGFloat = AgentMessageCell.maxAvatarWidth
    @State private var userAvatarSize: CGFloat = AgentMessageCell.userAvatarSize
    @State private var isQuoteButtonHovered: Bool = false
    @State private var isQuoteDismissHovered: Bool = false

    private static let inputFirstLineHeight: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13, weight: .regular))
    )

    private var inputVerticalOffsets: (avatarTop: CGFloat, contentTop: CGFloat) {
        let firstCenter: CGFloat = blocks.first?.isQuote == true ? 20 : Self.inputFirstLineHeight / 2
        let avatarCenter = userAvatarSize / 2
        if avatarCenter >= firstCenter {
            return (0, avatarCenter - firstCenter)
        }
        return (firstCenter - avatarCenter, 0)
    }
    /// Reports the full natural height of the input stack (banner + queue + editor) so the
    /// host can reserve room for it instead of letting extra rows overlap the chat above.
    public var onTotalHeightChange: ((CGFloat) -> Void)?

    public static func makeInputBlocks(
        from draftBlocks: [PromptBlock],
        fallbackText: String,
        images: [AgentImageAttachment] = []
    ) -> [AgentInputBlock] {
        let sourceBlocks: [PromptBlock]
        if !draftBlocks.isEmpty {
            sourceBlocks = draftBlocks
        } else if !fallbackText.isEmpty {
            sourceBlocks = [.text(fallbackText)]
        } else {
            sourceBlocks = [.text("")]
        }

        let lastTextIndex = sourceBlocks.lastIndex {
            if case .text = $0 { return true }
            return false
        }

        var result: [AgentInputBlock] = []
        var nextImageIndex = 0
        for (index, block) in sourceBlocks.enumerated() {
            switch block {
            case .text(let value):
                let markerCount = ((value as NSString).components(separatedBy: AgentInputImageTextSupport.marker).count - 1)
                let imageCount = min(markerCount, images.count - nextImageIndex)
                result.append(
                    .text(
                        AgentInputTextBlockState(
                            text: value,
                            inlineImages: imageCount > 0
                                ? Array(images[nextImageIndex..<(nextImageIndex + imageCount)])
                                : [],
                            height: 18,
                            focusRequest: (index == lastTextIndex) ? 1 : 0,
                            cursorToEnd: true
                        )
                    )
                )
                nextImageIndex += imageCount
            case .quote(let quote):
                result.append(.quote(id: "quote-\(UUID().uuidString)", quote: quote))
            }
        }

        if !result.contains(where: \.isText) {
            result.append(.text(AgentInputTextBlockState(text: "", height: 18, focusRequest: 1)))
        }

        if nextImageIndex < images.count,
           let lastTextIndex = result.lastIndex(where: \.isText),
           case .text(var state) = result[lastTextIndex] {
            let remainingImages = Array(images[nextImageIndex...])
            if !state.text.isEmpty, !(state.text as NSString).hasSuffix("\n") {
                state.text += "\n"
            }
            state.text += String(repeating: AgentInputImageTextSupport.marker + "\n", count: remainingImages.count)
            state.inlineImages.append(contentsOf: remainingImages)
            result[lastTextIndex] = .text(state)
        }
        return result
    }

    public init(
        text: Binding<String>,
        attachedImages: Binding<[AgentImageAttachment]>? = nil,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>? = nil,
        calculatedHeight: Binding<CGFloat>,
        externalFocusRequest: Int = 0,
        onSend: @escaping (String, [AgentImageAttachment]) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self._attachedImages = attachedImages ?? Binding(
            get: { agentManager.draftAttachments },
            set: { agentManager.draftAttachments = $0 }
        )
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self._calculatedHeight = calculatedHeight
        self.externalFocusRequest = externalFocusRequest
        self.onSend = onSend
        self.onCancel = onCancel
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
        let initialBlocks = Self.makeInputBlocks(
            from: agentManager.draftBlocks,
            fallbackText: text.wrappedValue,
            images: attachedImages?.wrappedValue ?? agentManager.draftAttachments
        )
        self._blocks = State(initialValue: initialBlocks)
        self._focusedBlockId = State(initialValue: initialBlocks.last(where: \.isText)?.id ?? initialBlocks.first?.id ?? "")
    }

    public init(
        text: Binding<String>,
        attachedImages: Binding<[AgentImageAttachment]>? = nil,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>? = nil,
        calculatedHeight: Binding<CGFloat>,
        externalFocusRequest: Int = 0,
        onSend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self._attachedImages = attachedImages ?? Binding(
            get: { agentManager.draftAttachments },
            set: { agentManager.draftAttachments = $0 }
        )
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self._calculatedHeight = calculatedHeight
        self.externalFocusRequest = externalFocusRequest
        self.onSend = { prompt, _ in onSend(prompt) }
        self.onCancel = onCancel
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
        let initialBlocks = Self.makeInputBlocks(
            from: agentManager.draftBlocks,
            fallbackText: text.wrappedValue,
            images: attachedImages?.wrappedValue ?? agentManager.draftAttachments
        )
        self._blocks = State(initialValue: initialBlocks)
        self._focusedBlockId = State(initialValue: initialBlocks.last(where: \.isText)?.id ?? initialBlocks.first?.id ?? "")
    }

    private var isBusy: Bool {
        agentManager.status == .busy || agentManager.status == .connecting || agentManager.initializationState == .starting
    }

    private var shouldShowLiveEditedSummary: Bool {
        agentManager.liveEditedSummary != nil &&
            (isBusy || agentManager.messages.last?.isStreaming == true)
    }

    public var body: some View {
        expandedView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: AgentInputTotalHeightPreferenceKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(AgentInputTotalHeightPreferenceKey.self) { newHeight in
                if newHeight > 0 { onTotalHeightChange?(newHeight) }
            }
            .onDrop(of: [UTType.image, UTType.fileURL, UTType.png, UTType.jpeg, UTType.tiff, UTType.webP, UTType.heic, UTType.url, UTType.data, UTType.item], isTargeted: $isInputDropTargeted) { providers in
                ImageAttachmentHelpers.extractImages(from: providers) { droppedImages in
                    guard !droppedImages.isEmpty else { return }
                    addImagesInline(droppedImages)
                }
                return true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAttachImages"))) { notification in
                if let newImages = notification.userInfo?["images"] as? [AgentImageAttachment], !newImages.isEmpty {
                    addImagesInline(newImages)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentSubmitPrompt"))) { _ in
                handleSend()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffFocusAgentInput"))) { _ in
                inputFocusRequest &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentAddCurrentQuote"))) { _ in
                if let quote = quoteStore.currentQuote, !isAlreadyQuoted(quote) {
                    addQuote(quote)
                }
            }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffDeleteDraftImage"))) { notification in
            if let delIdx = notification.userInfo?["index"] as? Int {
                removeInlineImage(at: delIdx)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffUpdateDraftImage"))) { notification in
            guard let index = notification.userInfo?["index"] as? Int,
                  let image = notification.userInfo?["image"] as? AgentImageAttachment,
                  index >= 0,
                  index < attachedImages.count else { return }
            updateInlineImage(at: index, with: image)
        }
        .overlay {
            if onPreviewImages == nil, previewImageIndex != nil && !attachedImages.isEmpty {
                AgentImagePreviewModalView(
                    images: attachedImages,
                    selectedIndex: $previewImageIndex,
                    allowsEditing: true,
                    onDelete: { delIdx in
                        removeInlineImage(at: delIdx)
                    },
                    onEdit: { index, image in
                        updateInlineImage(at: index, with: image)
                    },
                    theme: theme
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            if !agentManager.draftBlocks.isEmpty {
                let currentPromptBlocks = blocks.map(\.asPromptBlock)
                if currentPromptBlocks != agentManager.draftBlocks {
                    let restored = Self.makeInputBlocks(
                        from: agentManager.draftBlocks,
                        fallbackText: text,
                        images: attachedImages
                    )
                    blocks = restored
                    focusedBlockId = restored.last(where: \.isText)?.id ?? restored.first?.id ?? ""
                    syncDraftState()
                }
            } else if !text.isEmpty && blocks.count == 1, case .text(var state) = blocks[0], state.text.isEmpty {
                state.text = text
                blocks[0] = .text(state)
                focusedBlockId = state.id
                syncDraftState()
            }
            recalculateTotalHeight()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocusRequest &+= 1
            }
        }
        .onChange(of: agentManager.isPanelOpen) { isOpen in
            if isOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    inputFocusRequest &+= 1
                }
            }
        }
        .onChange(of: externalFocusRequest) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocusRequest &+= 1
            }
        }
        .onChange(of: attachedImages) { newImages in
            guard inlineImagesInBlocks.isEmpty, !newImages.isEmpty else { return }
            let restored = Self.makeInputBlocks(
                from: blocks.map(\.asPromptBlock),
                fallbackText: text,
                images: newImages
            )
            blocks = restored
            focusedBlockId = restored.last(where: \.isText)?.id ?? restored.first?.id ?? ""
            syncDraftState()
            recalculateTotalHeight()
        }
        .onChange(of: text) { newText in
            guard !hasQuotes else { return }
            if blocks.count == 1, case .text(var state) = blocks[0] {
                if AgentInputImageTextSupport.removingMarkers(from: state.text) != newText {
                    state.text = newText
                    state.inlineImages = []
                    blocks[0] = .text(state)
                    syncDraftState()
                }
            }
        }
        .onChange(of: agentManager.draftBlocks) { newDraftBlocks in
            if newDraftBlocks.isEmpty && text.isEmpty {
                let isSingleEmptyText = blocks.count == 1 && {
                    if case .text(let state) = blocks[0] { return state.text.isEmpty }
                    return false
                }()
                if !isSingleEmptyText {
                    let newId = UUID().uuidString
                    blocks = [.text(AgentInputTextBlockState(id: newId, text: "", height: 18, focusRequest: 1))]
                    focusedBlockId = newId
                    recalculateTotalHeight()
                }
            }
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(spacing: 8) {
            // Live changed files top banner
            if shouldShowLiveEditedSummary, let liveSummary = agentManager.liveEditedSummary {
                AgentLiveChangesBannerView(
                    summary: liveSummary,
                    theme: theme,
                    accentColor: accentColor,
                    onReview: onReview
                )
                .transition(.opacity)
            }

            if let permission = agentManager.pendingPermission {
                AgentPermissionCardView(
                    permission: permission,
                    theme: theme,
                    onRespond: { optionId in
                        agentManager.respondToPermission(optionId: optionId)
                    }
                )
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            let offsets = inputVerticalOffsets
            HStack(alignment: .top, spacing: 12) {
                // User avatar on the left, dynamically sized to user avatar size
                AgentAvatarProvider.userAvatarSwiftUIView()
                    .frame(width: maxAvatarWidth, alignment: .center)
                    .padding(.top, offsets.avatarTop)

                VStack(alignment: .leading, spacing: 6) {
                    // Blocks flow (interleaved quotes and text)
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            blocksContentView()
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let quote = quoteStore.currentQuote,
                       !isAlreadyQuoted(quote) {
                        HStack(spacing: 6) {
                            HStack(spacing: 0) {
                                Button(action: {
                                    addQuote(quote)
                                }) {
                                    Image(systemName: "quote.opening")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(accentColor)
                                        .frame(width: 24, height: 24)
                                        .background(
                                            accentColor.opacity(isQuoteButtonHovered ? 0.20 : 0.08)
                                        )
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        isQuoteButtonHovered = hovering
                                    }
                                }
                                .overlay(AgentInputPointingHandCursorView())
                                .help(quoteSuggestionHelpText(quote: quote))
                                .accessibilityLabel("Quote selection (\(quote.label))")

                                Rectangle()
                                    .fill(accentColor.opacity(0.18))
                                    .frame(width: 1, height: 14)

                                Button(action: {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        quoteStore.clearQuote(scopedToId: quote.id)
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundColor(accentColor.opacity(isQuoteDismissHovered ? 1.0 : 0.7))
                                        .frame(width: 20, height: 24)
                                        .background(
                                            accentColor.opacity(isQuoteDismissHovered ? 0.20 : 0.08)
                                        )
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        isQuoteDismissHovered = hovering
                                    }
                                }
                                .overlay(AgentInputPointingHandCursorView())
                                .help("Dismiss quote")
                                .accessibilityLabel("Dismiss quote")
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(accentColor.opacity(isQuoteButtonHovered || isQuoteDismissHovered ? 0.30 : 0.15), lineWidth: 1)
                            )

                            Spacer()
                        }
                        .padding(.top, 2)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(.top, offsets.contentTop)
                .frame(maxWidth: AgentMessageCell.maxContentWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .background(Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                inputFocusRequest &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: AgentAvatarProvider.avatarDidChangeNotification)) { _ in
                maxAvatarWidth = AgentMessageCell.maxAvatarWidth
                userAvatarSize = AgentMessageCell.userAvatarSize
                recalculateTotalHeight()
            }
        }
        .animation(.easeInOut(duration: 0.14), value: shouldShowLiveEditedSummary)
    }

    private func quoteBadgeView(id: String, quote: SelectionQuote) -> some View {
        AgentInputQuoteBadgeView(
            id: id,
            quote: quote,
            theme: theme,
            accentColor: accentColor,
            onRemove: {
                removeQuoteBlock(id: id)
            }
        )
    }

    @ViewBuilder
    private func blocksContentView() -> some View {
        VStack(spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block {
                case .quote(let id, let quote):
                    quoteBadgeView(id: id, quote: quote)

                case .text(let state):
                    let placeholder: String = {
                        if blocks.count == 1 {
                            return (!agentManager.authMethods.isEmpty || agentManager.isAuthenticating)
                                ? "Sign in above to start chatting..."
                                : "Ask anything..."
                        } else if index == 0 && blocks.first?.isText == true {
                            return "Add context before quote (optional)..."
                        } else {
                            return "Ask anything, add comment or instructions..."
                        }
                    }()

                    let shouldApplyGlobalFocus: Bool = {
                        if blocks.count <= 1 { return true }
                        if !focusedBlockId.isEmpty { return state.id == focusedBlockId }
                        return index == blocks.lastIndex(where: \.isText)
                    }()
                    let effectiveFocusRequest = state.focusRequest + (shouldApplyGlobalFocus ? (inputFocusRequest + externalFocusRequest) : 0)

                    AgentAutoGrowingTextView(
                        text: Binding(
                            get: { state.text },
                            set: { newText in updateTextBlock(id: state.id, text: newText) }
                        ),
                        inlineImages: state.inlineImages,
                        placeholder: placeholder,
                        theme: theme,
                        minHeight: 18,
                        maxHeight: .greatestFiniteMagnitude,
                        focusRequest: effectiveFocusRequest,
                        cursorToEnd: state.cursorToEnd,
                        calculatedHeight: Binding(
                            get: { state.height },
                            set: { newH in updateTextBlockHeight(id: state.id, height: newH) }
                        ),
                        onSend: handleSend,
                        onFocusChanged: { focused in
                            isInputFocused = focused
                            if focused { focusedBlockId = state.id }
                        },
                        onInlineImagesChanged: { newImages in
                            updateTextBlockImages(id: state.id, images: newImages)
                        },
                        onImagePreview: { localIndex in
                            let precedingImageCount = blocks.prefix(index).reduce(0) { count, block in
                                if case .text(let state) = block { return count + state.inlineImages.count }
                                return count
                            }
                            let globalIndex = precedingImageCount + localIndex
                            if let onPreviewImages {
                                onPreviewImages(attachedImages, globalIndex, true)
                            } else {
                                previewImageIndex = globalIndex
                            }
                        },
                        onDeleteBackwardWhenEmpty: {
                            handleDeleteBackward(inBlockId: state.id, index: index)
                        },
                        onNavigatePrevious: { toEnd in
                            navigateToPreviousTextBlock(fromIndex: index, toEnd: toEnd)
                        },
                        onNavigateNext: { toStart in
                            navigateToNextTextBlock(fromIndex: index, toStart: toStart)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: state.height)
                }
            }
        }
    }

    private var hasQuotes: Bool {
        blocks.contains(where: \.isQuote)
    }

    private func quoteSuggestionHelpText(quote: SelectionQuote) -> String {
        let snippet = quote.text.prefix(60).replacingOccurrences(of: "\n", with: " ")
        return "Quote selection (\(quote.label)): \"\(snippet)\""
    }

    private func isAlreadyQuoted(_ quote: SelectionQuote) -> Bool {
        blocks.contains { block in
            if case .quote(_, let q) = block {
                return q.id == quote.id || (q.text == quote.text && q.label == quote.label)
            }
            return false
        }
    }

    private func syncDraftState() {
        let promptBlocks = blocks.map(\.asPromptBlock)
        if agentManager.draftBlocks != promptBlocks {
            agentManager.draftBlocks = promptBlocks
        }
        let images = inlineImagesInBlocks
        if attachedImages != images {
            attachedImages = images
        }
        if agentManager.draftAttachments != images {
            agentManager.draftAttachments = images
        }
        if hasQuotes {
            let formatted = SelectionQuoteFormatter.formatPromptBlocks(promptBlocks.map(removingImageMarkers))
            if self.text != formatted {
                self.text = formatted
            }
        } else {
            let plainText: String
            if blocks.count == 1, case .text(let state) = blocks[0] {
                plainText = AgentInputImageTextSupport.removingMarkers(from: state.text)
            } else {
                plainText = blocks.compactMap { block -> String? in
                    if case .text(let state) = block {
                        return AgentInputImageTextSupport.removingMarkers(from: state.text)
                    }
                    return nil
                }.joined(separator: "\n\n")
            }
            if self.text != plainText {
                self.text = plainText
            }
        }
    }

    private func updateTextBlock(id: String, text: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if case .text(var state) = blocks[index] {
            state.text = text
            blocks[index] = .text(state)
        }
        syncDraftState()
    }

    private var inlineImagesInBlocks: [AgentImageAttachment] {
        blocks.flatMap { block in
            if case .text(let state) = block { return state.inlineImages }
            return []
        }
    }

    private func updateTextBlockImages(id: String, images: [AgentImageAttachment]) {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              case .text(var state) = blocks[index],
              state.inlineImages != images else { return }
        state.inlineImages = images
        blocks[index] = .text(state)
        syncDraftState()
    }

    private func addImagesInline(_ images: [AgentImageAttachment]) {
        guard !images.isEmpty else { return }
        let newImages = ImageAttachmentHelpers.deduplicateAttachments(images)
        guard !newImages.isEmpty else { return }

        let targetIndex = blocks.firstIndex(where: { $0.id == focusedBlockId && $0.isText })
            ?? blocks.lastIndex(where: \.isText)
        guard let targetIndex, case .text(var state) = blocks[targetIndex] else { return }
        if !state.text.isEmpty, !(state.text as NSString).hasSuffix("\n") {
            state.text += "\n"
        }
        state.text += String(repeating: AgentInputImageTextSupport.marker + "\n", count: newImages.count)
        state.inlineImages.append(contentsOf: newImages)
        blocks[targetIndex] = .text(state)
        syncDraftState()
        recalculateTotalHeight()
        inputFocusRequest &+= 1
    }

    private func removeInlineImage(at globalIndex: Int) {
        guard globalIndex >= 0 else { return }
        var imageOffset = 0
        for blockIndex in blocks.indices {
            guard case .text(var state) = blocks[blockIndex] else { continue }
            let imageEnd = imageOffset + state.inlineImages.count
            guard globalIndex < imageEnd else {
                imageOffset = imageEnd
                continue
            }
            let localIndex = globalIndex - imageOffset
            guard let markerRange = AgentInputImageTextSupport.markerRange(in: state.text, atOrdinal: localIndex) else { return }
            state.text = (state.text as NSString).replacingCharacters(in: markerRange, with: "")
            state.inlineImages.remove(at: localIndex)
            blocks[blockIndex] = .text(state)
            syncDraftState()
            recalculateTotalHeight()
            return
        }
    }

    private func updateInlineImage(at globalIndex: Int, with image: AgentImageAttachment) {
        guard globalIndex >= 0 else { return }
        var imageOffset = 0
        for blockIndex in blocks.indices {
            guard case .text(var state) = blocks[blockIndex] else { continue }
            let imageEnd = imageOffset + state.inlineImages.count
            guard globalIndex < imageEnd else {
                imageOffset = imageEnd
                continue
            }
            let existingImage = state.inlineImages[globalIndex - imageOffset]
            state.inlineImages[globalIndex - imageOffset] = AgentImageAttachment(
                id: existingImage.id == image.id ? UUID() : image.id,
                data: image.data,
                mimeType: image.mimeType,
                filename: image.filename,
                width: image.width,
                height: image.height,
                fileSize: image.fileSize
            )
            blocks[blockIndex] = .text(state)
            syncDraftState()
            recalculateTotalHeight()
            return
        }
    }

    private func removingImageMarkers(from block: PromptBlock) -> PromptBlock {
        if case .text(let value) = block {
            return .text(AgentInputImageTextSupport.removingMarkers(from: value))
        }
        return block
    }

    private var estimatedBlocksHeight: CGFloat {
        var total: CGFloat = 4
        for (i, block) in blocks.enumerated() {
            if i > 0 { total += 6 }
            switch block {
            case .quote:
                total += 42
            case .text(let state):
                total += max(18, state.height)
            }
        }
        return total
    }

    private func recalculateTotalHeight() {
        let offsets = inputVerticalOffsets
        let minH = max(userAvatarSize + 8, 38)
        let contentHeight = offsets.contentTop + estimatedBlocksHeight
        let avatarHeight = offsets.avatarTop + userAvatarSize
        let total = 8 + max(avatarHeight, contentHeight)
        self.calculatedHeight = max(minH, total)
    }

    private func updateTextBlockHeight(id: String, height: CGFloat) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if case .text(var state) = blocks[index] {
            state.height = height
            blocks[index] = .text(state)
        }
        recalculateTotalHeight()
    }

    private func addQuote(_ quote: SelectionQuote) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let newQuoteId = "\(quote.id)-\(timestamp)"
        let quoteBlockId = "quote-\(timestamp)"
        let nextTextBlockId = "text-\(timestamp + 1)"

        let quoteBlock = AgentInputBlock.quote(
            id: quoteBlockId,
            quote: SelectionQuote(
                id: newQuoteId,
                text: quote.text,
                source: quote.source,
                label: quote.label,
                filePath: quote.filePath,
                displayPath: quote.displayPath,
                lineRange: quote.lineRange,
                language: quote.language
            )
        )
        let nextTextBlock = AgentInputBlock.text(
            AgentInputTextBlockState(
                id: nextTextBlockId,
                text: "",
                height: 18,
                focusRequest: 1
            )
        )

        withAnimation(.easeOut(duration: 0.16)) {
            let isSingleEmpty: Bool = {
                if blocks.count == 1, case .text(let state) = blocks[0] {
                    return state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return false
            }()

            if isSingleEmpty {
                blocks = [quoteBlock, nextTextBlock]
            } else {
                let focusIdx = blocks.firstIndex(where: { $0.id == focusedBlockId })
                let insertAt = (focusIdx != nil) ? focusIdx! + 1 : blocks.count
                blocks.insert(contentsOf: [quoteBlock, nextTextBlock], at: insertAt)
            }
            focusedBlockId = nextTextBlockId
            syncDraftState()
            recalculateTotalHeight()
            inputFocusRequest &+= 1
        }

        quoteStore.clearQuote(scopedToId: quote.id)
    }

    private func removeQuoteBlock(id: String) {
        guard let quoteIdx = blocks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            blocks.remove(at: quoteIdx)

            // If quote was between two text blocks, merge them
            let prevIdx = quoteIdx - 1
            let nextIdx = quoteIdx // now at quoteIdx because quote was removed
            if prevIdx >= 0, nextIdx < blocks.count,
               case .text(var prevState) = blocks[prevIdx],
               case .text(let nextState) = blocks[nextIdx] {
                let prevT = prevState.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let nextT = nextState.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let merged: String
                if !prevT.isEmpty && !nextT.isEmpty {
                    merged = "\(prevT)\n\n\(nextT)"
                } else {
                    merged = prevT.isEmpty ? nextT : prevT
                }
                prevState.text = merged
                prevState.inlineImages.append(contentsOf: nextState.inlineImages)
                prevState.cursorToEnd = true
                prevState.focusRequest += 1
                blocks[prevIdx] = .text(prevState)
                blocks.remove(at: nextIdx)
                focusedBlockId = prevState.id
            } else if prevIdx >= 0, case .text(var prevState) = blocks[prevIdx] {
                prevState.cursorToEnd = true
                prevState.focusRequest += 1
                blocks[prevIdx] = .text(prevState)
                focusedBlockId = prevState.id
            } else if nextIdx < blocks.count, case .text(var nextState) = blocks[nextIdx] {
                nextState.cursorToEnd = true
                nextState.focusRequest += 1
                blocks[nextIdx] = .text(nextState)
                focusedBlockId = nextState.id
            }

            if blocks.isEmpty {
                let fallbackState = AgentInputTextBlockState(text: "", height: 18, focusRequest: 1)
                blocks = [.text(fallbackState)]
                focusedBlockId = fallbackState.id
                syncDraftState()
                recalculateTotalHeight()
                inputFocusRequest &+= 1
                return
            }

            if !hasQuotes {
                let singleText = blocks.compactMap { block -> String? in
                    if case .text(let s) = block {
                        let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return nil
                }.joined(separator: "\n\n")
                let singleImages = inlineImagesInBlocks

                let singleId = blocks.first(where: \.isText)?.id ?? UUID().uuidString
                let finalState = AgentInputTextBlockState(
                    id: singleId,
                    text: singleText,
                    inlineImages: singleImages,
                    height: 18,
                    focusRequest: 1
                )
                blocks = [.text(finalState)]
                focusedBlockId = singleId
                inputFocusRequest &+= 1
            }

            syncDraftState()
            recalculateTotalHeight()
        }
    }

    private func handleDeleteBackward(inBlockId: String, index: Int) {
        guard index > 0, let currentBlock = blocks.first(where: { $0.id == inBlockId }),
              case .text(let state) = currentBlock, state.text.isEmpty else { return }
        let prevBlock = blocks[index - 1]
        if case .quote(let quoteId, _) = prevBlock {
            removeQuoteBlock(id: quoteId)
        }
    }

    @discardableResult
    private func navigateToPreviousTextBlock(fromIndex index: Int, toEnd: Bool) -> Bool {
        guard index > 0 else { return false }
        for i in (0..<index).reversed() {
            if case .text(var targetState) = blocks[i] {
                targetState.cursorToEnd = toEnd
                targetState.focusRequest &+= 1
                blocks[i] = .text(targetState)
                focusedBlockId = targetState.id
                return true
            }
        }
        return false
    }

    @discardableResult
    private func navigateToNextTextBlock(fromIndex index: Int, toStart: Bool) -> Bool {
        guard index + 1 < blocks.count else { return false }
        for i in (index + 1)..<blocks.count {
            if case .text(var targetState) = blocks[i] {
                targetState.cursorToEnd = !toStart
                targetState.focusRequest &+= 1
                blocks[i] = .text(targetState)
                focusedBlockId = targetState.id
                return true
            }
        }
        return false
    }

    private var canSubmitPrompt: Bool {
        let hasText = blocks.contains { block in
            if case .text(let state) = block {
                return !AgentInputImageTextSupport.removingMarkers(from: state.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
        let hasQuotes = self.hasQuotes
        let hasImages = !attachedImages.isEmpty
        return (hasText || hasQuotes || hasImages) && agentManager.canAcceptPrompt
    }

    private func handleSend() {
        guard agentManager.canAcceptPrompt else { return }
        guard canSubmitPrompt else { return }

        let promptBlocks = blocks.map(\.asPromptBlock)
        let finalPrompt = SelectionQuoteFormatter.formatPromptBlocks(promptBlocks)
        let imagesToSend = attachedImages

        attachedImages = []
        let newId = UUID().uuidString
        blocks = [.text(AgentInputTextBlockState(id: newId, text: "", height: 18, focusRequest: 1))]
        text = ""
        agentManager.draftBlocks = []
        focusedBlockId = newId
        recalculateTotalHeight()
        inputFocusRequest &+= 1

        onSend(finalPrompt, imagesToSend)
    }
}

private struct AgentInputInteractiveHoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .overlay(AgentInputPointingHandCursorView())
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct AgentInputPointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentInputPointingHandNSView {
        AgentInputPointingHandNSView()
    }

    func updateNSView(_ nsView: AgentInputPointingHandNSView, context: Context) {}
}

private final class AgentInputPointingHandNSView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .cursorUpdate
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    // Keep the cursor view transparent to clicks so the underlying SwiftUI
    // Button/Menu still receives the event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension View {
    func agentInputInteractiveHover(
        cornerRadius: CGFloat = 6,
        horizontalPadding: CGFloat = 0,
        verticalPadding: CGFloat = 0
    ) -> some View {
        modifier(
            AgentInputInteractiveHoverModifier(
                cornerRadius: cornerRadius,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}

public struct AgentLiveChangesBannerView: View {
    public let summary: AgentEditedFilesSummary
    public let theme: Theme
    public let accentColor: Color
    public var onReview: ((AgentEditedFilesSummary) -> Void)?

    @State private var isHovered: Bool = false

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.onReview = onReview
    }

    public var body: some View {
        Button(action: {
            onReview?(summary)
        }) {
            HStack(spacing: 8) {
                // Left section: pencil icon, files count, +/- counters
                HStack(spacing: 7) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accentColor)

                    Text(summary.files.count == 1 ? "1 file changed" : "\(summary.files.count) files changed")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))

                    if summary.totalAdditions > 0 {
                        Text("+\(summary.totalAdditions)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.28, green: 0.82, blue: 0.45))
                    }

                    if summary.totalDeletions > 0 {
                        Text("-\(summary.totalDeletions)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.96, green: 0.32, blue: 0.28))
                    }
                }

                Spacer(minLength: 8)

                // Right section: Review ↗
                HStack(spacing: 3) {
                    Text("Review")
                        .font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(accentColor.opacity(isHovered ? 0.12 : 0.05))
                    )
            )
            .shadow(
                color: accentColor.opacity(isHovered ? 0.14 : 0.04),
                radius: isHovered ? 8 : 4,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .overlay(AgentInputPointingHandCursorView())
        .help("Review live changes in MultiBuffer (Read-Only)")
    }
}

private struct AgentInputTotalHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct AgentInputQuoteBadgeView: View {
    let id: String
    let quote: SelectionQuote
    let theme: Theme
    let accentColor: Color
    let onRemove: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            Image(systemName: "quote.opening")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(quote.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)

                    if let range = quote.lineRange {
                        Text(range.lowerBound == range.upperBound ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                            .lineLimit(1)
                    }
                }

                let cleanText = quote.text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)

                Text(cleanText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isCloseHovered ? 1.0 : 0.75))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color(theme.foreground).opacity(isCloseHovered ? 0.12 : 0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Remove quote")
            .accessibilityLabel("Remove quote from \(quote.label)")
            .overlay(AgentInputPointingHandCursorView())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    isCloseHovered = hovering
                }
            }
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(theme.foreground).opacity(isHovered ? 0.05 : 0.03))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
