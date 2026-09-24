import SwiftUI
import AppKit
import AnyDiffCore

public typealias AgentMarkdownParser = MarkdownParser


public struct AgentMarkdownView: View {
    public let content: String
    public let theme: Theme
    private let blocks: [MarkdownBlock]

    public init(content: String, theme: Theme) {
        self.content = content
        self.theme = theme
        self.blocks = AgentMarkdownParser.parse(content)
    }

    private func headerFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 14
        case 3: return 13.5
        case 4: return 13
        case 5: return 12.5
        default: return 12
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .header(let level, let text):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: headerFontSize(for: level), weight: .bold))
                        .foregroundColor(Color(theme.foreground))
                        .padding(.top, 4)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .bulletItem(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13))
                            .foregroundColor(Color(theme.foreground))
                        Text(LocalizedStringKey(text))
                            .font(.system(size: 13))
                            .foregroundColor(Color(theme.foreground))
                            .lineSpacing(3)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                case .numberedItem(let number, let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(theme.gutterForeground))
                        Text(LocalizedStringKey(text))
                            .font(.system(size: 13))
                            .foregroundColor(Color(theme.foreground))
                            .lineSpacing(3)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows, theme: theme)

                case .divider:
                    Divider()
                        .overlay(Color(theme.excerptHeaderBorder).opacity(0.4))
                        .padding(.vertical, 4)

                case .image(let alt, let path):
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundColor(.accentColor)
                        Text(alt.isEmpty ? path : alt)
                            .font(.system(size: 12))
                            .foregroundColor(Color(theme.foreground))
                    }
                    .padding(.vertical, 2)
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
