import Foundation

/// Status of a line in a diff
public enum DiffLineKind: String, Codable, Sendable {
    case unchanged = " "
    case added = "+"
    case deleted = "-"
    case header = "@"
}

/// A single line in a diff hunk
public struct DiffLine: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var kind: DiffLineKind
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var wordDiffRanges: [Range<Int>] // Highlight ranges within `text`

    public init(
        kind: DiffLineKind,
        text: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil,
        wordDiffRanges: [Range<Int>] = []
    ) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.wordDiffRanges = wordDiffRanges
    }
}

/// Overall status of a hunk
public enum DiffHunkStatus: String, Codable, Sendable {
    case added
    case deleted
    case modified
}

/// A contiguous diff hunk in a file
public struct DiffHunk: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var oldRange: Range<Int> // 1-based old line range (e.g. 10..<25)
    public var newRange: Range<Int> // 1-based new line range
    public var header: String       // e.g. "@@ -10,15 +10,18 @@ func start()"
    public var lines: [DiffLine]
    public var lineSpans: [LineSpan]
    public var status: DiffHunkStatus
    public var addedLineCount: Int
    public var deletedLineCount: Int

    public init(
        oldRange: Range<Int>,
        newRange: Range<Int>,
        header: String,
        lines: [DiffLine] = [],
        lineSpans: [LineSpan] = [],
        status: DiffHunkStatus = .modified,
        addedLineCount: Int? = nil,
        deletedLineCount: Int? = nil
    ) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.header = header
        self.lines = lines
        self.lineSpans = lineSpans
        self.status = status
        if let adds = addedLineCount {
            self.addedLineCount = adds
        } else if !lineSpans.isEmpty {
            self.addedLineCount = lineSpans.reduce(into: 0) { if $1.kind == .added { $0 += 1 } }
        } else {
            self.addedLineCount = lines.reduce(into: 0) { if $1.kind == .added { $0 += 1 } }
        }
        if let dels = deletedLineCount {
            self.deletedLineCount = dels
        } else if !lineSpans.isEmpty {
            self.deletedLineCount = lineSpans.reduce(into: 0) { if $1.kind == .deleted { $0 += 1 } }
        } else {
            self.deletedLineCount = lines.reduce(into: 0) { if $1.kind == .deleted { $0 += 1 } }
        }
    }
}

/// Status of a whole file in a git diff
public enum FileDiffStatus: String, Codable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
}

/// A parsed file diff containing metadata and list of hunks
public struct FileDiff: Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var oldPath: String
    public var newPath: String
    public var status: FileDiffStatus
    public var hunks: [DiffHunk]
    public var isReviewed: Bool = false

    public var displayPath: String {
        switch status {
        case .deleted: return oldPath
        default: return newPath
        }
    }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.addedLineCount }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.deletedLineCount }
    }

    public init(
        oldPath: String,
        newPath: String,
        status: FileDiffStatus = .modified,
        hunks: [DiffHunk] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.hunks = hunks
    }
}
