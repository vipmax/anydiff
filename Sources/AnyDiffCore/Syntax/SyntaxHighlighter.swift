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

            // Line Comments (//, #, or --)
            let nextIndex = line.index(after: i)
            if (ch == "/" && nextIndex < line.endIndex && line[nextIndex] == "/") ||
               (ch == "#" && Self.usesHashComment(language)) ||
               (ch == "-" && nextIndex < line.endIndex && line[nextIndex] == "-" && (language == "sql" || language == "lua")) {
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

            // Strings ("..." or '...' or `...` or $"..." or @"...")
            if ch == "\"" || ch == "'" || ch == "`" ||
               ((ch == "$" || ch == "@") && nextIndex < line.endIndex && (line[nextIndex] == "\"" || line[nextIndex] == "$" || line[nextIndex] == "@")) {
                let startOffset = currentUtf16Offset
                var quoteChar: Character? = nil

                if ch == "\"" || ch == "'" || ch == "`" {
                    quoteChar = ch
                    currentUtf16Offset += ch.utf16.count
                    i = line.index(after: i)
                } else {
                    // Consume prefix characters '$', '@'
                    while i < line.endIndex && (line[i] == "$" || line[i] == "@") {
                        currentUtf16Offset += line[i].utf16.count
                        i = line.index(after: i)
                    }
                    if i < line.endIndex && (line[i] == "\"" || line[i] == "'") {
                        quoteChar = line[i]
                        currentUtf16Offset += line[i].utf16.count
                        i = line.index(after: i)
                    }
                }

                if let quote = quoteChar {
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
    private static func usesHashComment(_ language: String) -> Bool {
        switch language {
        case "python", "py", "shell", "bash", "zsh", "sh", "yaml", "yml", "toml",
             "ruby", "rb", "elixir", "ex", "dockerfile", "graphql", "terraform", "tf", "php":
            return true
        default:
            return false
        }
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
        case "typescript", "javascript", "ts", "js", "vue", "svelte", "astro":
            switch word {
            case "function", "class", "interface", "type", "const", "let", "var", "import", "export",
                 "from", "default", "return", "if", "else", "switch", "case", "for", "while", "do",
                 "break", "continue", "try", "catch", "finally", "throw", "async", "await", "new",
                 "this", "null", "undefined", "true", "false", "typeof", "instanceof", "as", "is":
                return true
            default:
                return false
            }
        case "csharp", "cs":
            switch word {
            case "abstract", "add", "alias", "as", "async", "await", "base", "bool", "break",
                 "byte", "case", "catch", "char", "checked", "class", "const", "continue",
                 "decimal", "default", "delegate", "do", "double", "else", "enum", "event",
                 "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach",
                 "from", "get", "global", "goto", "group", "if", "implicit", "in", "init",
                 "int", "interface", "internal", "into", "is", "join", "let", "lock", "long",
                 "namespace", "new", "notnull", "null", "object", "operator", "orderby", "out",
                 "override", "params", "partial", "private", "protected", "public", "readonly",
                 "record", "ref", "remove", "return", "sbyte", "sealed", "select", "set",
                 "short", "sizeof", "stackalloc", "static", "string", "struct", "switch", "this",
                 "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unmanaged",
                 "unsafe", "ushort", "using", "value", "var", "virtual", "void", "volatile",
                 "when", "where", "while", "with", "yield":
                return true
            default:
                return false
            }
        case "java":
            switch word {
            case "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
                 "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
                 "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
                 "interface", "long", "native", "new", "null", "package", "private", "protected",
                 "public", "record", "return", "sealed", "short", "static", "strictfp", "super",
                 "switch", "synchronized", "this", "throw", "throws", "transient", "true", "false",
                 "try", "var", "void", "volatile", "while", "yield":
                return true
            default:
                return false
            }
        case "kotlin", "kt":
            switch word {
            case "abstract", "actual", "annotation", "as", "break", "by", "catch", "class", "companion",
                 "const", "constructor", "continue", "crossinline", "data", "do", "else", "enum",
                 "expect", "external", "false", "final", "finally", "for", "fun", "get", "if", "import",
                 "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit",
                 "noinline", "null", "object", "open", "operator", "out", "override", "package",
                 "private", "protected", "public", "reified", "return", "sealed", "set", "super",
                 "suspend", "tailrec", "this", "throw", "true", "try", "typealias", "val", "var",
                 "vararg", "when", "where", "while":
                return true
            default:
                return false
            }
        case "php":
            switch word {
            case "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
                 "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
                 "empty", "enum", "extends", "false", "final", "finally", "fn", "for", "foreach",
                 "function", "global", "goto", "if", "implements", "include", "instanceof", "interface",
                 "isset", "list", "match", "namespace", "new", "null", "or", "private", "protected",
                 "public", "readonly", "require", "return", "self", "static", "switch", "throw",
                 "trait", "true", "try", "unset", "use", "var", "while", "yield":
                return true
            default:
                return false
            }
        case "ruby", "rb":
            switch word {
            case "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else",
                 "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                 "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                 "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader":
                return true
            default:
                return false
            }
        case "dart":
            switch word {
            case "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch",
                 "class", "const", "continue", "covariant", "default", "deferred", "do", "dynamic",
                 "else", "enum", "export", "extends", "extension", "external", "factory", "false",
                 "final", "finally", "for", "Function", "get", "hide", "if", "implements", "import",
                 "in", "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator",
                 "part", "required", "rethrow", "return", "sealed", "set", "show", "static", "super",
                 "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "when",
                 "while", "with", "yield":
                return true
            default:
                return false
            }
        case "elixir", "ex":
            switch word {
            case "def", "defp", "defmodule", "defprotocol", "defimpl", "defmacro", "defstruct",
                 "do", "end", "fn", "if", "else", "unless", "cond", "case", "with", "for", "receive",
                 "after", "try", "catch", "rescue", "raise", "import", "alias", "require", "use",
                 "true", "false", "nil", "when", "in", "and", "or", "not":
                return true
            default:
                return false
            }
        case "scala":
            switch word {
            case "abstract", "case", "catch", "class", "def", "do", "else", "enum", "export",
                 "extends", "false", "final", "finally", "for", "given", "if", "implicit", "import",
                 "lazy", "match", "new", "null", "object", "override", "package", "private",
                 "protected", "return", "sealed", "super", "then", "this", "throw", "trait", "true",
                 "try", "type", "using", "val", "var", "while", "with", "yield":
                return true
            default:
                return false
            }
        case "lua":
            switch word {
            case "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
                 "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while":
                return true
            default:
                return false
            }
        case "zig":
            switch word {
            case "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async",
                 "await", "break", "callconv", "catch", "comptime", "const", "continue", "defer",
                 "else", "enum", "errdefer", "error", "export", "extern", "false", "fn", "for", "if",
                 "inline", "noalias", "nosuspend", "null", "opaque", "or", "orelse", "packed", "pub",
                 "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "true",
                 "try", "undefined", "union", "unreachable", "var", "volatile", "while":
                return true
            default:
                return false
            }
        case "sql":
            switch word.lowercased() {
            case "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                 "create", "table", "drop", "alter", "index", "view", "join", "inner", "left", "right",
                 "full", "on", "as", "and", "or", "not", "null", "is", "in", "exists", "between",
                 "like", "order", "by", "group", "having", "limit", "offset", "union", "all",
                 "distinct", "primary", "key", "foreign", "references", "default", "constraint",
                 "begin", "commit", "rollback", "transaction", "true", "false", "case", "when", "then", "else", "end":
                return true
            default:
                return false
            }
        case "terraform", "tf", "hcl":
            switch word {
            case "resource", "data", "variable", "output", "locals", "module", "provider", "terraform",
                 "for_each", "count", "depends_on", "lifecycle", "provisioner", "dynamic", "for", "in",
                 "if", "true", "false", "null", "string", "number", "bool", "list", "map", "object", "set", "any":
                return true
            default:
                return false
            }
        case "dockerfile":
            switch word.uppercased() {
            case "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
                 "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
                 "HEALTHCHECK", "SHELL", "AS":
                return true
            default:
                return false
            }
        case "graphql", "gql":
            switch word {
            case "query", "mutation", "subscription", "fragment", "on", "type", "interface", "union",
                 "enum", "input", "extend", "scalar", "directive", "schema", "implements", "true", "false", "null":
                return true
            default:
                return false
            }
        case "prisma":
            switch word {
            case "datasource", "generator", "model", "enum", "type", "view", "true", "false":
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
