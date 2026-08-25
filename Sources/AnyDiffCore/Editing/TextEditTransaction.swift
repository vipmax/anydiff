import Foundation

/// Represents a single text edit operation on a buffer
public struct TextEdit: Sendable, Equatable {
    public var bufferId: BufferId
    public var range: Range<BufferPoint>
    /// The range in the buffer before this edit. `range` is the range after it.
    /// Older callers may omit this for insertions and edits that use the same range.
    public var oldRange: Range<BufferPoint>?
    public var oldText: String
    public var newText: String

    public init(
        bufferId: BufferId,
        range: Range<BufferPoint>,
        oldRange: Range<BufferPoint>? = nil,
        oldText: String,
        newText: String
    ) {
        self.bufferId = bufferId
        self.range = range
        self.oldRange = oldRange
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
    public var cursorBefore: MultiBufferPoint?
    public var anchorBefore: MultiBufferPoint?
    public var cursorAfter: MultiBufferPoint?
    public var anchorAfter: MultiBufferPoint?
    /// Marks plain typing edits that may be coalesced with adjacent typing.
    public var isTyping: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        edits: [TextEdit],
        selectionBefore: Range<MultiBufferPoint>? = nil,
        selectionAfter: Range<MultiBufferPoint>? = nil,
        cursorBefore: MultiBufferPoint? = nil,
        anchorBefore: MultiBufferPoint? = nil,
        cursorAfter: MultiBufferPoint? = nil,
        anchorAfter: MultiBufferPoint? = nil,
        isTyping: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.edits = edits
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.cursorBefore = cursorBefore
        self.anchorBefore = anchorBefore
        self.cursorAfter = cursorAfter
        self.anchorAfter = anchorAfter
        self.isTyping = isTyping
    }
}
