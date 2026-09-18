import Foundation

/// Type of Git reference attached to a commit.
public enum GitRefType: String, Codable, Hashable, Sendable {
    case head
    case localBranch
    case remoteBranch
    case tag

    public var isBranch: Bool {
        self == .head || self == .localBranch || self == .remoteBranch
    }

    public var isTag: Bool {
        self == .tag
    }
}

/// Represents a Git reference (branch, tag, HEAD) pointing to a commit.
public struct GitRef: Identifiable, Hashable, Sendable {
    public let name: String
    public let shortName: String
    public let type: GitRefType

    public var id: String { name }

    public init(name: String, shortName: String, type: GitRefType) {
        self.name = name
        self.shortName = shortName
        self.type = type
    }
}

/// Represents a Git commit with its topology and metadata.
public struct GitCommit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let shortHash: String
    public let parentHashes: [String]
    public let authorName: String
    public let authorEmail: String
    public let date: Date
    public let summary: String
    public let body: String
    public var refs: [GitRef]
    public let filesChanged: Int
    public let additions: Int
    public let deletions: Int

    public var id: String { hash }

    public var isMergeCommit: Bool {
        parentHashes.count > 1
    }

    public var isRootCommit: Bool {
        parentHashes.isEmpty
    }

    public init(
        hash: String,
        shortHash: String,
        parentHashes: [String],
        authorName: String,
        authorEmail: String,
        date: Date,
        summary: String,
        body: String = "",
        refs: [GitRef] = [],
        filesChanged: Int = 0,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.hash = hash
        self.shortHash = shortHash
        self.parentHashes = parentHashes
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.summary = summary
        self.body = body
        self.refs = refs
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }
}

/// Represents a file modified in a commit, with additions and deletions stats.
public struct CommitFileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool

    public init(path: String, additions: Int, deletions: Int, isBinary: Bool = false) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }

    public var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var directoryPath: String {
        let dir = (path as NSString).deletingLastPathComponent
        return (dir.isEmpty || dir == ".") ? "" : dir
    }
}
