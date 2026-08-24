import SwiftUI
import AppKit
import AnyDiffCore

public enum MarkdownBlock: Identifiable {
    public var id: String {
        switch self {
        case .header(let level, let text):
            return "h_\(level)_\(text.hashValue)"
        case .bulletItem(let text):
            return "b_\(text.hashValue)"
        case .paragraph(let text):
            return "p_\(text.hashValue)"
        case .codeBlock(let lang, let code):
            return "c_\(lang ?? "")_\(code.hashValue)"
        case .quote(let text):
            return "q_\(text.hashValue)"
        }
    }

    case header(level: Int, text: String)
    case bulletItem(String)
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case quote(String)
}

public enum AgentMarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var currentLanguage: String? = nil
        var currentCodeLines: [String] = []
        var currentParagraphLines: [String] = []
        var currentQuoteLines: [String] = []

        func flushParagraph() {
            if !currentParagraphLines.isEmpty {
                let text = currentParagraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.paragraph(text))
                }
                currentParagraphLines.removeAll()
            }
        }

        func flushQuote() {
            if !currentQuoteLines.isEmpty {
                let text = currentQuoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.quote(text))
                }
                currentQuoteLines.removeAll()
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Code Block Fence
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    let code = currentCodeLines.joined(separator: "\n")
                    blocks.append(.codeBlock(language: currentLanguage, code: code))
                    currentCodeLines.removeAll()
                    currentLanguage = nil
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    flushQuote()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    currentLanguage = lang.isEmpty ? nil : lang
                    currentCodeLines.removeAll()
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                currentCodeLines.append(line)
                continue
            }

            // 2. Quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                if let gtIdx = line.firstIndex(of: ">") {
                    let afterGt = line[line.index(after: gtIdx)...]
                    currentQuoteLines.append(String(afterGt).trimmingCharacters(in: .whitespaces))
                }
                continue
            } else if !currentQuoteLines.isEmpty {
                flushQuote()
            }

            // 3. Headers
            if trimmed.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.header(level: 3, text: String(trimmed.dropFirst(4))))
                continue
            } else if trimmed.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.header(level: 2, text: String(trimmed.dropFirst(3))))
                continue
            } else if trimmed.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.header(level: 1, text: String(trimmed.dropFirst(2))))
                continue
            }

            // 4. Bullet Items (prevents Apple AttributedString markdown list parsing abort on + / -)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                let itemText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !itemText.isEmpty {
                    blocks.append(.bulletItem(itemText))
                }
                continue
            }

            // 5. Empty lines
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            currentParagraphLines.append(line)
        }

        if inCodeBlock {
            let code = currentCodeLines.joined(separator: "\n")
            blocks.append(.codeBlock(language: currentLanguage, code: code))
        }
        flushParagraph()
        flushQuote()

        return blocks
    }
}

public struct AgentMarkdownView: View {
    public let content: String
    public let theme: Theme
    private let blocks: [MarkdownBlock]

    public init(content: String, theme: Theme) {
        self.content = content
        self.theme = theme
        self.blocks = AgentMarkdownParser.parse(content)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .header(let level, let text):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: level == 1 ? 15 : (level == 2 ? 14 : 13.5), weight: .bold))
                        .foregroundColor(Color(theme.foreground))
                        .padding(.top, 4)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .bulletItem(let text):
                    Text(LocalizedStringKey("• \(text)"))
                        .font(.system(size: 13))
                        .foregroundColor(Color(theme.foreground))
                        .lineSpacing(3)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .paragraph(let text):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: 13))
                        .foregroundColor(Color(theme.foreground))
                        .lineSpacing(3)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .codeBlock(let language, let code):
                    AgentCodeBlockView(language: language, code: code, theme: theme)

                case .quote(let text):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(theme.foreground).opacity(0.9))
                        .lineSpacing(2)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(theme.gutterBackground).opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: 3)
                                .padding(.vertical, 3),
                            alignment: .leading
                        )
                }
            }
        }
    }
}

public struct AgentCodeBlockView: View {
    public let language: String?
    public let code: String
    public let theme: Theme

    @State private var isCopied: Bool = false
    @State private var isHovered: Bool = false

    public init(language: String?, code: String, theme: Theme) {
        self.language = language
        self.code = code
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground))

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isCopied ? .green : Color(theme.gutterForeground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(theme.gutterBackground).opacity(0.40))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isCopied ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.15), value: isCopied)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(theme.gutterBackground).opacity(0.75))
            .onHover { hovering in
                isHovered = hovering
            }

            Divider()
                .background(Color(theme.excerptHeaderBorder).opacity(0.35))

            // Code Content without gesture-stealing nested ScrollView
            Text(highlightedCode)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.gutterBackground).opacity(0.40))
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.35), lineWidth: 1)
        )
    }

    private var highlightedCode: AttributedString {
        let lang = language ?? "plaintext"
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let lines = code.components(separatedBy: "\n")
        let full = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let highlighted = SyntaxHighlighter.shared.highlight(line: line, language: lang, font: font, theme: theme)
            full.append(highlighted)
            if i < lines.count - 1 {
                full.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return AttributedString(full)
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCopied = false
            }
        }
    }
}
