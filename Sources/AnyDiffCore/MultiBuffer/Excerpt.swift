import Foundation

/// Index of an excerpt in a MultiBuffer
public typealias ExcerptIndex = Int

/// A slice/window of a file Buffer displayed within a MultiBuffer
public struct Excerpt: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var bufferId: BufferId
    public var filePath: String
    public var fileStatus: FileDiffStatus

    /// The zero-based row range in the underlying Buffer that this excerpt exposes
    public var bufferRange: Range<BufferRow>

    /// Optional diff hunk associated with this excerpt
    public var hunk: DiffHunk?

    /// Buffer version for which `hunk.lines` was refreshed from an edited
    /// full-file buffer while preserving the original git hunk shape.
    public var stableHunkBufferVersion: Int?

    /// Whether this excerpt is currently collapsed
    public var isCollapsed: Bool

    /// Whether this excerpt starts a new file (so a file header should be shown)
    public var isFileStart: Bool

    /// Line count in this excerpt
    public var lineCount: Int {
        isCollapsed ? 0 : max(0, bufferRange.count)
    }

    public init(
        id: UUID = UUID(),
        bufferId: BufferId,
        filePath: String,
        fileStatus: FileDiffStatus = .modified,
        bufferRange: Range<BufferRow>,
        hunk: DiffHunk? = nil,
        stableHunkBufferVersion: Int? = nil,
        isCollapsed: Bool = false,
        isFileStart: Bool = true
    ) {
        self.id = id
        self.bufferId = bufferId
        self.filePath = filePath
        self.fileStatus = fileStatus
        self.bufferRange = bufferRange
        self.hunk = hunk
        self.stableHunkBufferVersion = stableHunkBufferVersion
        self.isCollapsed = isCollapsed
        self.isFileStart = isFileStart
    }

    /// Expands the excerpt upwards into the buffer
    public mutating func expandUp(by lines: Int, maxRow: Int = 0) {
        let newStart = max(maxRow, bufferRange.lowerBound - lines)
        bufferRange = newStart..<bufferRange.upperBound
    }

    /// Expands the excerpt downwards into the buffer
    public mutating func expandDown(by lines: Int, bufferTotalRows: Int) {
        let newEnd = min(bufferTotalRows, bufferRange.upperBound + lines)
        bufferRange = bufferRange.lowerBound..<newEnd
    }

    /// Fully expands excerpt to cover the entire buffer
    public mutating func expandAll(bufferTotalRows: Int) {
        bufferRange = 0..<bufferTotalRows
    }
}
