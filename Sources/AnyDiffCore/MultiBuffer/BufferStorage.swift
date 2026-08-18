import Foundation

/// Compact slice describing a line in a flat raw byte buffer without heap String allocations
public struct LineSpan: Sendable, Equatable {
    public let offset: UInt32
    public let length: UInt16
    public let kind: DiffLineKind
    public let oldLineNumber: UInt32 // 0 represents nil
    public let newLineNumber: UInt32 // 0 represents nil

    public init(
        offset: UInt32,
        length: UInt16,
        kind: DiffLineKind = .unchanged,
        oldLineNumber: UInt32 = 0,
        newLineNumber: UInt32 = 0
    ) {
        self.offset = offset
        self.length = length
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// Selects which side of a unified diff is exposed as editable buffer contents.
public enum FlatDiffSide: Sendable, Equatable {
    case old
    case new

    fileprivate func includes(_ kind: DiffLineKind) -> Bool {
        switch self {
        case .old:
            return kind != .added
        case .new:
            return kind != .deleted
        }
    }
}

/// Hybrid storage representing lines either as zero-copy raw byte slices or mutable Swift strings
public enum BufferStorage: @unchecked Sendable {
    case flat(data: Data, spans: [LineSpan])
    /// Shares the hunk's complete span array and selects one side through a tiny rank index.
    /// This avoids allocating a second filtered `[LineSpan]` for every hunk.
    case diffFlat(data: Data, spans: [LineSpan], side: FlatDiffSide, rankCheckpoints: [UInt32], lineCount: Int)
    case mutable(lines: [String])

    private static let rankStride = 256

    public static func makeDiffFlat(data: Data, spans: [LineSpan], side: FlatDiffSide) -> BufferStorage {
        var checkpoints: [UInt32] = []
        checkpoints.reserveCapacity((spans.count + rankStride - 1) / rankStride)

        var includedCount: UInt32 = 0
        for index in spans.indices {
            if index % rankStride == 0 {
                checkpoints.append(includedCount)
            }
            if side.includes(spans[index].kind) {
                includedCount &+= 1
            }
        }

        return .diffFlat(
            data: data,
            spans: spans,
            side: side,
            rankCheckpoints: checkpoints,
            lineCount: Int(includedCount)
        )
    }

    public var count: Int {
        switch self {
        case .flat(_, let spans):
            return spans.count
        case .diffFlat(_, _, _, _, let lineCount):
            return lineCount
        case .mutable(let lines):
            return lines.count
        }
    }

    public func line(at index: Int) -> String {
        switch self {
        case .flat(let data, let spans):
            guard index >= 0 && index < spans.count else { return "" }
            return Self.decode(spans[index], from: data)
        case .diffFlat(let data, let spans, let side, let checkpoints, let lineCount):
            guard index >= 0 && index < lineCount, !checkpoints.isEmpty else { return "" }

            // Find the last raw-span block whose included-line rank is <= index.
            var low = 0
            var high = checkpoints.count - 1
            var block = 0
            while low <= high {
                let mid = (low + high) / 2
                if Int(checkpoints[mid]) <= index {
                    block = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            var logicalRow = Int(checkpoints[block])
            var rawIndex = block * Self.rankStride
            while rawIndex < spans.count {
                let span = spans[rawIndex]
                if side.includes(span.kind) {
                    if logicalRow == index {
                        return Self.decode(span, from: data)
                    }
                    logicalRow += 1
                }
                rawIndex += 1
            }
            return ""
        case .mutable(let lines):
            guard index >= 0 && index < lines.count else { return "" }
            return lines[index]
        }
    }

    public var allLines: [String] {
        switch self {
        case .flat(let data, let spans):
            var result: [String] = []
            result.reserveCapacity(spans.count)
            for span in spans {
                result.append(Self.decode(span, from: data))
            }
            return result
        case .diffFlat(let data, let spans, let side, _, let lineCount):
            var result: [String] = []
            result.reserveCapacity(lineCount)
            for span in spans where side.includes(span.kind) {
                result.append(Self.decode(span, from: data))
            }
            return result
        case .mutable(let lines):
            return lines
        }
    }

    /// Decodes a raw diff span without materializing any neighboring lines.
    public func text(for span: LineSpan) -> String? {
        switch self {
        case .flat(let data, _), .diffFlat(let data, _, _, _, _):
            return Self.decode(span, from: data)
        case .mutable:
            return nil
        }
    }

    private static func decode(_ span: LineSpan, from data: Data) -> String {
        let start = Int(span.offset)
        guard start >= 0, start <= data.count else { return "" }
        let end = min(data.count, start + Int(span.length))
        guard start <= end else { return "" }
        return String(decoding: data[start..<end], as: UTF8.self)
    }
}
