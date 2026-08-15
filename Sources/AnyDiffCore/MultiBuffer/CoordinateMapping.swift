import Foundation

/// Continuous logical row across all excerpts in a MultiBuffer
public typealias MultiBufferRow = Int

/// A 2D point in the unified coordinate space of a MultiBuffer
public struct MultiBufferPoint: Hashable, Equatable, Comparable, Sendable, CustomStringConvertible {
    public var row: MultiBufferRow
    public var column: Int

    public init(row: MultiBufferRow, column: Int) {
        self.row = row
        self.column = column
    }

    public static let zero = MultiBufferPoint(row: 0, column: 0)

    public static func < (lhs: MultiBufferPoint, rhs: MultiBufferPoint) -> Bool {
        if lhs.row != rhs.row {
            return lhs.row < rhs.row
        }
        return lhs.column < rhs.column
    }

    public var description: String {
        "MB(\(row):\(column))"
    }
}

/// Resolved location of a coordinate inside an excerpt and underlying buffer
public struct ExcerptLocation: Equatable, Sendable {
    public var excerptIndex: ExcerptIndex
    public var bufferId: BufferId
    public var filePath: String
    public var bufferRow: BufferRow // Zero-based row in buffer
    public var bufferColumn: Int
    public var fileLineNumber: Int { bufferRow + 1 } // 1-based line number

    public init(
        excerptIndex: ExcerptIndex,
        bufferId: BufferId,
        filePath: String,
        bufferRow: BufferRow,
        bufferColumn: Int
    ) {
        self.excerptIndex = excerptIndex
        self.bufferId = bufferId
        self.filePath = filePath
        self.bufferRow = bufferRow
        self.bufferColumn = bufferColumn
    }
}
