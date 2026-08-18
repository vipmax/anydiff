import Foundation

/// Continuous logical row across all excerpts in a MultiBuffer
public typealias MultiBufferRow = Int

/// A 2D point in the unified coordinate space of a MultiBuffer (compact 8-byte layout)
public struct MultiBufferPoint: Hashable, Equatable, Comparable, Sendable, CustomStringConvertible {
    public var row32: Int32
    public var column32: Int32

    @inlinable
    public var row: MultiBufferRow {
        get { Int(row32) }
        set { row32 = Int32(clamping: newValue) }
    }

    @inlinable
    public var column: Int {
        get { Int(column32) }
        set { column32 = Int32(clamping: newValue) }
    }

    @inlinable
    public init(row: MultiBufferRow, column: Int) {
        self.row32 = Int32(clamping: row)
        self.column32 = Int32(clamping: column)
    }

    @inlinable
    public init(row32: Int32, column32: Int32) {
        self.row32 = row32
        self.column32 = column32
    }

    public static let zero = MultiBufferPoint(row32: 0, column32: 0)

    @inlinable
    public static func < (lhs: MultiBufferPoint, rhs: MultiBufferPoint) -> Bool {
        if lhs.row32 != rhs.row32 {
            return lhs.row32 < rhs.row32
        }
        return lhs.column32 < rhs.column32
    }

    public var description: String {
        "MB(\(row32):\(column32))"
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
