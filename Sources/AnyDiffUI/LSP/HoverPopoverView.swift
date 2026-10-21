import SwiftUI
import AppKit
import AnyDiffCore

public struct HoverPopoverView: View {
    public let hover: LSPHover
    public let theme: Theme
    public var onHoverChanged: ((Bool) -> Void)? = nil

    public init(hover: LSPHover, theme: Theme, onHoverChanged: ((Bool) -> Void)? = nil) {
        self.hover = hover
        self.theme = theme
        self.onHoverChanged = onHoverChanged
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            contentView
        }
        .frame(minWidth: 160, maxWidth: 560)
        .frame(maxHeight: 320)
        .overlay(alignment: .topTrailing) {
            copyButton
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
        .onHover { isHovered in
            onHoverChanged?(isHovered)
        }
    }

    @State private var isCopied = false
    @State private var isButtonHovered = false

    private var copyButton: some View {
        Button(action: copyToClipboard) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(isCopied ? .green : Color(theme.foreground).opacity(isButtonHovered ? 0.9 : 0.55))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isCopied ? Color.green.opacity(0.15) : (isButtonHovered ? Color(theme.foreground).opacity(0.12) : Color(theme.foreground).opacity(0.06)))
                )
        }
        .buttonStyle(.plain)
        .onHover { h in
            isButtonHovered = h
        }
        .help(isCopied ? "Copied" : "Copy")
    }

    public var contentView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                markdownBlockView(block)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 32)
        .padding(.vertical, 8)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hover.markdownString, forType: .string)
        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                isCopied = false
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        let parsed = MarkdownParser.parse(hover.markdownString)
        if !parsed.isEmpty {
            return parsed
        }
        let trimmed = hover.markdownString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return [.paragraph(trimmed)]
        }
        return []
    }

    @ViewBuilder
    public func markdownBlockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .codeBlock(let language, let code):
            codeSection(code: code, language: language)

        case .paragraph(let text):
            inlineMarkdownText(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .header(let level, let text):
            let fontSize: CGFloat = level <= 2 ? 11.5 : 11
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            inlineMarkdownText(text, font: font, color: theme.foreground.withAlphaComponent(0.65))
                .textSelection(.enabled)

        case .bulletItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(theme.accentColor))
                inlineMarkdownText(text)
                    .textSelection(.enabled)
            }
            .padding(.leading, 2)

        case .numberedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.accentColor))
                inlineMarkdownText(text)
                    .textSelection(.enabled)
            }
            .padding(.leading, 2)

        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(theme.accentColor).opacity(0.7))
                    .frame(width: 2.5)
                inlineMarkdownText(
                    text,
                    font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    color: theme.foreground.withAlphaComponent(0.85)
                )
                .textSelection(.enabled)
            }
            .padding(.leading, 2)

        case .divider:
            Divider()
                .overlay(Color(theme.excerptHeaderBorder).opacity(0.45))
                .padding(.vertical, 2)

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows, theme: theme)
                .cornerRadius(4)

        case .image:
            EmptyView()
        }
    }

    private func codeSection(code: String, language: String?) -> some View {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AnyView(EmptyView()) }
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lang = (language?.isEmpty == false) ? language! : "swift"
        let highlighted = highlightedCode(code: trimmed, language: lang, font: codeFont)

        return AnyView(
            Text(highlighted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(3)
                .textSelection(.enabled)
        )
    }

    private func highlightedCode(code: String, language: String, font: NSFont) -> AttributedString {
        let lines = code.components(separatedBy: "\n")
        let attr = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let lineAttr = SyntaxHighlighter.shared.highlight(
                line: line,
                language: language,
                font: font,
                theme: theme
            )
            attr.append(lineAttr)
            if i < lines.count - 1 {
                attr.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return AttributedString(attr)
    }

    private func inlineMarkdownText(_ text: String, font: NSFont? = nil, color: NSColor? = nil) -> Text {
        let defaultFont = font ?? NSFont.systemFont(ofSize: 12, weight: .regular)
        let defaultColor = color ?? theme.foreground.withAlphaComponent(0.92)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        let attr = MarkdownInlineFormatter.format(
            text: text,
            font: defaultFont,
            color: defaultColor,
            paragraphStyle: style,
            theme: theme
        )
        return Text(AttributedString(attr))
    }
}
