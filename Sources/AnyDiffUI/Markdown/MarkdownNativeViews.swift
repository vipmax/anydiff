import SwiftUI
import AppKit
import AnyDiffCore

// MARK: - Markdown Selectable Text View

public final class MarkdownSelectableTextView: NSTextView, NSTextViewDelegate {
    public var hasLinks: Bool = false
    private var cachedLinkRects: [NSRect]?
    private var lastCalculatedBoundsWidth: CGFloat = -1
    private var lastMeasuredWidth: CGFloat = -1
    private var cachedMeasuredHeight: CGFloat = 0

    public init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        self.delegate = self
        self.isEditable = false
        self.isSelectable = true
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
        self.backgroundColor = .clear
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

    public override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = bounds.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged {
            cachedLinkRects = nil
            lastMeasuredWidth = -1
            window?.invalidateCursorRects(for: self)
        }
    }

    public override func addTrackingArea(_ trackingArea: NSTrackingArea) {
        // AppKit's NSTextView automatically adds a tracking area with
        // .cursorUpdate | .mouseEnteredAndExited | .mouseMoved, which forces
        // NSCursor.iBeam over all text and causes rapid cursor flickering between arrow
        // and I-beam during hover and scroll.
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

    public override func resetCursorRects() {
        // Do not call super.resetCursorRects() to avoid adding an I-beam cursor over text.
        // Instead, explicitly add an arrow cursor for the entire view bounds so the pointer remains
        // a stable arrow everywhere, while clickable links show the pointing hand cursor.
        addCursorRect(bounds, cursor: .arrow)

        guard hasLinks else { return }
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return }

        let currentWidth = bounds.width
        if let cached = cachedLinkRects, abs(lastCalculatedBoundsWidth - currentWidth) < 0.5 {
            for rect in cached {
                addCursorRect(rect, cursor: .pointingHand)
            }
            return
        }

        var rects: [NSRect] = []
        ts.enumerateAttribute(.link, in: NSRange(location: 0, length: ts.length), options: []) { val, range, _ in
            guard val != nil else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                rects.append(rect)
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
        cachedLinkRects = rects
        lastCalculatedBoundsWidth = currentWidth
    }

    private func isOverLink(at pInTV: NSPoint) -> Bool {
        guard hasLinks else { return false }
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return false }
        let glyphIdx = lm.glyphIndex(for: pInTV, in: tc)
        guard glyphIdx < lm.numberOfGlyphs else { return false }
        let charIdx = lm.characterIndexForGlyph(at: glyphIdx)
        guard charIdx < ts.length else { return false }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: tc)
        return rect.contains(pInTV) && ts.attribute(.link, at: charIdx, effectiveRange: nil) != nil
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
            return true
        } else if let str = link as? String, let url = URL(string: str) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    public func measuredHeight(for width: CGFloat) -> CGFloat {
        if abs(lastMeasuredWidth - width) < 0.5 && cachedMeasuredHeight > 0 {
            return cachedMeasuredHeight
        }
        cachedLinkRects = nil
        guard let layoutManager, let textContainer, (textStorage?.length ?? 0) > 0 else {
            return 0
        }
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let h = max(18, ceil(used.height))
        lastMeasuredWidth = width
        cachedMeasuredHeight = h
        return h
    }

    public override func cancelOperation(_ sender: Any?) {
        if selectedRange().length > 0 {
            setSelectedRange(NSRange(location: NSNotFound, length: 0))
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }
}

// MARK: - Native Code Block View

public final class MarkdownNativeCodeBlockView: NSView {
    public let headerView = NSView()
    public let langLabel = NSTextField(labelWithString: "")
    public let copyButton = NSButton()
    public let dividerView = NSView()
    public let textView = MarkdownSelectableTextView()

    public private(set) var code: String = ""
    public private(set) var theme: Theme = .zedDark
    private var copyTimer: Timer?

    public init(language: String?, code: String, theme: Theme) {
        self.code = code
        self.theme = theme
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        updateColors()

        // Header view
        headerView.wantsLayer = true
        addSubview(headerView)

        langLabel.stringValue = (language?.isEmpty == false ? language! : "CODE").uppercased()
        langLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        langLabel.isEditable = false
        langLabel.isSelectable = false
        langLabel.drawsBackground = false
        headerView.addSubview(langLabel)

        copyButton.title = "Copy"
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        headerView.addSubview(copyButton)

        // Divider
        dividerView.wantsLayer = true
        addSubview(dividerView)

        // Text view
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textColor = theme.foreground
        addSubview(textView)

        highlightCode(language: language ?? "plaintext")
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public func updateTheme(_ newTheme: Theme, language: String?) {
        self.theme = newTheme
        lastMeasuredWidth = -1
        cachedMeasuredHeight = 0
        updateColors()
        highlightCode(language: language ?? "plaintext")
    }

    private func updateColors() {
        let codeBg = theme.gutterBackground.withAlphaComponent(0.40)
        let borderColor = theme.excerptHeaderBorder.withAlphaComponent(0.35)
        let headerBg = theme.gutterBackground.withAlphaComponent(0.75)
        let labelColor = theme.gutterForeground

        layer?.backgroundColor = codeBg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor

        headerView.layer?.backgroundColor = headerBg.cgColor
        dividerView.layer?.backgroundColor = borderColor.cgColor
        langLabel.textColor = labelColor
        copyButton.contentTintColor = labelColor
        textView.textColor = theme.foreground
    }

    private func highlightCode(language: String) {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lines = code.components(separatedBy: "\n")
        let full = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5

        for (i, line) in lines.enumerated() {
            let highlighted = SyntaxHighlighter.shared.highlight(line: line, language: language, font: font, theme: theme)
            let lineAttr = NSMutableAttributedString(attributedString: highlighted)
            lineAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: lineAttr.length))
            full.append(lineAttr)
            if i < lines.count - 1 {
                full.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        textView.textStorage?.setAttributedString(full)
    }

    @objc private func copyCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)

        copyButton.title = "Copied!"
        copyButton.contentTintColor = .systemGreen

        copyTimer?.invalidate()
        copyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.copyButton.title = "Copy"
            self.copyButton.contentTintColor = self.theme.gutterForeground
        }
    }

    private var lastMeasuredWidth: CGFloat = -1
    private var cachedMeasuredHeight: CGFloat = 0

    public func measuredHeight(for width: CGFloat) -> CGFloat {
        if abs(lastMeasuredWidth - width) < 0.5 && cachedMeasuredHeight > 0 {
            return cachedMeasuredHeight
        }
        let codeWidth = max(1, width - 24)
        textView.textContainer?.containerSize = NSSize(width: codeWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let codeHeight = ceil(textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 20) + 20
        let total = 28 + 1 + codeHeight
        lastMeasuredWidth = width
        cachedMeasuredHeight = total
        return total
    }

    public func applyLayout(width: CGFloat) {
        let totalHeight = measuredHeight(for: width)
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: totalHeight)

        headerView.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        langLabel.frame = NSRect(x: 12, y: 6, width: max(50, width - 80), height: 16)
        copyButton.frame = NSRect(x: width - 64, y: 5, width: 52, height: 18)

        dividerView.frame = NSRect(x: 0, y: 28, width: width, height: 1)

        let codeHeight = max(10, totalHeight - 29)
        textView.frame = NSRect(x: 0, y: 29, width: width, height: codeHeight)
    }
}

// MARK: - Native Image View

public final class MarkdownNativeImageView: NSView {
    public static let imageCache = NSCache<NSString, NSImage>()

    public let altText: String
    public let rawPath: String
    public let filePath: String
    public let rootDirectory: String
    public var theme: Theme
    public var onImageLoaded: (() -> Void)?

    private let imageView = NSImageView()
    private let placeholderView = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let statusIconView = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")

    public private(set) var loadedImage: NSImage?
    private var isDownloading = false
    private var loadFailed = false

    public init(
        altText: String,
        rawPath: String,
        filePath: String,
        rootDirectory: String,
        theme: Theme,
        onImageLoaded: (() -> Void)? = nil
    ) {
        self.altText = altText
        self.rawPath = rawPath
        self.filePath = filePath
        self.rootDirectory = rootDirectory
        self.theme = theme
        self.onImageLoaded = onImageLoaded
        super.init(frame: .zero)

        wantsLayer = true

        // Image view: standard AppKit component, completely immune to coordinate flips
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.toolTip = altText.isEmpty ? nil : altText
        addSubview(imageView)

        // Placeholder for loading or missing
        placeholderView.wantsLayer = true
        placeholderView.layer?.cornerRadius = 6

        // Progress indicator for remote downloads
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        placeholderView.addSubview(progressIndicator)

        // Status icon for failed or missing images
        statusIconView.wantsLayer = true
        statusIconView.imageScaling = .scaleProportionallyUpOrDown
        statusIconView.contentTintColor = theme.gutterForeground
        placeholderView.addSubview(statusIconView)

        placeholderLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.maximumNumberOfLines = 1
        placeholderView.addSubview(placeholderLabel)
        addSubview(placeholderView)

        updateTheme(theme)
        loadImage()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public func updateTheme(_ newTheme: Theme) {
        self.theme = newTheme
        let borderColor = theme.excerptHeaderBorder.withAlphaComponent(0.25)
        imageView.layer?.borderWidth = (loadedImage?.size.width ?? 0) > 120 ? 1 : 0
        imageView.layer?.borderColor = borderColor.cgColor

        let bg = theme.gutterBackground.withAlphaComponent(0.35)
        placeholderView.layer?.backgroundColor = bg.cgColor
        placeholderView.layer?.borderWidth = 1
        placeholderView.layer?.borderColor = borderColor.cgColor
        placeholderLabel.textColor = theme.gutterForeground
        statusIconView.contentTintColor = theme.gutterForeground
    }

    public func loadImage() {
        if let img = resolveLocalImage() {
            setLoadedImage(img)
            return
        }

        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            if let cached = Self.imageCache.object(forKey: rawPath as NSString) {
                setLoadedImage(cached)
                return
            }
            startRemoteDownload(from: rawPath)
            return
        }

        self.loadFailed = true
        updateVisibility()
    }

    private func setLoadedImage(_ img: NSImage) {
        self.loadedImage = img
        self.loadFailed = false
        self.isDownloading = false
        imageView.image = img
        updateTheme(theme)
        updateVisibility()
        onImageLoaded?()
    }

    private func updateVisibility() {
        if let _ = loadedImage {
            imageView.isHidden = false
            placeholderView.isHidden = true
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusIconView.isHidden = true
        } else if isDownloading {
            imageView.isHidden = true
            placeholderView.isHidden = false
            statusIconView.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
            let name = altText.isEmpty ? (rawPath as NSString).lastPathComponent : altText
            placeholderLabel.stringValue = "Loading \(name)..."
        } else {
            imageView.isHidden = true
            placeholderView.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            statusIconView.isHidden = false
            statusIconView.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "Image not found")
                ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Image not found")
            let name = altText.isEmpty ? (rawPath as NSString).lastPathComponent : altText
            placeholderLabel.stringValue = "Image: \(name) (not found)"
        }
    }

    private func resolveLocalImage() -> NSImage? {
        let cacheKey = "local:\(filePath):\(rawPath)" as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            return cached
        }
        let fileManager = FileManager.default
        let mdDir = (filePath as NSString).deletingLastPathComponent
        let candidate1 = (mdDir as NSString).appendingPathComponent(rawPath)
        if fileManager.fileExists(atPath: candidate1), let img = NSImage(contentsOfFile: candidate1) {
            Self.imageCache.setObject(img, forKey: cacheKey)
            return img
        }
        let candidate2 = (rootDirectory as NSString).appendingPathComponent(rawPath)
        if fileManager.fileExists(atPath: candidate2), let img = NSImage(contentsOfFile: candidate2) {
            Self.imageCache.setObject(img, forKey: cacheKey)
            return img
        }
        if rawPath.hasPrefix("file://"), let url = URL(string: rawPath), fileManager.fileExists(atPath: url.path), let img = NSImage(contentsOfFile: url.path) {
            Self.imageCache.setObject(img, forKey: cacheKey)
            return img
        }
        if (rawPath as NSString).isAbsolutePath && fileManager.fileExists(atPath: rawPath), let img = NSImage(contentsOfFile: rawPath) {
            Self.imageCache.setObject(img, forKey: cacheKey)
            return img
        }
        return nil
    }

    private func startRemoteDownload(from urlString: String) {
        guard let url = URL(string: urlString), !isDownloading else { return }
        isDownloading = true
        updateVisibility()

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let data, let img = NSImage(data: data) {
                Self.imageCache.setObject(img, forKey: urlString as NSString)
                DispatchQueue.main.async {
                    self.setLoadedImage(img)
                }
            } else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.loadFailed = true
                    self.updateVisibility()
                    self.onImageLoaded?()
                }
            }
        }.resume()
    }

    public func measuredSize(for maxWidth: CGFloat) -> NSSize {
        if let img = loadedImage {
            let imgWidth = max(1, img.size.width)
            let imgHeight = max(1, img.size.height)
            let aspect = imgWidth / imgHeight

            if imgHeight <= 36 {
                // Badges / small icons keep intrinsic dimensions
                return NSSize(width: imgWidth, height: imgHeight)
            } else {
                let maxRenderHeight: CGFloat = 720
                var renderWidth = min(maxWidth, imgWidth)
                var renderHeight = renderWidth / aspect
                if renderHeight > maxRenderHeight {
                    renderHeight = maxRenderHeight
                    renderWidth = renderHeight * aspect
                }
                return NSSize(width: ceil(renderWidth), height: ceil(renderHeight))
            }
        } else {
            let isBadge = rawPath.contains("shields.io") || rawPath.contains("badge") || rawPath.hasSuffix(".svg")
            let h: CGFloat = isBadge ? 24 : 36
            let w: CGFloat = isBadge ? 110 : min(maxWidth, 320)
            return NSSize(width: w, height: h)
        }
    }

    public func applyLayout(width: CGFloat) {
        if let _ = loadedImage {
            let size = measuredSize(for: width)
            imageView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        } else {
            let size = measuredSize(for: width)
            placeholderView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)

            let iconSize: CGFloat = 14
            let leftPad: CGFloat = 10
            let spacing: CGFloat = 7
            let midY = floor((size.height - iconSize) / 2.0)

            if isDownloading {
                progressIndicator.frame = NSRect(x: leftPad, y: midY, width: iconSize, height: iconSize)
            } else {
                statusIconView.frame = NSRect(x: leftPad, y: midY, width: iconSize, height: iconSize)
            }

            let textX = leftPad + iconSize + spacing
            let textW = max(20, size.width - textX - leftPad)
            let textH: CGFloat = 16
            let textY = floor((size.height - textH) / 2.0)
            placeholderLabel.frame = NSRect(x: textX, y: textY, width: textW, height: textH)
        }
    }
}

// MARK: - Native Image Group View (Flow Layout for Badges & Images)

public final class MarkdownNativeImageGroupView: NSView {
    public let imageViews: [MarkdownNativeImageView]

    public init(imageViews: [MarkdownNativeImageView]) {
        self.imageViews = imageViews
        super.init(frame: .zero)
        wantsLayer = true
        for iv in imageViews {
            addSubview(iv)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public func measuredHeight(for width: CGFloat) -> CGFloat {
        var curX: CGFloat = 0
        var curY: CGFloat = 0
        var rowHeight: CGFloat = 0
        let spacingX: CGFloat = 8
        let spacingY: CGFloat = 8

        for iv in imageViews {
            let size = iv.measuredSize(for: width)
            if size.width > width * 0.7 || size.height > 40 {
                // Large standalone image
                if curX > 0 {
                    curY += rowHeight + spacingY
                    curX = 0
                    rowHeight = 0
                }
                curY += size.height + spacingY
            } else {
                // Small badge: horizontal flow
                if curX + size.width > width && curX > 0 {
                    curY += rowHeight + spacingY
                    curX = 0
                    rowHeight = 0
                }
                curX += size.width + spacingX
                rowHeight = max(rowHeight, size.height)
            }
        }
        if curX > 0 {
            curY += rowHeight
        }
        return max(24, ceil(curY))
    }

    public func applyLayout(width: CGFloat) {
        var curX: CGFloat = 0
        var curY: CGFloat = 0
        var rowHeight: CGFloat = 0
        let spacingX: CGFloat = 8
        let spacingY: CGFloat = 8

        for iv in imageViews {
            let size = iv.measuredSize(for: width)
            if size.width > width * 0.7 || size.height > 40 {
                if curX > 0 {
                    curY += rowHeight + spacingY
                    curX = 0
                    rowHeight = 0
                }
                let originX = floor((width - size.width) / 2)
                iv.frame = NSRect(x: originX, y: curY, width: size.width, height: size.height)
                iv.applyLayout(width: size.width)
                curY += size.height + spacingY
            } else {
                if curX + size.width > width && curX > 0 {
                    curY += rowHeight + spacingY
                    curX = 0
                    rowHeight = 0
                }
                iv.frame = NSRect(x: curX, y: curY, width: size.width, height: size.height)
                iv.applyLayout(width: size.width)
                curX += size.width + spacingX
                rowHeight = max(rowHeight, size.height)
            }
        }
        if curX > 0 {
            curY += rowHeight
        }
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: max(24, curY))
    }
}

// MARK: - Native Divider View

public final class MarkdownNativeDividerView: NSView {
    public let lineView = NSView()

    public init(theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        lineView.wantsLayer = true
        updateTheme(theme)
        addSubview(lineView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public func updateTheme(_ theme: Theme) {
        let borderColor = theme.excerptHeaderBorder.withAlphaComponent(0.40)
        lineView.layer?.backgroundColor = borderColor.cgColor
    }

    public func applyLayout(width: CGFloat) {
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: width, height: 16)
        lineView.frame = NSRect(x: 0, y: 7.5, width: width, height: 1)
    }
}

// MARK: - Native Table Scroll View

public final class MarkdownTableScrollView: NSScrollView {
    public let hostingView: NSHostingView<MarkdownTableView>
    private var isRoutingToEnclosing: Bool = false

    public init(headers: [String], rows: [[String]], theme: Theme) {
        let tableView = MarkdownTableView(headers: headers, rows: rows, theme: theme)
        self.hostingView = NSHostingView(rootView: tableView)
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    private func setup() {
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        scrollerStyle = .overlay
        wantsLayer = true

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        clipView.wantsLayer = true
        self.contentView = clipView

        documentView = hostingView
    }

    public override var fittingSize: NSSize {
        hostingView.fittingSize
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            if !hasHorizontalScroller || abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
                isRoutingToEnclosing = true
            } else {
                isRoutingToEnclosing = false
            }
        }

        if isRoutingToEnclosing || !hasHorizontalScroller || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            if event.phase == .ended || event.phase == .cancelled || (event.phase == [] && event.momentumPhase == .ended) {
                isRoutingToEnclosing = false
            }
            if let enclosing = enclosingScrollView {
                enclosing.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
            return
        }

        if event.phase == .ended || event.phase == .cancelled || (event.phase == [] && event.momentumPhase == .ended) {
            isRoutingToEnclosing = false
        }

        super.scrollWheel(with: event)
    }
}

// MARK: - Markdown Inline Formatter

public enum MarkdownInlineFormatter {
    private static let rawLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func format(
        text: String,
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle,
        theme: Theme
    ) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]

        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let plain = String(parsed.characters)
        let result = NSMutableAttributedString(string: plain, attributes: baseAttributes)

        var currentOffset = 0
        for run in parsed.runs {
            let length = String(parsed.characters[run.range]).utf16.count
            guard length > 0 else { continue }
            let range = NSRange(location: currentOffset, length: length)
            currentOffset += length

            let intent = run.inlinePresentationIntent
            let link = run.link

            var runFont: NSFont = font
            if let intent = intent {
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: max(11, font.pointSize - 0.5), weight: .regular)
                    let codeBg = theme.gutterBackground.withAlphaComponent(0.65)
                    result.addAttribute(.backgroundColor, value: codeBg, range: range)
                } else {
                    let isBold = intent.contains(.stronglyEmphasized)
                    let isItalic = intent.contains(.emphasized)
                    if isBold && isItalic {
                        let base = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                        runFont = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                    } else if isBold {
                        runFont = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                    } else if isItalic {
                        runFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                }
                if intent.contains(.strikethrough) {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }

            if let link = link {
                let linkColor = NSColor.controlAccentColor
                result.addAttribute(.link, value: link, range: range)
                result.addAttribute(.foregroundColor, value: linkColor, range: range)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                result.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: range)
                result.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
                result.addAttribute(.toolTip, value: link.isFileURL ? link.path : link.absoluteString, range: range)
            }

            result.addAttribute(.font, value: runFont, range: range)
        }

        linkifyRawURLs(in: result)
        return result
    }

    private static func linkifyRawURLs(in attrString: NSMutableAttributedString) {
        guard let detector = rawLinkDetector else { return }
        let fullLength = (attrString.string as NSString).length
        guard fullLength > 0 else { return }
        let fullRange = NSRange(location: 0, length: fullLength)
        let matches = detector.matches(in: attrString.string, options: [], range: fullRange)

        for match in matches {
            guard let url = match.url else { continue }
            var hasLink = false
            attrString.enumerateAttribute(.link, in: match.range, options: []) { val, _, stop in
                if val != nil {
                    hasLink = true
                    stop.pointee = true
                }
            }
            if !hasLink {
                let linkColor = NSColor.controlAccentColor
                attrString.addAttribute(.link, value: url, range: match.range)
                attrString.addAttribute(.foregroundColor, value: linkColor, range: match.range)
                attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
                attrString.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: match.range)
                attrString.addAttribute(.cursor, value: NSCursor.pointingHand, range: match.range)
            }
        }
    }
}

// MARK: - Section Chunks

public enum MarkdownDocumentSection {
    case text(textView: MarkdownSelectableTextView, headerAnchors: [(headerIndex: Int, charRange: NSRange)])
    case codeBlock(view: MarkdownNativeCodeBlockView)
    case imageGroup(view: MarkdownNativeImageGroupView)
    case table(view: MarkdownTableScrollView)
    case divider(view: MarkdownNativeDividerView)

    public var view: NSView {
        switch self {
        case .text(let tv, _): return tv
        case .codeBlock(let cb): return cb
        case .imageGroup(let ig): return ig
        case .table(let tb): return tb
        case .divider(let dv): return dv
        }
    }
}

// MARK: - Markdown Native Container View

public final class MarkdownNativeContainerView: NSView {
    public private(set) var sections: [MarkdownDocumentSection] = []
    public private(set) var lastLayoutWidth: CGFloat = 0
    public var onNeedsLayout: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public private(set) var contentHeight: CGFloat = 0

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool { true }

    public func setSections(_ newSections: [MarkdownDocumentSection]) {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        self.sections = newSections
        for section in newSections {
            addSubview(section.view)
        }
        let width = (lastLayoutWidth > 100) ? lastLayoutWidth : (enclosingScrollView?.contentView.bounds.width ?? 0)
        if width > 100 {
            layoutContent(for: width)
        }
        updateVisibleSections(in: enclosingScrollView?.contentView)
    }

    public func layoutContent(for width: CGFloat) {
        guard width > 100 else { return }
        lastLayoutWidth = width
        let maxContentWidth: CGFloat = 860
        let horizontalPadding: CGFloat = 48
        let availableWidth = max(200, width - horizontalPadding * 2)
        let contentWidth = min(maxContentWidth, availableWidth)
        let contentX = max(horizontalPadding, floor((width - contentWidth) / 2))

        var currentY: CGFloat = 28
        let spacing: CGFloat = 14

        for (index, section) in sections.enumerated() {
            let sectionHeight: CGFloat
            switch section {
            case .text(let tv, _):
                sectionHeight = tv.measuredHeight(for: contentWidth)
                tv.frame = NSRect(x: contentX, y: currentY, width: contentWidth, height: sectionHeight)
                tv.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)

            case .codeBlock(let cb):
                sectionHeight = cb.measuredHeight(for: contentWidth)
                cb.frame = NSRect(x: contentX, y: currentY, width: contentWidth, height: sectionHeight)
                cb.applyLayout(width: contentWidth)

            case .imageGroup(let ig):
                sectionHeight = ig.measuredHeight(for: contentWidth)
                ig.frame = NSRect(x: contentX, y: currentY, width: contentWidth, height: sectionHeight)
                ig.applyLayout(width: contentWidth)

            case .table(let tb):
                let fitting = tb.hostingView.fittingSize
                let tableWidth = max(36, ceil(fitting.width))
                let tableHeight = max(36, ceil(fitting.height))

                if tableWidth > contentWidth {
                    tb.hasHorizontalScroller = true
                    tb.frame = NSRect(x: contentX, y: currentY, width: contentWidth, height: tableHeight)
                    tb.hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: tableHeight)
                } else {
                    tb.hasHorizontalScroller = false
                    tb.frame = NSRect(x: contentX, y: currentY, width: tableWidth, height: tableHeight)
                    tb.hostingView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: tableHeight)
                }
                sectionHeight = tableHeight

            case .divider(let dv):
                sectionHeight = 16
                dv.applyLayout(width: contentWidth)
                dv.frame = NSRect(x: contentX, y: currentY, width: contentWidth, height: sectionHeight)
            }

            currentY += sectionHeight
            if index < sections.count - 1 {
                currentY += spacing
            }
        }

        let bottomPadding: CGFloat = 36
        let totalHeight = sections.isEmpty ? 0 : (currentY + bottomPadding)
        contentHeight = totalHeight
        let minHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let finalHeight = max(totalHeight, minHeight)
        frame = NSRect(x: 0, y: 0, width: width, height: finalHeight)

        if let clipView = enclosingScrollView?.contentView {
            let maxOriginY = max(0, finalHeight - clipView.bounds.height)
            if clipView.bounds.origin.y > maxOriginY {
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maxOriginY))
            }
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        updateVisibleSections(in: enclosingScrollView?.contentView)
    }

    public func updateVisibleSections(in clipView: NSClipView?) {
        guard !sections.isEmpty else { return }
        let clip = clipView ?? enclosingScrollView?.contentView
        let vis = clip?.documentVisibleRect ?? bounds
        // 800px buffer above and below for smooth pre-rendering without jank
        let bufferRect = NSRect(
            x: 0,
            y: max(0, vis.minY - 800),
            width: max(vis.width, bounds.width),
            height: vis.height + 1600
        )

        for section in sections {
            let view = section.view
            let isVisible = view.frame.intersects(bufferRect)
            if isVisible {
                if view.isHidden {
                    view.isHidden = false
                }
            } else {
                if !view.isHidden {
                    view.isHidden = true
                }
            }
        }
    }

    public func updateMinHeight(_ minHeight: CGFloat) {
        let finalHeight = max(contentHeight, minHeight)
        if abs(frame.size.height - finalHeight) > 0.5 {
            frame.size.height = finalHeight
            if let clipView = enclosingScrollView?.contentView {
                let maxOriginY = max(0, finalHeight - clipView.bounds.height)
                if clipView.bounds.origin.y > maxOriginY {
                    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maxOriginY))
                }
                enclosingScrollView?.reflectScrolledClipView(clipView)
            }
            updateVisibleSections(in: enclosingScrollView?.contentView)
        }
    }

    public func yOffset(forHeaderAt headerIndex: Int) -> CGFloat? {
        for section in sections {
            if case .text(let tv, let anchors) = section {
                if let anchor = anchors.first(where: { $0.headerIndex == headerIndex }) {
                    if let layoutManager = tv.layoutManager, let textContainer = tv.textContainer {
                        let glyphRange = layoutManager.glyphRange(forCharacterRange: anchor.charRange, actualCharacterRange: nil)
                        let rectInTV = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                        return tv.frame.origin.y + rectInTV.origin.y
                    }
                    return tv.frame.origin.y
                }
            }
        }
        return nil
    }
}

// MARK: - Markdown Native Document Scroll View

public final class MarkdownNativeDocumentScrollView: NSScrollView {
    public let containerView = MarkdownNativeContainerView()
    public var onClose: (() -> Void)? = nil

    public override func cancelOperation(_ sender: Any?) {
        if let onClose {
            onClose()
        } else {
            super.cancelOperation(sender)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            if let onClose {
                onClose()
                return
            }
        }
        super.keyDown(with: event)
    }
    private var lastObservedWidth: CGFloat = -1
    private var lastObservedHeight: CGFloat = -1
    private var boundsChangeObserver: NSObjectProtocol?

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
        borderType = .noBorder
        scrollsDynamically = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

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
            guard let self else { return }
            self.containerView.updateVisibleSections(in: self.contentView)
        }

        documentView = containerView
        containerView.onNeedsLayout = { [weak self] in
            guard let self else { return }
            let width = self.contentView.bounds.width
            if width > 100 {
                self.containerView.layoutContent(for: width)
            }
        }
    }

    deinit {
        if let boundsChangeObserver {
            NotificationCenter.default.removeObserver(boundsChangeObserver)
        }
    }

    public override func layout() {
        super.layout()
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        if abs(width - lastObservedWidth) > 0.5 && width > 100 {
            lastObservedWidth = width
            lastObservedHeight = height
            containerView.layoutContent(for: width)
        } else if abs(height - lastObservedHeight) > 0.5 && height > 0 {
            lastObservedHeight = height
            containerView.updateMinHeight(height)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        if abs(width - lastObservedWidth) > 0.5 && width > 100 {
            lastObservedWidth = width
            lastObservedHeight = height
            containerView.layoutContent(for: width)
        } else if abs(height - lastObservedHeight) > 0.5 && height > 0 {
            lastObservedHeight = height
            containerView.updateMinHeight(height)
        }
    }

    public func scrollToHeader(at headerIndex: Int, animated: Bool = true) {
        guard let y = containerView.yOffset(forHeaderAt: headerIndex) else { return }
        let targetY = max(0, y - 24)
        let targetPoint = NSPoint(x: 0, y: targetY)

        containerView.updateVisibleSections(in: contentView)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                contentView.animator().setBoundsOrigin(targetPoint)
            }
        } else {
            contentView.scroll(to: targetPoint)
            reflectScrolledClipView(contentView)
            containerView.updateVisibleSections(in: contentView)
        }
    }
}

// MARK: - Section Compiler

public enum MarkdownSectionCompiler {
    public static func compile(
        blocks: [MarkdownBlock],
        theme: Theme,
        filePath: String,
        rootDirectory: String,
        onImageLoaded: (() -> Void)? = nil
    ) -> [MarkdownDocumentSection] {
        var sections: [MarkdownDocumentSection] = []

        var currentRichText = NSMutableAttributedString()
        var currentHeaderAnchors: [(headerIndex: Int, charRange: NSRange)] = []
        var headerCounter = 0
        var pendingImages: [MarkdownNativeImageView] = []

        func flushImages() {
            if !pendingImages.isEmpty {
                let group = MarkdownNativeImageGroupView(imageViews: pendingImages)
                sections.append(.imageGroup(view: group))
                pendingImages.removeAll()
            }
        }

        func flushText() {
            if currentRichText.length > 0 {
                var s = currentRichText.string
                while s.hasSuffix("\n") {
                    currentRichText.deleteCharacters(in: NSRange(location: currentRichText.length - 1, length: 1))
                    s = currentRichText.string
                }
                if currentRichText.length > 0 {
                    let tv = MarkdownSelectableTextView()
                    tv.textColor = theme.foreground
                    tv.textStorage?.setAttributedString(currentRichText)
                    var hasAnyLink = false
                    currentRichText.enumerateAttribute(.link, in: NSRange(location: 0, length: currentRichText.length), options: []) { val, _, stop in
                        if val != nil {
                            hasAnyLink = true
                            stop.pointee = true
                        }
                    }
                    tv.hasLinks = hasAnyLink
                    sections.append(.text(textView: tv, headerAnchors: currentHeaderAnchors))
                }
                currentRichText = NSMutableAttributedString()
                currentHeaderAnchors.removeAll()
            }
        }

        let textColor = theme.foreground
        let gutterColor = theme.gutterForeground

        for block in blocks {
            if case .image = block {
                // Image block handling
            } else {
                flushImages()
            }

            switch block {
            case .header(let level, let text):
                let (fontSize, weight, spacingBefore, spacingAfter): (CGFloat, NSFont.Weight, CGFloat, CGFloat) = {
                    switch level {
                    case 1: return (22, .bold, 24, 8)
                    case 2: return (18, .bold, 20, 6)
                    case 3: return (15.5, .semibold, 16, 4)
                    case 4: return (14, .semibold, 12, 4)
                    case 5: return (13, .bold, 10, 2)
                    default: return (12, .bold, 8, 2)
                    }
                }()

                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacingBefore = currentRichText.length > 0 ? spacingBefore : 0
                style.paragraphSpacing = spacingAfter

                let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
                let headerAttr = MarkdownInlineFormatter.format(
                    text: text,
                    font: font,
                    color: textColor,
                    paragraphStyle: style,
                    theme: theme
                )

                let startLoc = currentRichText.length
                currentHeaderAnchors.append((headerIndex: headerCounter, charRange: NSRange(location: startLoc, length: headerAttr.length)))
                headerCounter += 1

                currentRichText.append(headerAttr)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: font]))

                // For H1 and H2, insert a separator line directly underneath
                if level <= 2 {
                    flushText()
                    sections.append(.divider(view: MarkdownNativeDividerView(theme: theme)))
                }

            case .paragraph(let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3.5
                style.paragraphSpacing = 10
                let paraAttr = MarkdownInlineFormatter.format(
                    text: text,
                    font: NSFont.systemFont(ofSize: 13.5),
                    color: textColor,
                    paragraphStyle: style,
                    theme: theme
                )
                currentRichText.append(paraAttr)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13.5)]))

            case .bulletItem(let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 4
                style.firstLineHeadIndent = 0
                style.headIndent = 18

                let itemAttr: NSAttributedString
                if text.hasPrefix("☑ ") {
                    let mutable = NSMutableAttributedString()
                    mutable.append(NSAttributedString(string: "☑ ", attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                        .foregroundColor: NSColor.controlAccentColor,
                        .paragraphStyle: style
                    ]))
                    let body = MarkdownInlineFormatter.format(
                        text: String(text.dropFirst(2)),
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: gutterColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    let bodyMutable = NSMutableAttributedString(attributedString: body)
                    bodyMutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: bodyMutable.length))
                    mutable.append(bodyMutable)
                    itemAttr = mutable
                } else if text.hasPrefix("☐ ") {
                    let mutable = NSMutableAttributedString()
                    mutable.append(NSAttributedString(string: "☐ ", attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: gutterColor,
                        .paragraphStyle: style
                    ]))
                    let body = MarkdownInlineFormatter.format(
                        text: String(text.dropFirst(2)),
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: textColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    mutable.append(body)
                    itemAttr = mutable
                } else {
                    let mutable = NSMutableAttributedString()
                    mutable.append(NSAttributedString(string: "•  ", attributes: [
                        .font: NSFont.systemFont(ofSize: 13.5, weight: .bold),
                        .foregroundColor: gutterColor,
                        .paragraphStyle: style
                    ]))
                    let body = MarkdownInlineFormatter.format(
                        text: text,
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: textColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    mutable.append(body)
                    itemAttr = mutable
                }
                currentRichText.append(itemAttr)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13.5)]))

            case .numberedItem(let number, let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 4
                style.firstLineHeadIndent = 0
                style.headIndent = number.count > 1 ? 26 : 20

                let mutable = NSMutableAttributedString()
                mutable.append(NSAttributedString(string: "\(number).  ", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: gutterColor,
                    .paragraphStyle: style
                ]))

                if text.hasPrefix("☑ ") {
                    let body = MarkdownInlineFormatter.format(
                        text: String(text.dropFirst(2)),
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: gutterColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    let bodyMutable = NSMutableAttributedString(attributedString: body)
                    bodyMutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: bodyMutable.length))
                    mutable.append(bodyMutable)
                } else if text.hasPrefix("☐ ") {
                    let body = MarkdownInlineFormatter.format(
                        text: String(text.dropFirst(2)),
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: textColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    mutable.append(body)
                } else {
                    let body = MarkdownInlineFormatter.format(
                        text: text,
                        font: NSFont.systemFont(ofSize: 13.5),
                        color: textColor,
                        paragraphStyle: style,
                        theme: theme
                    )
                    mutable.append(body)
                }
                currentRichText.append(mutable)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13.5)]))

            case .quote(let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 6
                style.firstLineHeadIndent = 0
                style.headIndent = 16

                let mutable = NSMutableAttributedString()
                mutable.append(NSAttributedString(string: "▎ ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor,
                    .paragraphStyle: style
                ]))
                let quoteBody = MarkdownInlineFormatter.format(
                    text: text,
                    font: NSFont.systemFont(ofSize: 13),
                    color: textColor.withAlphaComponent(0.9),
                    paragraphStyle: style,
                    theme: theme
                )
                mutable.append(quoteBody)
                currentRichText.append(mutable)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))

            case .divider:
                flushText()
                sections.append(.divider(view: MarkdownNativeDividerView(theme: theme)))

            case .codeBlock(let language, let code):
                flushText()
                sections.append(.codeBlock(view: MarkdownNativeCodeBlockView(language: language, code: code, theme: theme)))

            case .image(let alt, let path):
                flushText()
                let iv = MarkdownNativeImageView(
                    altText: alt,
                    rawPath: path,
                    filePath: filePath,
                    rootDirectory: rootDirectory,
                    theme: theme,
                    onImageLoaded: onImageLoaded
                )
                pendingImages.append(iv)

            case .table(let headers, let rows):
                flushText()
                let tableView = MarkdownTableScrollView(headers: headers, rows: rows, theme: theme)
                sections.append(.table(view: tableView))
            }
        }

        flushImages()
        flushText()
        return sections
    }
}

// MARK: - Markdown Native Scroll View Representable

public struct MarkdownNativeScrollViewRepresentable: NSViewRepresentable {
    public let blocks: [MarkdownBlock]
    public let theme: Theme
    public let filePath: String
    public let rootDirectory: String
    public let scrollToHeaderIndex: Int?
    public var onClose: (() -> Void)?

    public init(
        blocks: [MarkdownBlock],
        theme: Theme,
        filePath: String,
        rootDirectory: String,
        scrollToHeaderIndex: Int?,
        onClose: (() -> Void)? = nil
    ) {
        self.blocks = blocks
        self.theme = theme
        self.filePath = filePath
        self.rootDirectory = rootDirectory
        self.scrollToHeaderIndex = scrollToHeaderIndex
        self.onClose = onClose
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var lastBlocksCount: Int = -1
        var lastBlocksHash: Int = 0
        var lastThemeId: String = ""
        var lastFilePath: String = ""
        var lastScrollToHeaderIndex: Int? = nil

        func needsUpdate(blocks: [MarkdownBlock], theme: Theme, filePath: String) -> Bool {
            var hasher = Hasher()
            hasher.combine(blocks.count)
            for block in blocks {
                hasher.combine(block.id)
            }
            let hash = hasher.finalize()
            if blocks.count != lastBlocksCount || hash != lastBlocksHash || theme.id != lastThemeId || filePath != lastFilePath {
                lastBlocksCount = blocks.count
                lastBlocksHash = hash
                lastThemeId = theme.id
                lastFilePath = filePath
                return true
            }
            return false
        }
    }

    public func makeNSView(context: Context) -> MarkdownNativeDocumentScrollView {
        let scrollView = MarkdownNativeDocumentScrollView()
        scrollView.onClose = onClose
        scrollView.backgroundColor = theme.background
        _ = context.coordinator.needsUpdate(blocks: blocks, theme: theme, filePath: filePath)

        let sections = MarkdownSectionCompiler.compile(
            blocks: blocks,
            theme: theme,
            filePath: filePath,
            rootDirectory: rootDirectory,
            onImageLoaded: { [weak scrollView] in
                guard let scrollView else { return }
                let width = scrollView.contentView.bounds.width
                let effectiveWidth = width > 100 ? width : (scrollView.containerView.lastLayoutWidth > 100 ? scrollView.containerView.lastLayoutWidth : scrollView.bounds.width)
                if effectiveWidth > 100 {
                    scrollView.containerView.layoutContent(for: effectiveWidth)
                }
            }
        )
        scrollView.containerView.setSections(sections)
        return scrollView
    }

    public func updateNSView(_ scrollView: MarkdownNativeDocumentScrollView, context: Context) {
        scrollView.onClose = onClose
        let themeChanged = theme.id != context.coordinator.lastThemeId
        if themeChanged {
            scrollView.backgroundColor = theme.background
        }

        if context.coordinator.needsUpdate(blocks: blocks, theme: theme, filePath: filePath) {
            let sections = MarkdownSectionCompiler.compile(
                blocks: blocks,
                theme: theme,
                filePath: filePath,
                rootDirectory: rootDirectory,
                onImageLoaded: { [weak scrollView] in
                    guard let scrollView else { return }
                    let width = scrollView.contentView.bounds.width
                    let effectiveWidth = width > 100 ? width : (scrollView.containerView.lastLayoutWidth > 100 ? scrollView.containerView.lastLayoutWidth : scrollView.bounds.width)
                    if effectiveWidth > 100 {
                        scrollView.containerView.layoutContent(for: effectiveWidth)
                    }
                }
            )
            scrollView.containerView.setSections(sections)
            let width = scrollView.contentView.bounds.width
            if width > 100 {
                scrollView.containerView.layoutContent(for: width)
            }
        }

        if let headerIdx = scrollToHeaderIndex, headerIdx != context.coordinator.lastScrollToHeaderIndex {
            context.coordinator.lastScrollToHeaderIndex = headerIdx
            scrollView.scrollToHeader(at: headerIdx, animated: true)
        }
    }
}
