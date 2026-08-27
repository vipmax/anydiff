import Foundation
import AppKit
@preconcurrency import CoreText

/// A single slot in `LineRenderCache` mapping a sequential `displayLineIndex` to its cached `CTLine`.
/// Tagged with `lineIndex` to detect slot collisions in the direct-mapped ring buffer in 1 CPU cycle.
public struct LineCacheSlot: @unchecked Sendable {
    public var lineIndex: Int = -1
    public var ctLine: CTLine?

    public init(lineIndex: Int = -1, ctLine: CTLine? = nil) {
        self.lineIndex = lineIndex
        self.ctLine = ctLine
    }
}

/// Direct-mapped circular render cache (2048 slots) accessed via bitwise mask in 1 CPU cycle.
/// Designed to be owned per-editor view instance on the Main Thread (lock-free).
public final class LineRenderCache: @unchecked Sendable {
    public static let slotCount = 2048
    public static let slotMask = 2047 // 2048 - 1 (0b0111_1111_1111)

    @usableFromInline
    var slots: [LineCacheSlot]

    public init() {
        self.slots = [LineCacheSlot](repeating: LineCacheSlot(), count: Self.slotCount)
    }

    @inlinable
    public func get(lineIndex: Int) -> CTLine? {
        let slot = lineIndex & Self.slotMask
        let entry = slots[slot]
        if entry.lineIndex == lineIndex {
            return entry.ctLine
        }
        return nil
    }

    @inlinable
    public func set(lineIndex: Int, ctLine: CTLine) {
        let slot = lineIndex & Self.slotMask
        slots[slot] = LineCacheSlot(lineIndex: lineIndex, ctLine: ctLine)
    }

    public func clear() {
        slots = [LineCacheSlot](repeating: LineCacheSlot(), count: Self.slotCount)
    }

    /// Invalidates all cached lines at and below the given line index (e.g. when lines are inserted or deleted)
    public func invalidate(from lineIndex: Int) {
        for i in 0..<Self.slotCount {
            if slots[i].lineIndex >= lineIndex {
                slots[i] = LineCacheSlot()
            }
        }
    }

    /// Invalidates a single cached line index (e.g. on in-place character edit)
    public func invalidate(lineIndex: Int) {
        let slot = lineIndex & Self.slotMask
        if slots[slot].lineIndex == lineIndex {
            slots[slot] = LineCacheSlot()
        }
    }
}

public extension CTLine {
    /// Converts a horizontal pixel offset X into a character index
    @inlinable
    func characterIndex(at xOffset: CGFloat) -> Int {
        CTLineGetStringIndexForPosition(self, CGPoint(x: xOffset, y: 0))
    }

    /// Converts a character index into a horizontal pixel offset X
    @inlinable
    func xOffset(for characterIndex: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(self, characterIndex, nil)
    }
}

