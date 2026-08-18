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

    /// Underlying storage (either zero-copy raw flat slices or mutable array of strings)
    public var storage: BufferStorage
    private var _isDirty: Bool = false

    public var isDirty: Bool {
        _isDirty
    }

    public var lineCount: Int {
        storage.count
    }

    public var lines: [String] {
        get { storage.allLines }
        set {
            storage = .mutable(lines: newValue)
            _isDirty = true
            version &+= 1
        }
    }

    /// Incremented on every buffer modification to invalidate memoized diffs
    public private(set) var version: Int = 0
    public var cachedDiffLines: [DiffLine]? = nil
    public var cachedDiffVersion: Int = -1

    /// Original baseline file lines before modifications (e.g. from git HEAD)
    private var _baselineLines: [String]?
    public var baselineLines: [String] {
        get { _baselineLines ?? [] }
        set { _baselineLines = newValue }
    }

    public var baselineText: String {
        get { baselineLines.joined(separator: "\n") }
        set { baselineLines = newValue.components(separatedBy: "\n") }
    }

    /// Number of lines this buffer occupied on disk during last save
    public var lastSavedLineCount: Int

    /// True when this buffer holds a lightweight diff hunk slice loaded lazily without disk I/O
    public var isLazySlice: Bool = false
    public var isFullFile: Bool = false

    public var totalAdditions: Int
    public var totalDeletions: Int
    public var startLineNumber: Int
    public var fullDiskPath: String?
    public var diskFileLineCount: Int?

    public init(
        id: BufferId = BufferId(),
        filePath: String,
        storage: BufferStorage,
        language: String = "",
        baselineLines: [String]? = nil,
        totalAdditions: Int = 0,
        totalDeletions: Int = 0,
        startLineNumber: Int = 1,
        fullDiskPath: String? = nil,
        diskFileLineCount: Int? = nil,
        isLazySlice: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.storage = storage
        self.language = language.isEmpty ? Buffer.detectLanguage(for: filePath) : language
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.startLineNumber = startLineNumber
        self.fullDiskPath = fullDiskPath
        self.diskFileLineCount = diskFileLineCount
        self._baselineLines = baselineLines
        self.lastSavedLineCount = baselineLines?.count ?? storage.count
        self.isLazySlice = isLazySlice
    }

    public init(
        id: BufferId = BufferId(),
        filePath: String,
        lines: [String],
        language: String = "",
        baselineLines: [String]? = nil,
        totalAdditions: Int = 0,
        totalDeletions: Int = 0,
        startLineNumber: Int = 1,
        fullDiskPath: String? = nil,
        diskFileLineCount: Int? = nil,
        isLazySlice: Bool = false
    ) {
        self.id = id
        self.filePath = filePath
        self.storage = .mutable(lines: lines)
        self.language = language.isEmpty ? Buffer.detectLanguage(for: filePath) : language
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.startLineNumber = startLineNumber
        self.fullDiskPath = fullDiskPath
        self.diskFileLineCount = diskFileLineCount
        let bLines = baselineLines ?? lines
        self._baselineLines = bLines
        self.lastSavedLineCount = bLines.count
        self.isLazySlice = isLazySlice
    }

    public init(
        id: BufferId = BufferId(),
        filePath: String,
        text: String,
        language: String = "",
        baselineText: String? = nil,
        totalAdditions: Int = 0,
        totalDeletions: Int = 0,
        startLineNumber: Int = 1,
        fullDiskPath: String? = nil,
        diskFileLineCount: Int? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.language = language.isEmpty ? Buffer.detectLanguage(for: filePath) : language
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.startLineNumber = startLineNumber
        self.fullDiskPath = fullDiskPath
        self.diskFileLineCount = diskFileLineCount

        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        self.storage = .mutable(lines: lines)

        if let bText = baselineText {
            let bLines = bText.isEmpty ? [] : bText.components(separatedBy: "\n")
            self._baselineLines = bLines
            self.lastSavedLineCount = bLines.count
        } else {
            self._baselineLines = lines
            self.lastSavedLineCount = lines.count
        }
    }

    /// Promotes this lightweight slice buffer to a full-file buffer using the full content on disk
    public func promoteToFullFile(diskLines: [String], baselineDiskLines: [String]) {
        self.storage = .mutable(lines: diskLines)
        self._baselineLines = baselineDiskLines
        self.lastSavedLineCount = diskLines.count
        self.startLineNumber = 1
        self.isFullFile = true
        self.isLazySlice = false
        self.version &+= 1
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
        guard row >= 0 && row < storage.count else { return nil }
        return storage.line(at: row)
    }

    public subscript(row: BufferRow) -> String {
        storage.line(at: row)
    }

    public func text() -> String {
        storage.allLines.joined(separator: "\n")
    }

    public func lineLength(at row: BufferRow) -> Int {
        line(at: row)?.count ?? 0
    }

    public func text(in range: Range<BufferPoint>) -> String {
        let start = clamp(point: range.lowerBound)
        let end = clamp(point: range.upperBound)
        guard start < end else { return "" }

        if start.row == end.row {
            let lineStr = storage.line(at: start.row)
            let sCol = max(0, min(lineStr.count, start.column))
            let eCol = max(sCol, min(lineStr.count, end.column))
            let startIdx = lineStr.index(lineStr.startIndex, offsetBy: sCol)
            let endIdx = lineStr.index(lineStr.startIndex, offsetBy: eCol)
            return String(lineStr[startIdx..<endIdx])
        }

        var result: [String] = []
        let firstLine = storage.line(at: start.row)
        let firstCol = max(0, min(firstLine.count, start.column))
        let firstIdx = firstLine.index(firstLine.startIndex, offsetBy: firstCol)
        result.append(String(firstLine[firstIdx...]))

        if (start.row + 1) < end.row {
            for r in (start.row + 1)..<end.row {
                result.append(storage.line(at: r))
            }
        }

        let lastLine = storage.line(at: end.row)
        let lastCol = max(0, min(lastLine.count, end.column))
        let lastIdx = lastLine.index(lastLine.startIndex, offsetBy: lastCol)
        result.append(String(lastLine[..<lastIdx]))

        return result.joined(separator: "\n")
    }

    private func ensureMutableLines() -> [String] {
        switch storage {
        case .mutable(let lines):
            return lines
        case .flat, .diffFlat:
            let m = storage.allLines
            storage = .mutable(lines: m)
            return m
        }
    }

    /// Mutates the buffer by replacing a range of text
    @discardableResult
    public func replace(start: BufferPoint, end: BufferPoint, with newText: String) -> Range<BufferPoint> {
        let clampedStart = clamp(point: start)
        let clampedEnd = clamp(point: end)

        guard clampedStart <= clampedEnd else {
            return clampedStart..<clampedStart
        }

        var currentLines = ensureMutableLines()
        let replacementLines = newText.components(separatedBy: "\n")

        let startLine = currentLines[clampedStart.row]
        let endLine = currentLines[clampedEnd.row]

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

        currentLines.replaceSubrange(clampedStart.row...clampedEnd.row, with: newContentLines)
        storage = .mutable(lines: currentLines)
        _isDirty = true
        version &+= 1

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

    public func prependContextLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        var currentLines = ensureMutableLines()
        currentLines.insert(contentsOf: lines, at: 0)
        storage = .mutable(lines: currentLines)
        startLineNumber = max(1, startLineNumber - lines.count)
        version &+= 1
    }

    public func appendContextLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        var currentLines = ensureMutableLines()
        currentLines.append(contentsOf: lines)
        storage = .mutable(lines: currentLines)
        version &+= 1
    }

    public func clamp(row: BufferRow) -> BufferRow {
        max(0, min(storage.count > 0 ? storage.count - 1 : 0, row))
    }

    public func clamp(column: BufferColumn, in row: BufferRow) -> BufferColumn {
        let r = clamp(row: row)
        guard r < storage.count else { return 0 }
        return max(0, min(lineLength(at: r), column))
    }

    public func clamp(point: BufferPoint) -> BufferPoint {
        let r = clamp(row: point.row)
        let c = clamp(column: point.column, in: r)
        return BufferPoint(row: r, column: c)
    }

    public func markSaved() {
        _isDirty = false
        lastSavedLineCount = storage.count
    }

    public func mergeFrom(buffer other: Buffer, overlap: Int) {
        var currentLines = ensureMutableLines()
        let otherLines = other.storage.allLines
        let toAppend: [String]
        if overlap > 0 && overlap <= otherLines.count {
            toAppend = Array(otherLines[overlap...])
        } else if overlap > 0 {
            toAppend = []
        } else {
            toAppend = otherLines
        }
        currentLines.append(contentsOf: toAppend)
        storage = .mutable(lines: currentLines)
        version &+= 1
    }

    /// Saves the current in-memory contents to the underlying disk file.
    public func saveToFile(baseDirectory: String? = nil) throws {
        let diskPath: String
        if let directPath = fullDiskPath, !directPath.isEmpty {
            diskPath = directPath
        } else if let base = baseDirectory, !base.isEmpty {
            diskPath = (base as NSString).appendingPathComponent(filePath)
        } else {
            diskPath = filePath
        }

        let fileURL = URL(fileURLWithPath: diskPath)
        let directoryURL = fileURL.deletingLastPathComponent()

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        if isFullFile || !FileManager.default.fileExists(atPath: diskPath) {
            let fullText = text()
            try fullText.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedLineCount = storage.count
        } else {
            // Defensive partial-hunk splicing fallback: never truncate existing file
            let diskText = try String(contentsOfFile: diskPath, encoding: .utf8)
            var diskLines = diskText.components(separatedBy: "\n")
            let replaceStart = max(0, min(diskLines.count, startLineNumber - 1))
            let replaceCount = max(0, lastSavedLineCount)
            let replaceEnd = max(replaceStart, min(diskLines.count, replaceStart + replaceCount))
            diskLines.replaceSubrange(replaceStart..<replaceEnd, with: lines)
            let fullText = diskLines.joined(separator: "\n")
            try fullText.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedLineCount = storage.count
        }
        markSaved()
    }
}
