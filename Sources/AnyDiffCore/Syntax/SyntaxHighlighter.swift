import Foundation
import AppKit

public enum TokenType: Sendable {
    case plain
    case keyword
    case type
    case function
    case string
    case number
    case comment
    case property
    case `operator`
    case punctuation
}

public struct HighlightSpan: Sendable {
    public let range: Range<Int>
    public let tokenType: TokenType
}

/// Ultra-fast regex & keyword syntax highlighter with caching
public final class SyntaxHighlighter: @unchecked Sendable {
    public static let shared = SyntaxHighlighter()

    private let swiftKeywords: Set<String> = [
        "func", "class", "struct", "enum", "protocol", "extension", "let", "var", "import",
        "public", "private", "fileprivate", "internal", "open", "static", "final", "mutating",
        "return", "if", "else", "guard", "switch", "case", "default", "for", "in", "while",
        "repeat", "break", "continue", "fallthrough", "try", "catch", "throw", "throws",
        "rethrows", "async", "await", "actor", "some", "any", "self", "Self", "nil", "true", "false",
        "where", "init", "deinit", "subscript", "typealias", "associatedtype", "defer", "as", "is"
    ]

    private let rustKeywords: Set<String> = [
        "fn", "struct", "enum", "trait", "impl", "let", "mut", "pub", "use", "mod", "crate",
        "self", "Self", "return", "if", "else", "match", "for", "in", "while", "loop",
        "break", "continue", "async", "await", "move", "ref", "type", "where", "unsafe",
        "const", "static", "true", "false", "None", "Some", "Ok", "Err"
    ]

    private let tsKeywords: Set<String> = [
        "function", "class", "interface", "type", "const", "let", "var", "import", "export",
        "from", "default", "return", "if", "else", "switch", "case", "for", "while", "do",
        "break", "continue", "try", "catch", "finally", "throw", "async", "await", "new",
        "this", "null", "undefined", "true", "false", "typeof", "instanceof", "as", "is"
    ]

    public init() {}

    /// Produces an NSAttributedString for a line of code with syntax highlighting
    public func highlight(
        line: String,
        language: String,
        font: NSFont,
        theme: Theme
    ) -> NSAttributedString {
        guard !line.isEmpty else {
            return NSAttributedString(string: "", attributes: [
                .font: font,
                .foregroundColor: theme.foreground
            ])
        }

        let attr = NSMutableAttributedString(
            string: line,
            attributes: [
                .font: font,
                .foregroundColor: theme.foreground
            ]
        )

        let spans = tokenize(line: line, language: language)
        for span in spans {
            guard span.range.lowerBound < line.count && span.range.upperBound <= line.count else { continue }
            let nsRange = NSRange(location: span.range.lowerBound, length: span.range.count)
            let color = colorForToken(span.tokenType, theme: theme)
            attr.addAttribute(.foregroundColor, value: color, range: nsRange)
        }

        return attr
    }

    private func colorForToken(_ token: TokenType, theme: Theme) -> NSColor {
        switch token {
        case .plain: return theme.foreground
        case .keyword: return theme.keyword
        case .type: return theme.type
        case .function: return theme.function
        case .string: return theme.string
        case .number: return theme.number
        case .comment: return theme.comment
        case .property: return theme.property
        case .operator: return theme.operator
        case .punctuation: return theme.punctuation
        }
    }

    public func tokenize(line: String, language: String) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        let chars = Array(line)
        let count = chars.count
        var i = 0

        while i < count {
            let ch = chars[i]

            // Line Comments (// or #)
            if (ch == "/" && i + 1 < count && chars[i + 1] == "/") ||
               ((language == "python" || language == "shell" || language == "yaml") && ch == "#") {
                spans.append(HighlightSpan(range: i..<count, tokenType: .comment))
                break
            }

            // Strings ("..." or '...' or `...`)
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                let start = i
                i += 1
                while i < count {
                    if chars[i] == "\\" && i + 1 < count {
                        i += 2
                        continue
                    }
                    if chars[i] == quote {
                        i += 1
                        break
                    }
                    i += 1
                }
                spans.append(HighlightSpan(range: start..<i, tokenType: .string))
                continue
            }

            // Numbers
            if ch.isNumber || (ch == "." && i + 1 < count && chars[i + 1].isNumber) {
                let start = i
                while i < count && (chars[i].isNumber || chars[i] == "." || chars[i] == "x" || chars[i] == "f" || (chars[i] >= "a" && chars[i] <= "f")) {
                    i += 1
                }
                spans.append(HighlightSpan(range: start..<i, tokenType: .number))
                continue
            }

            // Identifiers / Keywords / Types
            if ch.isLetter || ch == "_" || ch == "$" {
                let start = i
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let word = String(chars[start..<i])
                let tokenType = classifyWord(word, language: language, nextChar: i < count ? chars[i] : nil)
                spans.append(HighlightSpan(range: start..<i, tokenType: tokenType))
                continue
            }

            // Operators & Punctuation
            if "+-*/%=!<>|&^~?".contains(ch) {
                let start = i
                while i < count && "+-*/%=!<>|&^~?".contains(chars[i]) {
                    i += 1
                }
                spans.append(HighlightSpan(range: start..<i, tokenType: .operator))
                continue
            } else if ".,;:(){}[]".contains(ch) {
                spans.append(HighlightSpan(range: i..<(i + 1), tokenType: .punctuation))
                i += 1
                continue
            }

            i += 1
        }

        return spans
    }

    private func classifyWord(_ word: String, language: String, nextChar: Character?) -> TokenType {
        let isKeyword: Bool
        switch language {
        case "rust":
            isKeyword = rustKeywords.contains(word)
        case "typescript", "javascript":
            isKeyword = tsKeywords.contains(word)
        default:
            isKeyword = swiftKeywords.contains(word)
        }

        if isKeyword {
            return .keyword
        }

        if let first = word.first, first.isUppercase {
            return .type
        }

        if nextChar == "(" {
            return .function
        }

        return .plain
    }
}
