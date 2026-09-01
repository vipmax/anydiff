import Foundation

/// A single slot in `WordDiffRenderCache` mapping a sequential line index to its cached intra-line word diff ranges.
/// Tagged with `lineIndex` to detect slot collisions in the direct-mapped ring buffer in 1 CPU cycle.
public struct WordDiffCacheSlot: Sendable {
    public var lineIndex: Int = -1
    public var wordDiffRanges: [Range<Int>] = []

    public init(lineIndex: Int = -1, wordDiffRanges: [Range<Int>] = []) {
        self.lineIndex = lineIndex
        self.wordDiffRanges = wordDiffRanges
    }
}

/// Direct-mapped circular render cache (2048 slots) accessed via bitwise mask in 1 CPU cycle.
/// Provides lock-free O(1) cache lookups for word-level diff highlight ranges by line index.
public final class WordDiffRenderCache: @unchecked Sendable {
    public static let slotCount = 2048
    public static let slotMask = 2047 // 2048 - 1 (0b0111_1111_1111)

    @usableFromInline
    var slots: [WordDiffCacheSlot]

    public init() {
        self.slots = [WordDiffCacheSlot](repeating: WordDiffCacheSlot(), count: Self.slotCount)
    }

    @inlinable
    public func get(lineIndex: Int) -> [Range<Int>]? {
        let slot = lineIndex & Self.slotMask
        let entry = slots[slot]
        if entry.lineIndex == lineIndex {
            return entry.wordDiffRanges
        }
        return nil
    }

    @inlinable
    public func set(lineIndex: Int, wordDiffRanges: [Range<Int>]) {
        let slot = lineIndex & Self.slotMask
        slots[slot] = WordDiffCacheSlot(lineIndex: lineIndex, wordDiffRanges: wordDiffRanges)
    }

    public func clear() {
        slots = [WordDiffCacheSlot](repeating: WordDiffCacheSlot(), count: Self.slotCount)
    }

    /// Invalidates all cached entries at and below the given line index (e.g. when lines are inserted or deleted)
    public func invalidate(from lineIndex: Int) {
        for i in 0..<Self.slotCount {
            if slots[i].lineIndex >= lineIndex {
                slots[i] = WordDiffCacheSlot()
            }
        }
    }

    /// Invalidates a single cached line index (e.g. on in-place character edit)
    public func invalidate(lineIndex: Int) {
        let slot = lineIndex & Self.slotMask
        if slots[slot].lineIndex == lineIndex {
            slots[slot] = WordDiffCacheSlot()
        }
    }
}
