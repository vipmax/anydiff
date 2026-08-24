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

    public init(range: Range<Int>, tokenType: TokenType) {
        self.range = range
        self.tokenType = tokenType
    }
}

/// Ultra-fast memoized syntax highlighter for 120 FPS editor scrolling
public final class SyntaxHighlighter: @unchecked Sendable {
    public static let shared = SyntaxHighlighter()

    private struct CacheKey: Hashable {
        let themeId: String
        let language: String
        let fontSize: CGFloat
        let line: String
    }

    private var cache: [CacheKey: NSAttributedString] = [:]
    private var cacheKeys: [CacheKey] = []
    private let maxEntries = 1000
    private let cacheLock = NSLock()

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

    private let pythonKeywords: Set<String> = [
        "def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "while",
        "break", "continue", "try", "except", "finally", "raise", "with", "yield", "async", "await",
        "lambda", "pass", "global", "nonlocal", "assert", "del", "in", "is", "not", "and", "or",
        "True", "False", "None", "self"
    ]

    private let goKeywords: Set<String> = [
        "func", "package", "import", "type", "struct", "interface", "var", "const", "return",
        "if", "else", "switch", "case", "default", "for", "range", "break", "continue", "fallthrough",
        "go", "defer", "select", "chan", "map", "nil", "true", "false", "make", "new", "len", "cap", "append"
    ]

    private let cKeywords: Set<String> = [
        "int", "char", "float", "double", "void", "bool", "long", "short", "signed", "unsigned",
        "struct", "union", "enum", "typedef", "sizeof", "static", "const", "extern", "register", "volatile",
        "if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return",
        "goto", "auto", "inline", "restrict", "true", "false", "NULL", "nullptr", "class", "namespace",
        "public", "private", "protected", "template", "typename", "virtual", "override", "final", "new", "delete"
    ]

    private let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done",
        "in", "function", "select", "time", "return", "exit", "export", "local", "readonly", "set",
        "unset", "shift", "source", "alias", "unalias", "cd", "echo", "pwd", "true", "false"
    ]

    public init() {}

    public func clearCache() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: false)
        cacheKeys.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }

    /// Produces an NSAttributedString for a line of code with syntax highlighting (instant memoized lookup)
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

        let key = CacheKey(themeId: theme.id, language: language, fontSize: font.pointSize, line: line)
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

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

        cacheLock.lock()
        if cacheKeys.count >= maxEntries {
            let evicted = cacheKeys.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        cacheKeys.append(key)
        cache[key] = attr
        cacheLock.unlock()

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
                i += 1
                while i < count && (chars[i].isNumber || chars[i] == "." || chars[i] == "x" || chars[i] == "f" || (chars[i] >= "a" && chars[i] <= "f") || (chars[i] >= "A" && chars[i] <= "F")) {
                    i += 1
                }
                spans.append(HighlightSpan(range: start..<i, tokenType: .number))
                continue
            }

            // Identifiers / Keywords / Types (including Swift closure shorthands $0, $1, etc.)
            if ch.isLetter || ch == "_" || ch == "$" {
                let start = i
                i += 1
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$") {
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
                i += 1
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
        case "python":
            isKeyword = pythonKeywords.contains(word)
        case "go":
            isKeyword = goKeywords.contains(word)
        case "c", "cpp":
            isKeyword = cKeywords.contains(word)
        case "shell":
            isKeyword = shellKeywords.contains(word)
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
