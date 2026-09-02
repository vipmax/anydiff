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

public extension String {
    /// Converts a Swift Character index (0...count) into a UTF-16 code unit offset (0...utf16.count)
    @inlinable
    func utf16Offset(forCharacterIndex charIdx: Int) -> Int {
        let cnt = count
        let clamped = max(0, min(cnt, charIdx))
        if utf8.count == cnt {
            return clamped
        }
        let idx = index(startIndex, offsetBy: clamped)
        return idx.utf16Offset(in: self)
    }

    /// Converts a UTF-16 code unit offset (0...utf16.count) into a Swift Character index (0...count)
    @inlinable
    func characterIndex(forUtf16Offset utf16Offset: Int) -> Int {
        let u16Count = utf16.count
        let clamped = max(0, min(u16Count, utf16Offset))
        if utf8.count == count {
            return clamped
        }
        let u16Idx = utf16.index(utf16.startIndex, offsetBy: clamped)
        if let sIdx = u16Idx.samePosition(in: self) {
            return distance(from: startIndex, to: sIdx)
        }
        var cur = u16Idx
        while cur > utf16.startIndex {
            cur = utf16.index(before: cur)
            if let sIdx = cur.samePosition(in: self) {
                return distance(from: startIndex, to: sIdx)
            }
        }
        return 0
    }
}

public extension CTLine {
    /// Converts a horizontal pixel offset X into a UTF-16 string index
    @inlinable
    func utf16Index(at xOffset: CGFloat) -> Int {
        CTLineGetStringIndexForPosition(self, CGPoint(x: xOffset, y: 0))
    }

    /// Converts a horizontal pixel offset X into a Swift Character index for the given line text
    @inlinable
    func characterIndex(at xOffset: CGFloat, in text: String) -> Int {
        let u16 = CTLineGetStringIndexForPosition(self, CGPoint(x: xOffset, y: 0))
        return text.characterIndex(forUtf16Offset: u16)
    }

    /// Converts a horizontal pixel offset X into a UTF-16 index (legacy compat)
    @inlinable
    func characterIndex(at xOffset: CGFloat) -> Int {
        CTLineGetStringIndexForPosition(self, CGPoint(x: xOffset, y: 0))
    }

    /// Converts a UTF-16 index into a horizontal pixel offset X
    @inlinable
    func xOffset(for characterIndex: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(self, characterIndex, nil)
    }

    /// Converts a Swift Character index into a horizontal pixel offset X for the given line text
    @inlinable
    func xOffset(forCharacterIndex charIdx: Int, in text: String) -> CGFloat {
        let u16 = text.utf16Offset(forCharacterIndex: charIdx)
        return CTLineGetOffsetForStringIndex(self, u16, nil)
    }
}

