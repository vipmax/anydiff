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
    public var status: DiffHunkStatus

    public var addedLineCount: Int {
        lines.filter { $0.kind == .added }.count
    }

    public var deletedLineCount: Int {
        lines.filter { $0.kind == .deleted }.count
    }

    public init(
        oldRange: Range<Int>,
        newRange: Range<Int>,
        header: String,
        lines: [DiffLine],
        status: DiffHunkStatus = .modified
    ) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.header = header
        self.lines = lines
        self.status = status
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
