import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

/// Chevron rendered into a fixed-size canvas so `chevron.right` and `chevron.down`
/// occupy the same width and the adjacent title does not shift on toggle.
func agentFixedWidthChevron(expanded: Bool, pointSize: CGFloat, description: String) -> NSImage? {
    let name = expanded ? "chevron.down" : "chevron.right"
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
        .withSymbolConfiguration(config) else { return nil }
    let canvas = NSSize(width: ceil(pointSize * 1.3), height: ceil(pointSize * 1.3))
    let image = NSImage(size: canvas, flipped: false) { rect in
        let size = symbol.size
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: size))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
}

public final class AgentCodeBlockHeaderView: AgentFlippedView {
    public let langLabel = AgentStaticTextField(labelWithString: "")
    public let toggleButton = AgentHoverButton()
    public let copyBtn = AgentHoverButton()
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
        toggleButton.image = agentFixedWidthChevron(
            expanded: expanded,
            pointSize: 9,
            description: expanded ? "Collapse code block" : "Expand code block"
        )
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
        copyBtn.alphaValue = 1.0
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        copyBtn.alphaValue = 0.0
    }
}

public final class AgentCodeBlockView: AgentFlippedView {
    public let header = AgentCodeBlockHeaderView()
    public let codeScrollView = NSScrollView()
    public let tv = AgentSelectableTextView()
    public var isExpanded: Bool { header.isExpanded }
}

public final class AgentCodeBlockScrollView: NSScrollView {
    public override func scrollWheel(with event: NSEvent) {
        let docH = documentView?.bounds.height ?? 0
        let clipH = contentView.bounds.height
        let docW = documentView?.bounds.width ?? 0
        let clipW = contentView.bounds.width
        let canScrollY = docH > clipH + 1
        let canScrollX = docW > clipW + 1
        let isVertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)

        if (isVertical && canScrollY) || (!isVertical && canScrollX) {
            super.scrollWheel(with: event)
        } else if let sv = enclosingScrollView {
            sv.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

public final class AgentUserCodeBlockView: AgentFlippedView {
    public let codeScrollView = AgentCodeBlockScrollView()
    public let tv = AgentSelectableTextView()
    public let copyBtn = AgentHoverButton()
    public let langLabel = AgentStaticTextField(labelWithString: "")
    private var rawCode: String = ""
    private var contentTextHeight: CGFloat = 0
    private var cachedHeight: CGFloat = 0

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
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        codeScrollView.hasVerticalScroller = true
        codeScrollView.hasHorizontalScroller = true
        codeScrollView.autohidesScrollers = true
        codeScrollView.scrollerStyle = .overlay
        codeScrollView.drawsBackground = false
        codeScrollView.borderType = .noBorder
        codeScrollView.contentView = FlippedClipView()

        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true

        codeScrollView.documentView = tv
        addSubview(codeScrollView)

        langLabel.isBezeled = false
        langLabel.drawsBackground = false
        langLabel.isEditable = false
        langLabel.isSelectable = false
        langLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
        addSubview(langLabel)

        copyBtn.isBordered = false
        copyBtn.setButtonType(.momentaryPushIn)
        copyBtn.target = self
        copyBtn.action = #selector(handleCopy)
        copyBtn.toolTip = "Copy code"
        if let copyImg = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code") {
            copyBtn.image = copyImg
            copyBtn.imageScaling = .scaleProportionallyDown
            copyBtn.imagePosition = .imageOnly
        } else {
            copyBtn.title = "Copy"
            copyBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        }
        addSubview(copyBtn)
    }

    public func configure(
        code: String,
        language: String?,
        theme: Theme,
        accentColor: Color,
        messageId: UUID,
        index: Int,
        parentCell: AgentMessageCell
    ) {
        self.rawCode = code
        tv.parentCell = parentCell
        tv.cellId = messageId
        tv.tvKey = "user_code_\(index)"

        let bg = (NSColor(cgColor: theme.background.cgColor) ?? .black).withAlphaComponent(0.40)
        layer?.backgroundColor = bg.cgColor
        let border = (NSColor(cgColor: theme.excerptHeaderBorder.cgColor) ?? .white).withAlphaComponent(0.20)
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1

        let labelColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor).withAlphaComponent(0.75)
        langLabel.textColor = labelColor
        let detectedLang = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        langLabel.stringValue = (detectedLang?.isEmpty == false) ? detectedLang!.uppercased() : ""
        langLabel.isHidden = langLabel.stringValue.isEmpty

        copyBtn.contentTintColor = labelColor

        let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let langForSyntax = (detectedLang?.isEmpty == false) ? detectedLang! : "plaintext"
        let normalized = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let cleanCode = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized
        let lines = cleanCode.components(separatedBy: "\n")
        let attr = NSMutableAttributedString()
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 2.5

        for (i, line) in lines.enumerated() {
            let highlighted = SyntaxHighlighter.shared.highlight(
                line: line,
                language: langForSyntax,
                font: codeFont,
                theme: theme
            )
            let lineAttr = NSMutableAttributedString(attributedString: highlighted)
            lineAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: lineAttr.length))
            attr.append(lineAttr)
            if i < lines.count - 1 {
                attr.append(NSAttributedString(string: "\n", attributes: [.font: codeFont, .paragraphStyle: pStyle]))
            }
        }
        tv.textStorage?.setAttributedString(attr)

        let hasHeader = !langLabel.isHidden
        let headerH: CGFloat = hasHeader ? 22 : 6

        let textHeight: CGFloat
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            let usedRect = lm.usedRect(for: tc)
            let calculated = ceil(usedRect.height) + tv.textContainerInset.height * 2
            textHeight = max(CGFloat(lines.count) * 17.5 + tv.textContainerInset.height * 2, calculated)
        } else {
            textHeight = CGFloat(lines.count) * 17.5 + tv.textContainerInset.height * 2
        }

        self.contentTextHeight = textHeight
        let totalH = headerH + textHeight + 8
        self.cachedHeight = min(200, max(42, totalH))
    }

    public func height(for width: CGFloat) -> CGFloat {
        cachedHeight
    }

    public func applyLayout(width: CGFloat) {
        let hasHeader = !langLabel.isHidden
        let headerH: CGFloat = hasHeader ? 22 : 6
        let totalH = cachedHeight

        if hasHeader {
            langLabel.frame = NSRect(x: 10, y: 3, width: max(50, width - 60), height: 16)
        }
        copyBtn.frame = NSRect(x: max(10, width - 26), y: 3, width: 20, height: 18)

        let scrollY = hasHeader ? headerH : 4
        let scrollH = max(20, totalH - scrollY - 4)
        codeScrollView.frame = NSRect(x: 0, y: scrollY, width: width, height: scrollH)

        if let lm = tv.layoutManager, let tc = tv.textContainer {
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            let usedRect = lm.usedRect(for: tc)
            let tvW = max(width, ceil(usedRect.width) + tv.textContainerInset.width * 2)
            let calculatedH = ceil(usedRect.height) + tv.textContainerInset.height * 2
            let tvH = max(scrollH, max(contentTextHeight, calculatedH))
            tv.frame = NSRect(x: 0, y: 0, width: tvW, height: tvH)
        } else {
            let tvH = max(scrollH, contentTextHeight)
            tv.frame = NSRect(x: 0, y: 0, width: width, height: tvH)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        codeScrollView.scrollWheel(with: event)
    }

    @objc private func handleCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawCode, forType: .string)
        if let checkImg = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied") {
            copyBtn.image = checkImg
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.copyBtn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
            }
        }
    }
}

public final class AgentUserQuoteBlockView: AgentFlippedView {
    public let bar = NSView()
    public let tv = AgentSelectableTextView()

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
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        addSubview(bar)

        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        addSubview(tv)
    }

    public func configure(
        attributedText: NSAttributedString,
        theme: Theme,
        accentColor: Color,
        messageId: UUID,
        index: Int,
        parentCell: AgentMessageCell
    ) {
        tv.parentCell = parentCell
        tv.cellId = messageId
        tv.tvKey = "user_quote_\(index)"
        tv.textStorage?.setAttributedString(attributedText)

        let bg = (NSColor(cgColor: theme.background.cgColor) ?? .black).withAlphaComponent(0.28)
        layer?.backgroundColor = bg.cgColor
        let border = (NSColor(cgColor: theme.excerptHeaderBorder.cgColor) ?? .white).withAlphaComponent(0.18)
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1

        let barColor = (NSColor(cgColor: theme.foreground.cgColor) ?? .white).withAlphaComponent(0.60)
        bar.layer?.backgroundColor = barColor.cgColor
    }

    public func height(for width: CGFloat) -> CGFloat {
        let textWidth = max(20, width - 22)
        guard let attr = tv.textStorage, attr.length > 0 else { return 32 }
        return measureAttributedTextHeight(attr, maxWidth: textWidth) + 14
    }

    public func applyLayout(width: CGFloat) {
        let totalH = height(for: width)
        let textWidth = max(20, width - 22)
        let textHeight = max(16, totalH - 14)

        bar.frame = NSRect(x: 5, y: 6, width: 3, height: max(14, totalH - 12))
        tv.frame = NSRect(x: 14, y: 7, width: textWidth, height: textHeight)
        tv.textContainer?.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
    }
}

public final class AgentThoughtBlockView: AgentFlippedView {
    public let headerButton = AgentHoverButton()
    public let textView = AgentSelectableTextView()
    public private(set) var isExpanded = false
    public private(set) var isExpandable: Bool
    public var onToggle: (() -> Void)?

    public init(title: String, attributedText: NSAttributedString, isExpandable: Bool = true) {
        self.isExpandable = isExpandable
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true

        headerButton.wantsLayer = true
        headerButton.layerContentsRedrawPolicy = .onSetNeedsDisplay
        headerButton.isBordered = false
        headerButton.setButtonType(.momentaryPushIn)
        headerButton.alignment = .left
        headerButton.imagePosition = .imageRight
        headerButton.imageHugsTitle = true
        headerButton.imageScaling = .scaleProportionallyDown
        headerButton.defaultBackgroundColor = .clear
        headerButton.hoverBackgroundColor = .clear
        headerButton.target = self
        headerButton.action = #selector(toggle)
        headerButton.isEnabled = isExpandable
        addSubview(headerButton)

        textView.isHidden = true
        textView.alphaValue = 0

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
            textView.removeFromSuperview()
            return
        }
        isExpanded = expanded
        updateHeaderAppearance()

        if expanded {
            if textView.superview == nil {
                addSubview(textView)
            }
            textView.isHidden = false
            textView.alphaValue = 1
        } else {
            if animated {
                textView.alphaValue = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, !self.isExpanded else { return }
                    self.textView.isHidden = true
                    self.textView.removeFromSuperview()
                }
            } else {
                textView.alphaValue = 0
                textView.isHidden = true
                textView.removeFromSuperview()
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
        headerButton.image = agentFixedWidthChevron(
            expanded: isExpanded,
            pointSize: 9,
            description: isExpanded ? "Collapse thought" : "Expand thought"
        )
    }

    private func measuredTextHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 18 }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(18, ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2))
    }
}

public final class AgentToolGroupView: AgentFlippedView {
    public let headerButton = AgentHoverButton()
    public private(set) var toolViews: [NSView] = []
    public private(set) var isExpanded = false
    public var groupKey: String
    public var onToggle: (() -> Void)?
    private var currentTheme: Theme

    private static let headerHeight: CGFloat = 22
    private static let headerSpacing: CGFloat = 6
    private static let itemSpacing: CGFloat = 6

    public init(groupKey: String, toolViews: [NSView], theme: Theme, isExpanded: Bool = false) {
        self.groupKey = groupKey
        self.isExpanded = isExpanded
        self.currentTheme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false

        headerButton.wantsLayer = true
        headerButton.layerContentsRedrawPolicy = .onSetNeedsDisplay
        headerButton.isBordered = false
        headerButton.setButtonType(.momentaryPushIn)
        headerButton.alignment = .left
        headerButton.imagePosition = .imageLeading
        headerButton.imageHugsTitle = true
        headerButton.imageScaling = .scaleProportionallyDown
        headerButton.defaultBackgroundColor = .clear
        headerButton.hoverBackgroundColor = .clear
        headerButton.target = self
        headerButton.action = #selector(toggle)
        addSubview(headerButton)

        update(toolViews: toolViews, theme: theme, isExpanded: isExpanded)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(toolViews newViews: [NSView], theme: Theme, isExpanded: Bool) {
        let newSet = Set(newViews.map(ObjectIdentifier.init))

        for oldView in toolViews where !newSet.contains(ObjectIdentifier(oldView)) {
            if oldView.superview === self {
                oldView.removeFromSuperview()
            }
        }

        self.toolViews = newViews
        self.isExpanded = isExpanded
        self.currentTheme = theme

        if isExpanded {
            for view in newViews {
                if view.superview !== self {
                    view.removeFromSuperview()
                    addSubview(view)
                }
                view.isHidden = false
                view.alphaValue = 1
            }
        } else {
            for view in newViews {
                if view.superview != nil {
                    view.removeFromSuperview()
                }
            }
        }

        updateHeaderAppearance(theme: theme)
    }

    @objc public func toggle() {
        isExpanded.toggle()
        if isExpanded {
            for view in toolViews {
                if view.superview !== self {
                    view.removeFromSuperview()
                    addSubview(view)
                }
                view.isHidden = false
                view.alphaValue = 1
            }
        } else {
            for view in toolViews where view.superview === self {
                view.removeFromSuperview()
            }
        }
        updateHeaderAppearance(theme: currentTheme)
        onToggle?()
    }

    public func updateHeaderAppearance(theme: Theme) {
        var thoughtCount = 0
        var readCount = 0
        var searchCount = 0
        var editCount = 0
        var shellCount = 0
        var otherCount = 0

        for view in toolViews {
            if view is AgentThoughtBlockView {
                thoughtCount += 1
            } else if let card = view as? AgentToolCardView {
                switch card.item.shortToolName {
                case "Edit", "Create", "Write":
                    editCount += 1
                case "Run":
                    shellCount += 1
                case "Read":
                    readCount += 1
                case "Search":
                    searchCount += 1
                default:
                    otherCount += 1
                }
            } else if let simple = view as? AgentSimpleToolCallView {
                otherCount += 1
                _ = simple
            } else {
                otherCount += 1
            }
        }

        var parts: [String] = []
        if thoughtCount > 0 {
            parts.append("\(thoughtCount) \(thoughtCount == 1 ? "thought" : "thoughts")")
        }
        if readCount > 0 {
            parts.append("\(readCount) \(readCount == 1 ? "read" : "reads")")
        }
        if searchCount > 0 {
            parts.append("\(searchCount) \(searchCount == 1 ? "search" : "searches")")
        }
        if editCount > 0 {
            parts.append("\(editCount) \(editCount == 1 ? "edit" : "edits")")
        }
        if shellCount > 0 {
            parts.append("\(shellCount) shell")
        }
        if otherCount > 0 {
            parts.append("\(otherCount) \(otherCount == 1 ? "tool" : "tools")")
        }

        let summary: String
        if parts.isEmpty {
            let count = toolViews.count
            summary = "\(count) \(count == 1 ? "step" : "steps")"
        } else {
            summary = parts.joined(separator: ", ")
        }

        let title = " worked (\(summary))"
        let textColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor).withAlphaComponent(0.85)

        headerButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: textColor
        ])
        headerButton.contentTintColor = textColor

        headerButton.image = agentFixedWidthChevron(
            expanded: isExpanded,
            pointSize: 9.5,
            description: isExpanded ? "Collapse steps" : "Expand steps"
        )
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        guard isExpanded, !toolViews.isEmpty else {
            return Self.headerHeight
        }
        var total = Self.headerHeight + Self.headerSpacing
        for (idx, view) in toolViews.enumerated() {
            if let thought = view as? AgentThoughtBlockView {
                total += thought.measureHeight(width: width)
            } else if let card = view as? AgentToolCardView {
                total += card.measureHeight(width: width)
            } else if let simple = view as? AgentSimpleToolCallView {
                total += simple.measureHeight(width: width)
            }
            if idx < toolViews.count - 1 {
                total += Self.itemSpacing
            }
        }
        return total
    }

    public func applyLayout(width: CGFloat, animated: Bool) {
        let headerFrame = NSRect(x: 0, y: 0, width: max(1, width), height: Self.headerHeight)
        if animated {
            headerButton.animator().frame = headerFrame
        } else {
            headerButton.frame = headerFrame
        }

        guard isExpanded else { return }

        var y = Self.headerHeight + Self.headerSpacing
        for view in toolViews {
            let h: CGFloat
            if let thought = view as? AgentThoughtBlockView {
                h = thought.measureHeight(width: width)
                let f = NSRect(x: 0, y: y, width: width, height: h)
                if animated { thought.animator().frame = f } else { thought.frame = f }
                thought.applyLayout(width: width, animated: animated)
            } else if let card = view as? AgentToolCardView {
                h = card.measureHeight(width: width)
                let f = NSRect(x: 0, y: y, width: width, height: h)
                if animated { card.animator().frame = f } else { card.frame = f }
                card.applyLayout(width: width, animated: animated)
            } else if let simple = view as? AgentSimpleToolCallView {
                h = simple.measureHeight(width: width)
                let f = NSRect(x: 0, y: y, width: width, height: h)
                if animated { simple.animator().frame = f } else { simple.frame = f }
                simple.applyLayout(width: width)
            } else {
                h = 28
            }
            y += h + Self.itemSpacing
        }
    }
}
