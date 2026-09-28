import Foundation
import Combine

public enum QuoteSource: String, Sendable, Codable, Equatable {
    case editor
    case agent
    case terminal
    case markdown
}

public struct SelectionQuote: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let source: QuoteSource
    public let label: String
    public let filePath: String?
    public let displayPath: String?
    public let lineRange: ClosedRange<Int>?
    public let language: String?

    public init(
        id: String,
        text: String,
        source: QuoteSource,
        label: String,
        filePath: String? = nil,
        displayPath: String? = nil,
        lineRange: ClosedRange<Int>? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.label = label
        self.filePath = filePath
        self.displayPath = displayPath
        self.lineRange = lineRange
        self.language = language
    }
}

public final class SelectionQuoteStore: ObservableObject {
    public static let shared = SelectionQuoteStore()

    @Published public private(set) var currentQuote: SelectionQuote?

    public init() {}

    public func setQuote(_ quote: SelectionQuote) {
        let apply = { [weak self] in
            guard let self = self else { return }
            if let current = self.currentQuote,
               current.id == quote.id,
               current.text == quote.text,
               current.lineRange == quote.lineRange {
                return
            }
            self.currentQuote = quote
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    public func clearQuote(scopedToId: String? = nil) {
        let apply = { [weak self] in
            guard let self = self, let current = self.currentQuote else { return }
            if let scopedToId, current.id != scopedToId {
                return
            }
            self.currentQuote = nil
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

public enum SelectionQuoteFormatter {
    public static func formatSingleQuote(_ quote: SelectionQuote) -> String {
        let normalized = quote.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawText = normalized.hasSuffix("\n") ? String(normalized.dropLast()) : normalized

        if quote.source == .editor || quote.source == .markdown {
            let defaultLang = (quote.source == .markdown) ? "markdown" : ""
            let lang = quote.language ?? (quote.filePath.map { Buffer.detectLanguage(for: $0) } ?? defaultLang)
            let cleanLang = (lang == "plaintext") ? "" : lang
            var header = ""
            if let filePath = quote.filePath {
                let fileName = (filePath as NSString).lastPathComponent
                let targetPath = quote.displayPath ?? filePath
                let lineSuffix: String
                let hashSuffix: String
                if let range = quote.lineRange {
                    if range.lowerBound == range.upperBound {
                        lineSuffix = ":L\(range.lowerBound)"
                        hashSuffix = "#L\(range.lowerBound)"
                    } else {
                        lineSuffix = ":L\(range.lowerBound)-L\(range.upperBound)"
                        hashSuffix = "#L\(range.lowerBound)-L\(range.upperBound)"
                    }
                } else {
                    lineSuffix = ""
                    hashSuffix = ""
                }
                header = "[\(fileName)\(lineSuffix)](\(targetPath)\(hashSuffix))\n"
            } else if !quote.label.isEmpty {
                header = "\(quote.label):\n"
            }
            return "\(header)```\(cleanLang)\n\(rawText)\n```"
        } else if quote.source == .terminal {
            return "Terminal output (\(quote.label)):\n```sh\n\(rawText)\n```"
        } else {
            return rawText
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
        }
    }

    public static func formatPrompt(userText: String, quotes: [SelectionQuote]) -> String {
        let validQuotes = quotes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)

        if validQuotes.isEmpty {
            return trimmedUser
        }

        let quoteBlocks = validQuotes.map { formatSingleQuote($0) }
        var parts: [String] = quoteBlocks
        if !trimmedUser.isEmpty {
            parts.append(trimmedUser)
        }
        return parts.joined(separator: "\n\n")
    }

    public static func formatPromptBlocks(_ blocks: [PromptBlock]) -> String {
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
            case .quote(let quote):
                if !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(formatSingleQuote(quote))
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }
}

public enum PromptBlock: Equatable, Sendable {
    case text(String)
    case quote(SelectionQuote)
}
