import Foundation

// MARK: - LSP Primitive Types

public struct LSPPosition: Codable, Equatable, Sendable {
    public let line: Int // 0-based
    public let character: Int // 0-based

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Equatable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPLocation: Codable, Equatable, Sendable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    /// Resolves file URL string to a clean filesystem path.
    public var targetFilePath: String {
        if uri.hasPrefix("file://") {
            if let url = URL(string: uri) {
                return url.path
            }
            return String(uri.dropFirst(7))
        }
        return uri
    }

    /// 1-based line number for AnyDiff editor navigation.
    public var targetLine: Int {
        range.start.line + 1
    }

    /// 1-based column number for AnyDiff editor navigation.
    public var targetColumn: Int {
        range.start.character + 1
    }
}

public struct LSPLocationLink: Codable, Equatable, Sendable {
    public let targetUri: String
    public let targetRange: LSPRange
    public let targetSelectionRange: LSPRange?

    public init(targetUri: String, targetRange: LSPRange, targetSelectionRange: LSPRange? = nil) {
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }

    public func toLocation() -> LSPLocation {
        LSPLocation(uri: targetUri, range: targetSelectionRange ?? targetRange)
    }
}

// MARK: - Definition Response Parsing (Matching Zed's definition_locations_from_lsp)

public enum LSPDefinitionResponseParser {
    public static func parse(from jsonValue: Any?) -> [LSPLocation] {
        guard let value = jsonValue, !(value is NSNull) else {
            return []
        }

        let decoder = JSONDecoder()

        // 1. Array of Locations or LocationLinks
        if let array = value as? [[String: Any]] {
            guard let data = try? JSONSerialization.data(withJSONObject: array) else { return [] }
            if let locations = try? decoder.decode([LSPLocation].self, from: data) {
                return locations
            }
            if let links = try? decoder.decode([LSPLocationLink].self, from: data) {
                return links.map { $0.toLocation() }
            }
        }

        // 2. Single Scalar Location
        if let dict = value as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return [] }
            if let singleLoc = try? decoder.decode(LSPLocation.self, from: data) {
                return [singleLoc]
            }
            if let singleLink = try? decoder.decode(LSPLocationLink.self, from: data) {
                return [singleLink.toLocation()]
            }
        }

        return []
    }
}

// MARK: - Hover Types (LSP textDocument/hover)

public struct LSPHover: Codable, Equatable, Sendable {
    public let contents: [String]
    public let range: LSPRange?

    public init(contents: [String], range: LSPRange? = nil) {
        self.contents = contents
        self.range = range
    }

    /// Primary combined markdown string for rendering
    public var markdownString: String {
        contents.joined(separator: "\n\n")
    }
}

public enum LSPHoverResponseParser {
    public static func parse(from jsonValue: Any?) -> LSPHover? {
        guard let value = jsonValue, !(value is NSNull) else {
            return nil
        }

        guard let dict = value as? [String: Any] else {
            if let str = value as? String, !str.isEmpty {
                return LSPHover(contents: [str])
            }
            return nil
        }

        var parsedContents: [String] = []

        if let rawContents = dict["contents"] {
            extractStrings(from: rawContents, into: &parsedContents)
        }

        guard !parsedContents.isEmpty else {
            return nil
        }

        var lspRange: LSPRange? = nil
        if let rangeDict = dict["range"] as? [String: Any],
           let startDict = rangeDict["start"] as? [String: Any],
           let startLine = startDict["line"] as? Int,
           let startChar = startDict["character"] as? Int,
           let endDict = rangeDict["end"] as? [String: Any],
           let endLine = endDict["line"] as? Int,
           let endChar = endDict["character"] as? Int {
            lspRange = LSPRange(
                start: LSPPosition(line: startLine, character: startChar),
                end: LSPPosition(line: endLine, character: endChar)
            )
        }

        return LSPHover(contents: parsedContents, range: lspRange)
    }

    private static func extractStrings(from raw: Any, into results: inout [String]) {
        if let str = raw as? String {
            if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(str)
            }
        } else if let dict = raw as? [String: Any] {
            if let language = dict["language"] as? String, let code = dict["value"] as? String {
                results.append("```\(language)\n\(code)\n```")
            } else if let value = dict["value"] as? String {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append(value)
                }
            }
        } else if let array = raw as? [Any] {
            for item in array {
                extractStrings(from: item, into: &results)
            }
        }
    }
}

// MARK: - Completion Types

public enum LSPCompletionItemKind: Int, Codable, Sendable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case `interface` = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25

    public var badge: String {
        switch self {
        case .method, .function: return "f"
        case .variable, .field: return "v"
        case .class, .struct, .interface: return "s"
        case .module: return "m"
        case .property: return "p"
        case .enum, .enumMember: return "e"
        case .keyword: return "k"
        case .snippet: return "sn"
        case .constant: return "c"
        case .constructor: return "init"
        default: return "•"
        }
    }
}

public struct LSPTextEdit: Codable, Equatable, Sendable {
    public let range: LSPRange
    public let newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

public struct LSPCompletionItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let kind: LSPCompletionItemKind?
    public let detail: String?
    public let documentation: String?
    public let insertText: String?
    public let filterText: String?
    public let sortText: String?
    public let textEdit: LSPTextEdit?
    public let insertTextFormat: Int? // 1: PlainText, 2: Snippet

    public init(
        id: String = UUID().uuidString,
        label: String,
        kind: LSPCompletionItemKind? = nil,
        detail: String? = nil,
        documentation: String? = nil,
        insertText: String? = nil,
        filterText: String? = nil,
        sortText: String? = nil,
        textEdit: LSPTextEdit? = nil,
        insertTextFormat: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.filterText = filterText
        self.sortText = sortText
        self.textEdit = textEdit
        self.insertTextFormat = insertTextFormat
    }

    /// The text to insert when completing this item
    public var effectiveInsertText: String {
        if let edit = textEdit {
            return edit.newText
        }
        if let ins = insertText, !ins.isEmpty {
            return ins
        }
        return label
    }

    /// Strips simple snippet placeholders (e.g. `${1:foo}` -> `foo`, `$0` -> ``)
    public var sanitizedInsertText: String {
        var text = effectiveInsertText
        // Replace ${N:placeholder} with placeholder
        if let regex = try? NSRegularExpression(pattern: #"\\$\\{\\d+:([^}]+)\\}"#) {
            let nsStr = text as NSString
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsStr.length), withTemplate: "$1")
        }
        // Replace $0, $1, etc. with empty string
        if let regex = try? NSRegularExpression(pattern: #"\\$\\d+"#) {
            let nsStr = text as NSString
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsStr.length), withTemplate: "")
        }
        return text
    }
}

// MARK: - Completion Response Parser

public enum LSPCompletionResponseParser {
    public static func parse(from jsonValue: Any?) -> [LSPCompletionItem] {
        guard let value = jsonValue, !(value is NSNull) else {
            return []
        }

        var itemsDicts: [[String: Any]] = []

        if let array = value as? [[String: Any]] {
            itemsDicts = array
        } else if let dict = value as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] {
                itemsDicts = items
            }
        }

        var results: [LSPCompletionItem] = []
        results.reserveCapacity(itemsDicts.count)

        for d in itemsDicts {
            guard let label = d["label"] as? String else { continue }
            let kindRaw = d["kind"] as? Int
            let kind = kindRaw.flatMap { LSPCompletionItemKind(rawValue: $0) }
            let detail = d["detail"] as? String
            var documentation: String? = nil
            if let docStr = d["documentation"] as? String {
                documentation = docStr
            } else if let docDict = d["documentation"] as? [String: Any], let val = docDict["value"] as? String {
                documentation = val
            }
            let insertText = d["insertText"] as? String
            let filterText = d["filterText"] as? String
            let sortText = d["sortText"] as? String
            let insertTextFormat = d["insertTextFormat"] as? Int

            var textEdit: LSPTextEdit? = nil
            if let editDict = d["textEdit"] as? [String: Any],
               let newText = editDict["newText"] as? String,
               let rangeDict = editDict["range"] as? [String: Any],
               let startDict = rangeDict["start"] as? [String: Any],
               let startLine = startDict["line"] as? Int,
               let startChar = startDict["character"] as? Int,
               let endDict = rangeDict["end"] as? [String: Any],
               let endLine = endDict["line"] as? Int,
               let endChar = endDict["character"] as? Int {
                textEdit = LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: startLine, character: startChar),
                        end: LSPPosition(line: endLine, character: endChar)
                    ),
                    newText: newText
                )
            }

            results.append(LSPCompletionItem(
                label: label,
                kind: kind,
                detail: detail,
                documentation: documentation,
                insertText: insertText,
                filterText: filterText,
                sortText: sortText,
                textEdit: textEdit,
                insertTextFormat: insertTextFormat
            ))
        }

        return results
    }
}

// MARK: - Text Document Synchronization Types

public struct LSPTextDocumentIdentifier: Codable, Sendable {
    public let uri: String

    public init(uri: String) {
        self.uri = uri
    }
}

public struct LSPVersionedTextDocumentIdentifier: Codable, Sendable {
    public let uri: String
    public let version: Int

    public init(uri: String, version: Int) {
        self.uri = uri
        self.version = version
    }
}

public struct LSPTextDocumentItem: Codable, Sendable {
    public let uri: String
    public let languageId: String
    public let version: Int
    public let text: String

    public init(uri: String, languageId: String, version: Int, text: String) {
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
    }
}

public struct LSPTextDocumentContentChangeEvent: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Framing & JSON-RPC Encoding

public enum LSPFraming {
    private static let headerPrefix = "Content-Length: "
    private static let delimiter = "\r\n\r\n"

    /// Encodes a dictionary into JSON-RPC format with Content-Length header.
    public static func encode(jsonDict: [String: Any]) throws -> Data {
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
        let header = "\(headerPrefix)\(jsonData.count)\(delimiter)"
        var data = Data(header.utf8)
        data.append(jsonData)
        return data
    }

    /// Buffer for decoding incoming chunked streams of LSP frames.
    public final class FrameReader: @unchecked Sendable {
        private var buffer = Data()
        private let lock = NSLock()

        public init() {}

        public func append(data: Data) -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)
            var messages: [[String: Any]] = []

            while true {
                // Find \r\n\r\n delimiter
                guard let delimiterRange = buffer.range(of: Data(delimiter.utf8)) else {
                    break
                }

                let headerData = buffer.subdata(in: 0..<delimiterRange.lowerBound)
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    buffer.removeSubrange(0..<delimiterRange.upperBound)
                    continue
                }

                // Parse Content-Length: <len>
                var contentLength: Int? = nil
                for line in headerString.components(separatedBy: "\r\n") {
                    if line.hasPrefix(headerPrefix) {
                        let lenStr = line.dropFirst(headerPrefix.count).trimmingCharacters(in: .whitespaces)
                        contentLength = Int(lenStr)
                        break
                    }
                }

                guard let length = contentLength else {
                    buffer.removeSubrange(0..<delimiterRange.upperBound)
                    continue
                }

                let bodyStart = delimiterRange.upperBound
                let bodyEnd = bodyStart + length

                guard buffer.count >= bodyEnd else {
                    // Whole body not received yet
                    break
                }

                let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)
                buffer.removeSubrange(0..<bodyEnd)

                if let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                    messages.append(json)
                }
            }

            return messages
        }
    }
}
