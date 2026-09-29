import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public typealias AgentMarkdownParser = MarkdownParser

extension AgentMessageCell {
    enum AssistantContentSection {
        case richText(NSAttributedString)
        case quote(NSAttributedString)
        case codeBlock(language: String?, code: String)
        case divider
    }

    func compileSections(
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
                let fontSize: CGFloat
                switch level {
                case 1: fontSize = 15
                case 2: fontSize = 14
                case 3: fontSize = 13.5
                case 4: fontSize = 13
                case 5: fontSize = 12.5
                default: fontSize = 12
                }
                let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                let color = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 6
                style.paragraphSpacingBefore = currentRichText.length > 0 ? (level <= 2 ? 12 : 8) : 0
                style.alignment = .left
                let headerAttr = formatInlineMarkdownString(
                    text,
                    font: font,
                    color: color,
                    paragraphStyle: style
                )
                let mutable = NSMutableAttributedString(attributedString: headerAttr)
                mutable.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                currentRichText.append(mutable)
                finishRichTextBlock()

            case .bulletItem(let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 4
                style.alignment = .left
                style.firstLineHeadIndent = 0
                style.headIndent = 16
                let bulletAttr = formatInlineMarkdownString(
                    "•  \(text)",
                    font: NSFont.systemFont(ofSize: 13),
                    color: NSColor(cgColor: theme.foreground.cgColor) ?? .textColor,
                    paragraphStyle: style
                )
                let bulletMutable = NSMutableAttributedString(attributedString: bulletAttr)
                currentRichText.append(bulletMutable)
                currentRichText.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
                finishRichTextBlock()

            case .numberedItem(let number, let text):
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.paragraphSpacing = 4
                style.alignment = .left
                style.firstLineHeadIndent = 0
                let indent: CGFloat = number.count > 1 ? 24 : 18
                style.headIndent = indent
                let numAttr = formatInlineMarkdownString(
                    "\(number).  \(text)",
                    font: NSFont.systemFont(ofSize: 13),
                    color: NSColor(cgColor: theme.foreground.cgColor) ?? .textColor,
                    paragraphStyle: style
                )
                let numMutable = NSMutableAttributedString(attributedString: numAttr)
                currentRichText.append(numMutable)
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

            case .table(let headers, let rows):
                flushRichText()
                let headerLine = headers.joined(separator: "  |  ")
                let sepLine = String(repeating: "-", count: max(10, headerLine.count))
                let rowLines = rows.map { $0.joined(separator: "  |  ") }.joined(separator: "\n")
                sections.append(.codeBlock(language: nil, code: "\(headerLine)\n\(sepLine)\n\(rowLines)"))

            case .divider:
                flushRichText()
                sections.append(.divider)

            case .image(let alt, let path):
                let label = alt.isEmpty ? path : alt
                currentRichText.append(NSAttributedString(string: "[\(label)](\(path))\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.controlAccentColor
                ]))
                finishRichTextBlock()
            }
        }

        flushRichText()
        return sections
    }

    func createSectionView(section: AssistantContentSection, index: Int, highlightCode: Bool = true) -> NSView {
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
            let container = AgentFlippedView()
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
            let container = AgentCodeBlockView()
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
            toggleButton.action = #selector(AgentCodeBlockHeaderView.toggleCodeBlock)
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

        case .divider:
            return AgentDividerView(theme: theme)
        }
    }

    @objc func handleImageClick(_ sender: NSButton) {
        onPreviewImages?(message.images, sender.tag)
    }

    @objc func copyCodeSnippet(_ sender: NSButton) {
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

    func formatQuoteAttributedText(_ raw: String, theme: Theme) -> NSAttributedString {
        let qFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let qColor = (NSColor(cgColor: theme.foreground.cgColor) ?? .textColor).withAlphaComponent(0.90)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        style.paragraphSpacing = 2

        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let result = NSMutableAttributedString()

        for (i, line) in lines.enumerated() {
            let lineAttr = formatInlineMarkdownString(line, font: qFont, color: qColor, paragraphStyle: style)
            result.append(lineAttr)
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: qFont,
                    .foregroundColor: qColor,
                    .paragraphStyle: style
                ]))
            }
        }
        return result
    }

    func formatMarkdownString(_ raw: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return formatInlineMarkdownString(
            raw,
            font: NSFont.systemFont(ofSize: 13),
            color: NSColor(cgColor: theme.foreground.cgColor) ?? .textColor,
            paragraphStyle: style
        )
    }

    func formatThoughtMarkdownString(
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

    func formatInlineMarkdownString(
        _ raw: String,
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        if raw.contains("\n") {
            let normalized = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")
            let result = NSMutableAttributedString()
            for (i, line) in lines.enumerated() {
                result.append(formatSingleLineMarkdownString(line, font: font, color: color, paragraphStyle: paragraphStyle))
                if i < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: paragraphStyle
                    ]))
                }
            }
            return result
        }
        return formatSingleLineMarkdownString(raw, font: font, color: color, paragraphStyle: paragraphStyle)
    }

    func formatSingleLineMarkdownString(
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
                    runFont = NSFont.monospacedSystemFont(ofSize: max(11.5, font.pointSize - 0.5), weight: .regular)
                    let codeBg = (NSColor(cgColor: theme.gutterBackground.cgColor) ?? NSColor.windowBackgroundColor).withAlphaComponent(0.65)
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
                let linkColor = NSColor(accentColor)
                result.addAttribute(.link, value: link, range: range)
                result.addAttribute(.foregroundColor, value: linkColor, range: range)
                result.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
                result.addAttribute(.toolTip, value: link.isFileURL ? link.path : link.absoluteString, range: range)
                let linkText = (result.string as NSString).substring(with: range)
                if linkText.contains(":") || linkText.contains(".") || !link.pathExtension.isEmpty {
                    runFont = NSFont.monospacedSystemFont(ofSize: max(11.5, font.pointSize - 0.5), weight: .semibold)
                    result.addAttribute(.backgroundColor, value: linkColor.withAlphaComponent(0.14), range: range)
                } else {
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    result.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: range)
                    if (intent?.rawValue ?? 0) & 4 != 0 {
                        runFont = NSFont.monospacedSystemFont(ofSize: max(11.5, font.pointSize - 0.5), weight: .semibold)
                    }
                }
            }

            result.addAttribute(.font, value: runFont, range: range)
        }

        linkifyRawURLs(in: result)

        return result
    }

    static let rawLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func linkifyRawURLs(in attrString: NSMutableAttributedString) {
        guard let detector = Self.rawLinkDetector else { return }
        let fullLength = (attrString.string as NSString).length
        guard fullLength > 0 else { return }
        let fullRange = NSRange(location: 0, length: fullLength)
        let matches = detector.matches(in: attrString.string, options: [], range: fullRange)
        let linkColor = NSColor(accentColor)

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
                attrString.addAttribute(.link, value: url, range: match.range)
                attrString.addAttribute(.foregroundColor, value: linkColor, range: match.range)
                attrString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
                attrString.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: match.range)
                attrString.addAttribute(.cursor, value: NSCursor.pointingHand, range: match.range)
                attrString.addAttribute(.toolTip, value: url.isFileURL ? url.path : url.absoluteString, range: match.range)
            }
        }
    }
}
