import Foundation

/// Unique identifier for a file buffer
public struct BufferId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString.prefix(8).lowercased()
    }
}

/// Zero-based row in an individual file buffer
public typealias BufferRow = Int

/// Zero-based column (character index) in an individual file buffer line
public typealias BufferColumn = Int

/// A 2D point coordinate in a file buffer
public struct BufferPoint: Hashable, Equatable, Comparable, Sendable, CustomStringConvertible {
    public var row: BufferRow
    public var column: BufferColumn

    public init(row: BufferRow, column: BufferColumn) {
        self.row = row
        self.column = column
    }

    public static let zero = BufferPoint(row: 0, column: 0)

    public static func < (lhs: BufferPoint, rhs: BufferPoint) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        return lhs.column < rhs.column
    }

    public var description: String {
        "(\(row):\(column))"
    }
}

/// High-performance text buffer representing an underlying file or snapshot
public final class Buffer: Identifiable, @unchecked Sendable {
    public let id: BufferId
    public var filePath: String
    public var language: String

    /// Cached lines of the buffer
    private var _lines: [String]
    private var _isDirty: Bool = false

    public var isDirty: Bool {
        _isDirty
    }

    public var lineCount: Int {
        _lines.count
    }

    public var lines: [String] {
        _lines
    }

    public init(id: BufferId = BufferId(), filePath: String, text: String, language: String = "") {
        self.id = id
        self.filePath = filePath
        self.language = language.isEmpty ? Buffer.detectLanguage(for: filePath) : language
        
        let split = text.components(separatedBy: "\n")
        self._lines = split.isEmpty ? [""] : split
    }

    public static func detectLanguage(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "rust"
        case "ts", "tsx": return "typescript"
        case "js", "jsx": return "javascript"
        case "py": return "python"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc", "cxx": return "cpp"
        case "go": return "go"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        case "diff", "patch": return "diff"
        case "sh", "zsh", "bash": return "shell"
        default: return "plaintext"
        }
    }

    public func line(at row: BufferRow) -> String? {
        guard row >= 0 && row < _lines.count else { return nil }
        return _lines[row]
    }

    public func text() -> String {
        _lines.joined(separator: "\n")
    }

    public func lineLength(at row: BufferRow) -> Int {
        guard row >= 0 && row < _lines.count else { return 0 }
        return _lines[row].count
    }

    public func text(in range: Range<BufferPoint>) -> String {
        let start = clamp(point: range.lowerBound)
        let end = clamp(point: range.upperBound)
        guard start <= end else { return "" }

        if start.row == end.row {
            let line = _lines[start.row]
            let startIdx = line.index(line.startIndex, offsetBy: min(line.count, start.column))
            let endIdx = line.index(line.startIndex, offsetBy: min(line.count, end.column))
            return String(line[startIdx..<endIdx])
        }

        var result: [String] = []
        let firstLine = _lines[start.row]
        let firstIdx = firstLine.index(firstLine.startIndex, offsetBy: min(firstLine.count, start.column))
        result.append(String(firstLine[firstIdx...]))

        for r in (start.row + 1)..<end.row {
            result.append(_lines[r])
        }

        let lastLine = _lines[end.row]
        let lastIdx = lastLine.index(lastLine.startIndex, offsetBy: min(lastLine.count, end.column))
        result.append(String(lastLine[..<lastIdx]))

        return result.joined(separator: "\n")
    }

    /// Mutates the buffer by replacing a range of text
    @discardableResult
    public func replace(start: BufferPoint, end: BufferPoint, with newText: String) -> Range<BufferPoint> {
        let clampedStart = clamp(point: start)
        let clampedEnd = clamp(point: end)

        guard clampedStart <= clampedEnd else {
            return clampedStart..<clampedStart
        }

        let replacementLines = newText.components(separatedBy: "\n")

        let startLine = _lines[clampedStart.row]
        let endLine = _lines[clampedEnd.row]

        let prefix = String(startLine.prefix(clampedStart.column))
        let suffix = String(endLine.suffix(max(0, endLine.count - clampedEnd.column)))

        var newContentLines: [String] = []

        if replacementLines.count == 1 {
            let combined = prefix + replacementLines[0] + suffix
            newContentLines.append(combined)
        } else {
            let first = prefix + replacementLines[0]
            newContentLines.append(first)
            for i in 1..<(replacementLines.count - 1) {
                newContentLines.append(replacementLines[i])
            }
            let last = replacementLines.last! + suffix
            newContentLines.append(last)
        }

        _lines.replaceSubrange(clampedStart.row...clampedEnd.row, with: newContentLines)
        _isDirty = true

        let endRow = clampedStart.row + newContentLines.count - 1
        let endCol: Int
        if replacementLines.count == 1 {
            endCol = clampedStart.column + replacementLines[0].count
        } else {
            endCol = replacementLines.last!.count
        }

        return clampedStart..<BufferPoint(row: endRow, column: endCol)
    }

    /// Inserts text at a specific point
    @discardableResult
    public func insert(text: String, at point: BufferPoint) -> Range<BufferPoint> {
        replace(start: point, end: point, with: text)
    }

    /// Deletes text between start and end point
    @discardableResult
    public func delete(from start: BufferPoint, to end: BufferPoint) -> BufferPoint {
        let _ = replace(start: start, end: end, with: "")
        return clamp(point: start)
    }

    public var isFullFile: Bool = true
    public var absolutePath: String?

    public func saveToFile(baseDirectory: String? = nil) throws {
        let resolvedPath: String
        if let abs = absolutePath {
            resolvedPath = abs
        } else if let base = baseDirectory {
            resolvedPath = URL(fileURLWithPath: base).appendingPathComponent(filePath).path
        } else {
            resolvedPath = filePath
        }

        let fullText = text()
        try fullText.write(to: URL(fileURLWithPath: resolvedPath), atomically: true, encoding: .utf8)
        _isDirty = false
    }

    public func markClean() {
        _isDirty = false
    }

    public func clamp(point: BufferPoint) -> BufferPoint {
        let maxRow = max(0, _lines.count - 1)
        let row = min(max(0, point.row), maxRow)
        let lineLen = lineLength(at: row)
        let col = min(max(0, point.column), lineLen)
        return BufferPoint(row: row, column: col)
    }
}
