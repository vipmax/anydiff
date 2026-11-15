import AppKit
import AnyDiffCore

public final class MermaidHorizontalScrollView: NSScrollView {
    public override func scrollWheel(with event: NSEvent) {
        let docW = documentView?.bounds.width ?? 0
        let clipW = contentView.bounds.width
        let canScrollX = docW > clipW + 1
        let isHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)

        if isHorizontal && canScrollX {
            super.scrollWheel(with: event)
        } else if let enclosing = enclosingScrollView {
            enclosing.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

public final class MermaidVectorView: NSView {
    public override var isFlipped: Bool { true }
    public var diagram: MermaidLayoutDiagram? {
        didSet { needsDisplay = true }
    }
    public var palette: MermaidThemePalette? {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.size.width - newSize.width) > 0.25 || abs(frame.size.height - newSize.height) > 0.25
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let diagram,
              let palette,
              let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }
        let natural = diagram.size
        guard natural.width > 1, natural.height > 1, bounds.width > 1, bounds.height > 1 else {
            return
        }

        let scale = min(bounds.width / natural.width, bounds.height / natural.height)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        MermaidCGContextRenderer.draw(diagram, in: ctx, palette: palette)
        ctx.restoreGState()
    }
}

public final class MermaidDiagramCanvasView: NSView {
    public override var isFlipped: Bool { true }
    public let vectorView = MermaidVectorView()
    public var onClickZoom: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(vectorView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func resetCursorRects() {
        discardCursorRects()
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 1, vectorView.diagram != nil {
            let loc = convert(event.locationInWindow, from: nil)
            if bounds.contains(loc) {
                onClickZoom?()
            }
        }
    }
}

public final class MermaidBlockView: NSView {
    public override var isFlipped: Bool { true }

    public private(set) var code: String
    public private(set) var theme: Theme
    public var maxDiagramHeight: CGFloat = 480
    public var maxCodeHeight: CGFloat = 340
    public var allowsCodeScrolling: Bool = true
    public var onNeedsLayout: (() -> Void)?
    public var onZoomDiagram: ((String) -> Void)?

    private let headerView = NSView()
    private let dividerView = NSView()
    private let langLabel = NSTextField(labelWithString: "MERMAID")
    private let diagramTabButton = NSButton()
    private let codeTabButton = NSButton()
    private let zoomButton = NSButton()
    private let copyButton = NSButton()

    private let diagramScrollView = MermaidHorizontalScrollView()
    private let diagramCanvas = MermaidDiagramCanvasView()
    private let loadingLabel = NSTextField(labelWithString: "Rendering diagram...")

    private let codeScrollView = NSScrollView()
    public let codeTextView = NSTextView()

    private var isShowingCode: Bool = false
    private var renderResult: MermaidRenderResult?
    private var activeRequestToken: UUID?
    private var copyTimer: Timer?

    private var cachedMeasuredWidth: CGFloat = -1
    private var cachedMeasuredHeight: CGFloat = 0

    public init(
        code: String,
        theme: Theme,
        maxDiagramHeight: CGFloat = 480,
        maxCodeHeight: CGFloat = 340,
        allowsCodeScrolling: Bool = true
    ) {
        self.code = code
        self.theme = theme
        self.maxDiagramHeight = maxDiagramHeight
        self.maxCodeHeight = maxCodeHeight
        self.allowsCodeScrolling = allowsCodeScrolling
        super.init(frame: .zero)
        setupViews()
        applyThemeColors()
        rebuildCodeText()
        startRenderIfNeeded()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        copyTimer?.invalidate()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        headerView.wantsLayer = true
        addSubview(headerView)

        dividerView.wantsLayer = true
        addSubview(dividerView)

        langLabel.isBezeled = false
        langLabel.drawsBackground = false
        langLabel.isEditable = false
        langLabel.isSelectable = false
        langLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        headerView.addSubview(langLabel)

        configureTabButton(diagramTabButton, title: "Diagram", action: #selector(selectDiagramTab))
        configureTabButton(codeTabButton, title: "Code", action: #selector(selectCodeTab))
        headerView.addSubview(diagramTabButton)
        headerView.addSubview(codeTabButton)

        zoomButton.isBordered = false
        zoomButton.setButtonType(.momentaryPushIn)
        zoomButton.focusRingType = .none
        zoomButton.imagePosition = .imageOnly
        zoomButton.imageScaling = .scaleProportionallyDown
        zoomButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Zoom diagram")
        zoomButton.toolTip = "Zoom diagram"
        zoomButton.target = self
        zoomButton.action = #selector(handleZoom)
        headerView.addSubview(zoomButton)

        copyButton.isBordered = false
        copyButton.setButtonType(.momentaryPushIn)
        copyButton.focusRingType = .none
        copyButton.title = "Copy"
        copyButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        headerView.addSubview(copyButton)

        // Diagram horizontal scroll container
        diagramScrollView.hasVerticalScroller = false
        diagramScrollView.hasHorizontalScroller = true
        diagramScrollView.autohidesScrollers = true
        diagramScrollView.scrollerStyle = .overlay
        diagramScrollView.drawsBackground = false
        diagramScrollView.borderType = .noBorder
        let diagramClip = NSClipView()
        diagramClip.drawsBackground = false
        diagramScrollView.contentView = diagramClip
        diagramScrollView.documentView = diagramCanvas
        addSubview(diagramScrollView)

        diagramCanvas.onClickZoom = { [weak self] in
            self?.handleZoom()
        }

        loadingLabel.isBezeled = false
        loadingLabel.drawsBackground = false
        loadingLabel.isEditable = false
        loadingLabel.isSelectable = false
        loadingLabel.alignment = .center
        loadingLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        addSubview(loadingLabel)

        // Code view
        codeScrollView.hasVerticalScroller = allowsCodeScrolling
        codeScrollView.hasHorizontalScroller = false
        codeScrollView.autohidesScrollers = true
        codeScrollView.scrollerStyle = .overlay
        codeScrollView.drawsBackground = false
        codeScrollView.borderType = .noBorder
        let codeClip = NSClipView()
        codeClip.drawsBackground = false
        codeScrollView.contentView = codeClip

        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.drawsBackground = false
        codeTextView.isContinuousSpellCheckingEnabled = false
        codeTextView.isGrammarCheckingEnabled = false
        codeTextView.isAutomaticQuoteSubstitutionEnabled = false
        codeTextView.isAutomaticDashSubstitutionEnabled = false
        codeTextView.isAutomaticLinkDetectionEnabled = false
        codeTextView.textContainerInset = NSSize(width: 12, height: 10)
        codeTextView.textContainer?.lineFragmentPadding = 0
        codeTextView.textContainer?.widthTracksTextView = false
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = false
        codeScrollView.documentView = codeTextView
        addSubview(codeScrollView)

        updateModeVisibility()
    }

    private func configureTabButton(_ button: NSButton, title: String, action: Selector) {
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.title = title
        button.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        button.target = self
        button.action = action
    }

    public func update(code newCode: String, theme newTheme: Theme) {
        let codeChanged = newCode != code
        let themeChanged = newTheme.id != theme.id
        guard codeChanged || themeChanged else { return }

        self.code = newCode
        self.theme = newTheme
        invalidateMeasurement()
        applyThemeColors()

        if codeChanged || themeChanged {
            rebuildCodeText()
            renderResult = nil
            startRenderIfNeeded()
        }
        updateModeVisibility()
    }

    private func invalidateMeasurement() {
        cachedMeasuredWidth = -1
        cachedMeasuredHeight = 0
    }

    private func applyThemeColors() {
        let bg = theme.gutterBackground.withAlphaComponent(0.35)
        let border = theme.excerptHeaderBorder.withAlphaComponent(0.35)
        let headerBg = theme.gutterBackground.withAlphaComponent(0.75)
        let muted = theme.gutterForeground

        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor
        headerView.layer?.backgroundColor = headerBg.cgColor
        dividerView.layer?.backgroundColor = border.cgColor
        langLabel.textColor = muted
        loadingLabel.textColor = muted
        zoomButton.contentTintColor = muted
        copyButton.contentTintColor = muted
        codeTextView.textColor = theme.foreground

        updateTabButtonStyles()
    }

    private func updateTabButtonStyles() {
        let activeBg = theme.accentColor.withAlphaComponent(theme.isDark ? 0.25 : 0.16)
        let activeFg = theme.foreground
        let inactiveFg = theme.gutterForeground

        let diagramSelected = !isShowingCode
        diagramTabButton.layer?.backgroundColor = diagramSelected ? activeBg.cgColor : NSColor.clear.cgColor
        diagramTabButton.attributedTitle = NSAttributedString(string: "Diagram", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: diagramSelected ? .semibold : .medium),
            .foregroundColor: diagramSelected ? activeFg : inactiveFg
        ])

        let codeSelected = isShowingCode
        codeTabButton.layer?.backgroundColor = codeSelected ? activeBg.cgColor : NSColor.clear.cgColor
        codeTabButton.attributedTitle = NSAttributedString(string: "Code", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: codeSelected ? .semibold : .medium),
            .foregroundColor: codeSelected ? activeFg : inactiveFg
        ])
    }

    private func rebuildCodeText() {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        let attr = NSMutableAttributedString()
        let lines = code.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let highlighted = SyntaxHighlighter.shared.highlight(line: line, language: "mermaid", font: font, theme: theme)
            let lineAttr = NSMutableAttributedString(attributedString: highlighted)
            lineAttr.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: lineAttr.length))
            attr.append(lineAttr)
            if i < lines.count - 1 {
                attr.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            }
        }
        codeTextView.textStorage?.setAttributedString(attr)
    }

    private func startRenderIfNeeded() {
        let layoutTargetWidth: CGFloat = 760
        if let cached = MermaidRenderCache.shared.cachedResult(code: code, theme: theme, maxWidth: layoutTargetWidth) {
            applyRenderResult(cached, notifyLayout: false)
            return
        }

        let token = UUID()
        activeRequestToken = token
        MermaidRenderCache.shared.renderAsync(code: code, theme: theme, maxWidth: layoutTargetWidth) { [weak self] result in
            guard let self, self.activeRequestToken == token else { return }
            self.applyRenderResult(result, notifyLayout: true)
        }
    }

    private func applyRenderResult(_ result: MermaidRenderResult, notifyLayout: Bool) {
        self.renderResult = result
        if case .diagram(let diagram, let palette) = result {
            diagramCanvas.vectorView.diagram = diagram
            diagramCanvas.vectorView.palette = palette
        } else {
            diagramCanvas.vectorView.diagram = nil
            diagramCanvas.vectorView.palette = nil
        }
        invalidateMeasurement()
        updateModeVisibility()
        if notifyLayout {
            onNeedsLayout?()
        }
    }

    private func hasFailedRender() -> Bool {
        if case .failure = renderResult { return true }
        return false
    }

    private func effectiveShowsCode() -> Bool {
        isShowingCode || hasFailedRender()
    }

    private func updateModeVisibility() {
        let showCode = effectiveShowsCode()
        let failed = hasFailedRender()
        let hasDiagram: Bool
        if case .diagram = renderResult { hasDiagram = true } else { hasDiagram = false }

        diagramTabButton.isHidden = failed
        codeTabButton.isHidden = failed
        zoomButton.isHidden = showCode || !hasDiagram || onZoomDiagram == nil

        diagramScrollView.isHidden = showCode || !hasDiagram
        loadingLabel.isHidden = showCode || hasDiagram || failed
        codeScrollView.isHidden = !showCode

        updateTabButtonStyles()
    }

    // MARK: - Actions

    @objc private func selectDiagramTab() {
        guard isShowingCode else { return }
        isShowingCode = false
        invalidateMeasurement()
        updateModeVisibility()
        onNeedsLayout?()
    }

    @objc private func selectCodeTab() {
        guard !isShowingCode else { return }
        isShowingCode = true
        invalidateMeasurement()
        updateModeVisibility()
        onNeedsLayout?()
    }

    @objc private func handleZoom() {
        onZoomDiagram?(code)
    }

    @objc private func handleCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)

        copyButton.attributedTitle = NSAttributedString(string: "Copied!", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ])
        copyTimer?.invalidate()
        copyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.copyButton.attributedTitle = NSAttributedString(string: "Copy", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: self.theme.gutterForeground
            ])
        }
    }

    // MARK: - Sizing & Layout

    private func fittedDiagramSize(for availableWidth: CGFloat, naturalSize: CGSize) -> CGSize {
        let innerWidth = max(120, availableWidth - 16)
        var scale: CGFloat = 1.0
        // Scale down gently up to ~0.78x so wide diagrams fit nicely without becoming tiny;
        // diagrams much wider than availableWidth remain horizontally scrollable at 0.78x.
        if naturalSize.width > innerWidth {
            scale = max(0.78, innerWidth / naturalSize.width)
        }
        if maxDiagramHeight > 0 && maxDiagramHeight < 10_000 && naturalSize.height * scale > maxDiagramHeight {
            scale = min(scale, maxDiagramHeight / naturalSize.height)
        }
        return CGSize(
            width: ceil(naturalSize.width * scale),
            height: ceil(naturalSize.height * scale)
        )
    }

    public func measuredHeight(for width: CGFloat) -> CGFloat {
        if abs(cachedMeasuredWidth - width) < 0.5 && cachedMeasuredHeight > 0 {
            return cachedMeasuredHeight
        }

        let headerH: CGFloat = 29
        let bodyH: CGFloat
        if effectiveShowsCode() {
            let textW = max(80, width - 24)
            codeTextView.textContainer?.containerSize = NSSize(width: textW, height: .greatestFiniteMagnitude)
            if let lm = codeTextView.layoutManager, let tc = codeTextView.textContainer {
                lm.ensureLayout(for: tc)
                let textH = ceil(lm.usedRect(for: tc).height + 20)
                bodyH = allowsCodeScrolling ? min(maxCodeHeight, max(44, textH)) : max(44, textH)
            } else {
                bodyH = 80
            }
        } else if case .diagram(let diagram, _) = renderResult {
            let fitted = fittedDiagramSize(for: width, naturalSize: diagram.size)
            bodyH = max(60, fitted.height + 20)
        } else {
            bodyH = 68
        }

        let total = headerH + bodyH
        cachedMeasuredWidth = width
        cachedMeasuredHeight = total
        return total
    }

    public func applyLayout(width: CGFloat) {
        let totalH = measuredHeight(for: width)
        let headerH: CGFloat = 28
        headerView.frame = NSRect(x: 0, y: 0, width: width, height: headerH)
        dividerView.frame = NSRect(x: 0, y: headerH, width: width, height: 1)

        langLabel.frame = NSRect(x: 10, y: 6, width: 62, height: 16)

        if !diagramTabButton.isHidden {
            diagramTabButton.frame = NSRect(x: 74, y: 4, width: 58, height: 20)
            codeTabButton.frame = NSRect(x: 136, y: 4, width: 44, height: 20)
        }

        copyButton.frame = NSRect(x: width - 58, y: 5, width: 50, height: 18)
        zoomButton.frame = NSRect(x: width - 82, y: 5, width: 22, height: 18)

        let bodyY: CGFloat = headerH + 1
        let bodyH = max(20, totalH - bodyY)
        let bodyFrame = NSRect(x: 0, y: bodyY, width: width, height: bodyH)

        if effectiveShowsCode() {
            codeScrollView.frame = bodyFrame
            let textW = max(80, width - 24)
            codeTextView.textContainer?.containerSize = NSSize(width: textW, height: .greatestFiniteMagnitude)
            let docH: CGFloat
            if let lm = codeTextView.layoutManager, let tc = codeTextView.textContainer {
                lm.ensureLayout(for: tc)
                docH = max(bodyH, ceil(lm.usedRect(for: tc).height + 20))
            } else {
                docH = bodyH
            }
            codeTextView.frame = NSRect(x: 0, y: 0, width: width, height: docH)
        } else if case .diagram(let diagram, _) = renderResult {
            diagramScrollView.frame = bodyFrame
            let fitted = fittedDiagramSize(for: width, naturalSize: diagram.size)
            let canvasW = max(width, fitted.width + 16)
            let canvasH = bodyH
            diagramCanvas.frame = NSRect(x: 0, y: 0, width: canvasW, height: canvasH)
            let imgX = floor((canvasW - fitted.width) / 2)
            let imgY = floor((canvasH - fitted.height) / 2)
            diagramCanvas.vectorView.frame = NSRect(x: imgX, y: imgY, width: fitted.width, height: fitted.height)
        } else {
            loadingLabel.frame = NSRect(x: 12, y: bodyY + floor((bodyH - 18) / 2), width: max(40, width - 24), height: 18)
        }
    }
}
