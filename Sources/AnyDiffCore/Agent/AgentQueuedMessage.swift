import Foundation

public enum QueueMoveDirection: Sendable, Equatable {
    case up
    case down
}

public struct AgentQueuedMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var images: [AgentImageAttachment]
    public var workingDirectory: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        images: [AgentImageAttachment] = [],
        workingDirectory: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
    }
}
