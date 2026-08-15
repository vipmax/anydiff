import Foundation

/// A code review comment attached to a file and line number
public struct ReviewComment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var filePath: String
    public var lineNumber: Int // 1-based line number in new file or diff
    public var author: String
    public var content: String
    public var createdAt: Date
    public var isResolved: Bool
    public var reactions: [String: Int] // e.g. ["👍": 2, "❤️": 1]

    public init(
        id: UUID = UUID(),
        filePath: String,
        lineNumber: Int,
        author: String = "You",
        content: String,
        createdAt: Date = Date(),
        isResolved: Bool = false,
        reactions: [String: Int] = [:]
    ) {
        self.id = id
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.author = author
        self.content = content
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.reactions = reactions
    }
}

/// Overall PR review status decision
public enum ReviewDecision: String, Codable, Sendable {
    case pending = "Pending"
    case approved = "Approved"
    case changesRequested = "Changes Requested"
    case commented = "Commented"
}

/// Manager maintaining PR reviews, inline comments and reviewed files state
public final class ReviewManager: ObservableObject, @unchecked Sendable {
    @Published public var comments: [ReviewComment] = []
    @Published public var reviewedFiles: Set<String> = []
    @Published public var decision: ReviewDecision = .pending

    public init(comments: [ReviewComment] = [], reviewedFiles: Set<String> = [], decision: ReviewDecision = .pending) {
        self.comments = comments
        self.reviewedFiles = reviewedFiles
        self.decision = decision
    }

    public func addComment(filePath: String, lineNumber: Int, author: String = "You", content: String) -> ReviewComment {
        let comment = ReviewComment(filePath: filePath, lineNumber: lineNumber, author: author, content: content)
        comments.append(comment)
        return comment
    }

    public func removeComment(id: UUID) {
        comments.removeAll { $0.id == id }
    }

    public func toggleResolved(id: UUID) {
        if let idx = comments.firstIndex(where: { $0.id == id }) {
            comments[idx].isResolved.toggle()
        }
    }

    public func toggleReviewed(filePath: String) {
        if reviewedFiles.contains(filePath) {
            reviewedFiles.remove(filePath)
        } else {
            reviewedFiles.insert(filePath)
        }
    }

    public func isFileReviewed(filePath: String) -> Bool {
        reviewedFiles.contains(filePath)
    }

    public func comments(for filePath: String, lineNumber: Int) -> [ReviewComment] {
        comments.filter { $0.filePath == filePath && $0.lineNumber == lineNumber }
    }
}
