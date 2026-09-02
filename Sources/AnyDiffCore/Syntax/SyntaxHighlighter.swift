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
        let language: String
        let line: String
    }

    private var cache: [CacheKey: NSAttributedString] = [:]
    private var cacheKeys: [CacheKey] = []
    private let maxEntries = 2000
    private let cacheLock = NSLock()

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

        let key = CacheKey(language: language, line: line)
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
        let utf16Length = (line as NSString).length
        for span in spans {
            guard span.range.lowerBound >= 0 && span.range.upperBound <= utf16Length && span.range.lowerBound < span.range.upperBound else { continue }
            let nsRange = NSRange(location: span.range.lowerBound, length: span.range.count)
            let color = colorForToken(span.tokenType, theme: theme)
            attr.addAttribute(.foregroundColor, value: color, range: nsRange)
        }

        cacheLock.lock()
        if cacheKeys.count >= maxEntries {
            let toRemove = maxEntries / 4 // Batch purge oldest 25% to avoid O(N) array shifts on every line
            for k in cacheKeys.prefix(toRemove) {
                cache.removeValue(forKey: k)
            }
            cacheKeys.removeFirst(toRemove)
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
        let nsLine = line as NSString
        let utf16Length = nsLine.length
        guard utf16Length > 0 else { return [] }

        var i = line.startIndex
        var currentUtf16Offset = 0

        // 1. Fast-skip leading whitespace (0 heap allocations)
        while i < line.endIndex && (line[i] == " " || line[i] == "\t") {
            currentUtf16Offset += 1
            i = line.index(after: i)
        }

        guard i < line.endIndex else { return [] }

        // 2. Multi-line comment continuation lines (e.g. " * doc text" or " */")
        if language != "python" && language != "shell" && language != "yaml" && line[i] == "*" {
            let next = line.index(after: i)
            if next == line.endIndex || line[next] == " " || line[next] == "\t" || line[next] == "*" {
                return [HighlightSpan(range: currentUtf16Offset..<utf16Length, tokenType: .comment)]
            } else if line[next] == "/" {
                let closeEndOffset = currentUtf16Offset + 2
                spans.append(HighlightSpan(range: currentUtf16Offset..<closeEndOffset, tokenType: .comment))
                i = line.index(after: next)
                currentUtf16Offset = closeEndOffset
                while i < line.endIndex && (line[i] == " " || line[i] == "\t") {
                    currentUtf16Offset += 1
                    i = line.index(after: i)
                }
                if i == line.endIndex {
                    return spans
                }
            }
        }

        while i < line.endIndex {
            let ch = line[i]

            // Line Comments (// or #)
            let nextIndex = line.index(after: i)
            if (ch == "/" && nextIndex < line.endIndex && line[nextIndex] == "/") ||
               ((language == "python" || language == "shell" || language == "yaml") && ch == "#") {
                spans.append(HighlightSpan(range: currentUtf16Offset..<utf16Length, tokenType: .comment))
                break
            }

            // Block Comments (/* ... */)
            if ch == "/" && nextIndex < line.endIndex && line[nextIndex] == "*" {
                let startOffset = currentUtf16Offset
                currentUtf16Offset += 2 // "/" and "*"
                i = line.index(after: nextIndex)

                while i < line.endIndex {
                    let sc = line[i]
                    let sn = line.index(after: i)
                    if sc == "*" && sn < line.endIndex && line[sn] == "/" {
                        currentUtf16Offset += 2 // "*" and "/"
                        i = line.index(after: sn)
                        break
                    }
                    currentUtf16Offset += sc.utf16.count
                    i = line.index(after: i)
                }
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: .comment))
                continue
            }

            // Strings ("..." or '...' or `...`)
            if ch == "\"" || ch == "'" || ch == "`" {
                let quote = ch
                let startOffset = currentUtf16Offset
                currentUtf16Offset += ch.utf16.count
                i = line.index(after: i)

                while i < line.endIndex {
                    let sc = line[i]
                    if sc == "\\" {
                        currentUtf16Offset += sc.utf16.count
                        let next = line.index(after: i)
                        if next < line.endIndex {
                            currentUtf16Offset += line[next].utf16.count
                            i = line.index(after: next)
                            continue
                        } else {
                            i = next
                            break
                        }
                    }
                    currentUtf16Offset += sc.utf16.count
                    i = line.index(after: i)
                    if sc == quote {
                        break
                    }
                }
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: .string))
                continue
            }

            // Numbers
            if ch.isNumber || (ch == "." && nextIndex < line.endIndex && line[nextIndex].isNumber) {
                let startOffset = currentUtf16Offset
                currentUtf16Offset += ch.utf16.count
                i = nextIndex

                while i < line.endIndex {
                    let c = line[i]
                    if c.isNumber || c == "." || c == "x" || c == "X" || c == "f" || c == "F" || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") {
                        currentUtf16Offset += c.utf16.count
                        i = line.index(after: i)
                    } else {
                        break
                    }
                }
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: .number))
                continue
            }

            // Identifiers / Keywords / Types (including Swift closure shorthands $0, $1, etc.)
            if ch.isLetter || ch == "_" || ch == "$" {
                let start = i
                let startOffset = currentUtf16Offset
                currentUtf16Offset += ch.utf16.count
                i = line.index(after: i)

                while i < line.endIndex {
                    let c = line[i]
                    if c.isLetter || c.isNumber || c == "_" || c == "$" {
                        currentUtf16Offset += c.utf16.count
                        i = line.index(after: i)
                    } else {
                        break
                    }
                }
                let word = line[start..<i]
                let nextChar = i < line.endIndex ? line[i] : nil
                let tokenType = classifyWord(word, language: language, nextChar: nextChar)
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: tokenType))
                continue
            }

            // Operators & Punctuation
            if Self.isOperatorChar(ch) {
                let startOffset = currentUtf16Offset
                currentUtf16Offset += ch.utf16.count
                i = line.index(after: i)

                while i < line.endIndex && Self.isOperatorChar(line[i]) {
                    currentUtf16Offset += line[i].utf16.count
                    i = line.index(after: i)
                }
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: .operator))
                continue
            } else if Self.isPunctuationChar(ch) {
                let startOffset = currentUtf16Offset
                currentUtf16Offset += ch.utf16.count
                i = line.index(after: i)
                spans.append(HighlightSpan(range: startOffset..<currentUtf16Offset, tokenType: .punctuation))
                continue
            }

            currentUtf16Offset += ch.utf16.count
            i = line.index(after: i)
        }

        return spans
    }

    @inline(__always)
    private static func isOperatorChar(_ ch: Character) -> Bool {
        switch ch {
        case "+", "-", "*", "/", "%", "=", "!", "<", ">", "|", "&", "^", "~", "?":
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func isPunctuationChar(_ ch: Character) -> Bool {
        switch ch {
        case ".", ",", ";", ":", "(", ")", "{", "}", "[", "]":
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private func classifyWord(_ word: Substring, language: String, nextChar: Character?) -> TokenType {
        if Self.isKeyword(word, language: language) {
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

    @inline(__always)
    private static func isKeyword(_ word: Substring, language: String) -> Bool {
        switch language {
        case "rust":
            switch word {
            case "fn", "struct", "enum", "trait", "impl", "let", "mut", "pub", "use", "mod", "crate",
                 "self", "Self", "return", "if", "else", "match", "for", "in", "while", "loop",
                 "break", "continue", "async", "await", "move", "ref", "type", "where", "unsafe",
                 "const", "static", "true", "false", "None", "Some", "Ok", "Err":
                return true
            default:
                return false
            }
        case "typescript", "javascript", "ts", "js":
            switch word {
            case "function", "class", "interface", "type", "const", "let", "var", "import", "export",
                 "from", "default", "return", "if", "else", "switch", "case", "for", "while", "do",
                 "break", "continue", "try", "catch", "finally", "throw", "async", "await", "new",
                 "this", "null", "undefined", "true", "false", "typeof", "instanceof", "as", "is":
                return true
            default:
                return false
            }
        case "python", "py":
            switch word {
            case "def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "while",
                 "break", "continue", "try", "except", "finally", "raise", "with", "yield", "async", "await",
                 "lambda", "pass", "global", "nonlocal", "assert", "del", "in", "is", "not", "and", "or",
                 "True", "False", "None", "self":
                return true
            default:
                return false
            }
        case "go":
            switch word {
            case "func", "package", "import", "type", "struct", "interface", "var", "const", "return",
                 "if", "else", "switch", "case", "default", "for", "range", "break", "continue", "fallthrough",
                 "go", "defer", "select", "chan", "map", "nil", "true", "false", "make", "new", "len", "cap", "append":
                return true
            default:
                return false
            }
        case "c", "cpp", "cxx", "h", "hpp":
            switch word {
            case "int", "char", "float", "double", "void", "bool", "long", "short", "signed", "unsigned",
                 "struct", "union", "enum", "typedef", "sizeof", "static", "const", "extern", "register", "volatile",
                 "if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return",
                 "goto", "auto", "inline", "restrict", "true", "false", "NULL", "nullptr", "class", "namespace",
                 "public", "private", "protected", "template", "typename", "virtual", "override", "final", "new", "delete":
                return true
            default:
                return false
            }
        case "shell", "bash", "zsh", "sh":
            switch word {
            case "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done",
                 "in", "function", "select", "time", "return", "exit", "export", "local", "readonly", "set",
                 "unset", "shift", "source", "alias", "unalias", "cd", "echo", "pwd", "true", "false":
                return true
            default:
                return false
            }
        default: // swift
            switch word {
            case "func", "class", "struct", "enum", "protocol", "extension", "let", "var", "import",
                 "public", "private", "fileprivate", "internal", "open", "static", "final", "mutating",
                 "return", "if", "else", "guard", "switch", "case", "default", "for", "in", "while",
                 "repeat", "break", "continue", "fallthrough", "try", "catch", "throw", "throws",
                 "rethrows", "async", "await", "actor", "some", "any", "self", "Self", "nil", "true", "false",
                 "where", "init", "deinit", "subscript", "typealias", "associatedtype", "defer", "as", "is":
                return true
            default:
                return false
            }
        }
    }
}
