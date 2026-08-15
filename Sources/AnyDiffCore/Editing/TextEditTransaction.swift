import Foundation

/// Represents a single text edit operation on a buffer
public struct TextEdit: Sendable, Equatable {
    public var bufferId: BufferId
    public var range: Range<BufferPoint>
    public var oldText: String
    public var newText: String

    public init(bufferId: BufferId, range: Range<BufferPoint>, oldText: String, newText: String) {
        self.bufferId = bufferId
        self.range = range
        self.oldText = oldText
        self.newText = newText
    }
}

/// An atomic transaction containing one or more edits with cursor/selection state
public struct EditTransaction: Sendable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var edits: [TextEdit]
    public var selectionBefore: Range<MultiBufferPoint>?
    public var selectionAfter: Range<MultiBufferPoint>?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        edits: [TextEdit],
        selectionBefore: Range<MultiBufferPoint>? = nil,
        selectionAfter: Range<MultiBufferPoint>? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.edits = edits
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
    }
}
