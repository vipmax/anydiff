import Foundation

/// A single cell (left or right column) in a side-by-side split diff row
public struct SplitDiffCell: Sendable, Equatable {
    public var lineNumber: Int?
    public var text: String
    public var diffKind: DiffLineKind
    public var wordDiffRanges: [Range<Int>]
    public var isSpacer: Bool
    public var bufferRow: BufferRow?
    public var multiBufferRow: MultiBufferRow?

    public static let emptySpacer = SplitDiffCell(
        lineNumber: nil,
        text: "",
        diffKind: .unchanged,
        wordDiffRanges: [],
        isSpacer: true,
        bufferRow: nil,
        multiBufferRow: nil
    )

    public init(
        lineNumber: Int?,
        text: String,
        diffKind: DiffLineKind,
        wordDiffRanges: [Range<Int>] = [],
        isSpacer: Bool = false,
        bufferRow: BufferRow? = nil,
        multiBufferRow: MultiBufferRow? = nil
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.diffKind = diffKind
        self.wordDiffRanges = wordDiffRanges
        self.isSpacer = isSpacer
        self.bufferRow = bufferRow
        self.multiBufferRow = multiBufferRow
    }
}

/// A paired row in a side-by-side split diff
public struct SplitDiffRow: Sendable, Equatable {
    public var left: SplitDiffCell
    public var right: SplitDiffCell
    public var expandInfo: ExpandInfo?
    public var multiBufferRow: MultiBufferRow?

    public init(
        left: SplitDiffCell,
        right: SplitDiffCell,
        expandInfo: ExpandInfo? = nil,
        multiBufferRow: MultiBufferRow? = nil
    ) {
        self.left = left
        self.right = right
        self.expandInfo = expandInfo
        self.multiBufferRow = multiBufferRow
    }
}

/// Zero-allocation alignment engine for transforming unified diff lines into paired Side-by-Side rows
public final class SplitDiffEngine: Sendable {
    public static let shared = SplitDiffEngine()

    public init() {}

    /// Aligns a slice of DiffLines with associated bufferRows into paired SplitDiffRows
    public func align(diffLines: [(line: DiffLine, bufferRow: Int)]) -> [SplitDiffRow] {
        guard !diffLines.isEmpty else { return [] }

        var result: [SplitDiffRow] = []
        result.reserveCapacity(diffLines.count)

        var idx = 0
        let count = diffLines.count

        while idx < count {
            let item = diffLines[idx]
            let line = item.line
            let bRow = item.bufferRow

            switch line.kind {
            case .unchanged, .header:
                let left = SplitDiffCell(
                    lineNumber: line.oldLineNumber,
                    text: line.text,
                    diffKind: line.kind,
                    wordDiffRanges: [],
                    isSpacer: false,
                    bufferRow: bRow
                )
                let right = SplitDiffCell(
                    lineNumber: line.newLineNumber,
                    text: line.text,
                    diffKind: line.kind,
                    wordDiffRanges: [],
                    isSpacer: false,
                    bufferRow: bRow
                )
                result.append(SplitDiffRow(left: left, right: right))
                idx += 1

            case .deleted, .added:
                // Scan contiguous change block without any heap allocations
                let blockStart = idx
                var delCount = 0
                var addCount = 0
                while idx < count {
                    let k = diffLines[idx].line.kind
                    if k == .deleted {
                        delCount += 1
                        idx += 1
                    } else if k == .added {
                        addCount += 1
                        idx += 1
                    } else {
                        break
                    }
                }
                let blockEnd = idx

                var delCursor = blockStart
                var addCursor = blockStart
                let maxRows = max(delCount, addCount)

                for _ in 0..<maxRows {
                    var leftCell: SplitDiffCell = .emptySpacer
                    while delCursor < blockEnd {
                        let item = diffLines[delCursor]
                        delCursor += 1
                        if item.line.kind == .deleted {
                            leftCell = SplitDiffCell(
                                lineNumber: item.line.oldLineNumber,
                                text: item.line.text,
                                diffKind: .deleted,
                                wordDiffRanges: item.line.wordDiffRanges,
                                isSpacer: false,
                                bufferRow: item.bufferRow
                            )
                            break
                        }
                    }

                    var rightCell: SplitDiffCell = .emptySpacer
                    while addCursor < blockEnd {
                        let item = diffLines[addCursor]
                        addCursor += 1
                        if item.line.kind == .added {
                            rightCell = SplitDiffCell(
                                lineNumber: item.line.newLineNumber,
                                text: item.line.text,
                                diffKind: .added,
                                wordDiffRanges: item.line.wordDiffRanges,
                                isSpacer: false,
                                bufferRow: item.bufferRow
                            )
                            break
                        }
                    }

                    // Compute intra-line word diffs if both sides are present and don't already have wordDiffRanges
                    if !leftCell.isSpacer && !rightCell.isSpacer && leftCell.wordDiffRanges.isEmpty && rightCell.wordDiffRanges.isEmpty {
                        let (oldRanges, newRanges) = WordDiffEngine.shared.diffWords(oldText: leftCell.text, newText: rightCell.text)
                        leftCell.wordDiffRanges = oldRanges
                        rightCell.wordDiffRanges = newRanges
                    }

                    result.append(SplitDiffRow(left: leftCell, right: rightCell))
                }
            }
        }

        return result
    }
}
