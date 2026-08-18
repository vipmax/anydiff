import Foundation
import AnyDiffCore

/// Hierarchical Excerpt-Based Spatial Layout Model for Virtualized Editing (Zero-Allocation)
public struct ExcerptLayout: Sendable, Equatable {
    public var excerptIndex: Int
    public var filePath: String
    public var displayRange: Range<Int>
    public var codeRange: Range<Int>
    public var startY: CGFloat
    public var height: CGFloat
    public var hasHeader: Bool
    public var hasTopGap: Bool
    public var hasBottomGap: Bool
    public var codeLineCount: Int
    public var isCollapsed: Bool

    public init(
        excerptIndex: Int,
        filePath: String,
        displayRange: Range<Int>,
        codeRange: Range<Int>,
        startY: CGFloat,
        height: CGFloat,
        hasHeader: Bool,
        hasTopGap: Bool,
        hasBottomGap: Bool,
        codeLineCount: Int,
        isCollapsed: Bool
    ) {
        self.excerptIndex = excerptIndex
        self.filePath = filePath
        self.displayRange = displayRange
        self.codeRange = codeRange
        self.startY = startY
        self.height = height
        self.hasHeader = hasHeader
        self.hasTopGap = hasTopGap
        self.hasBottomGap = hasBottomGap
        self.codeLineCount = codeLineCount
        self.isCollapsed = isCollapsed
    }

    /// Computes the relative Y coordinate of a line within this excerpt in O(1)
    @inlinable
    public func relativeY(for offset: Int, headerHeight: CGFloat, foldGapHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        var curY: CGFloat = 0
        var rem = offset
        if hasHeader {
            if rem == 0 { return curY }
            curY += headerHeight
            rem -= 1
        }
        if !isCollapsed {
            if hasTopGap {
                if rem == 0 { return curY }
                curY += foldGapHeight
                rem -= 1
            }
            if rem < codeLineCount {
                return curY + CGFloat(rem) * lineHeight
            }
            curY += CGFloat(codeLineCount) * lineHeight
            rem -= codeLineCount
            if hasBottomGap {
                if rem == 0 { return curY }
                curY += foldGapHeight
                rem -= 1
            }
        }
        return curY
    }

    /// Computes the height of a specific line within this excerpt in O(1)
    @inlinable
    public func lineHeight(for offset: Int, headerHeight: CGFloat, foldGapHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        var rem = offset
        if hasHeader {
            if rem == 0 { return headerHeight }
            rem -= 1
        }
        if !isCollapsed {
            if hasTopGap {
                if rem == 0 { return foldGapHeight }
                rem -= 1
            }
            if rem < codeLineCount {
                return lineHeight
            }
            rem -= codeLineCount
            if hasBottomGap {
                if rem == 0 { return foldGapHeight }
            }
        }
        return lineHeight
    }

    /// Computes the line offset within this excerpt for a relative Y position in O(1)
    @inlinable
    public func lineOffset(atRelativeY relY: CGFloat, headerHeight: CGFloat, foldGapHeight: CGFloat, lineHeight: CGFloat) -> Int {
        var curY: CGFloat = 0
        var offset = 0
        if hasHeader {
            if relY < curY + headerHeight {
                return offset
            }
            curY += headerHeight
            offset += 1
        }
        if !isCollapsed {
            if hasTopGap {
                if relY < curY + foldGapHeight {
                    return offset
                }
                curY += foldGapHeight
                offset += 1
            }
            let codeHeight = CGFloat(codeLineCount) * lineHeight
            if codeLineCount > 0 && relY < curY + codeHeight {
                let codeIdx = max(0, min(codeLineCount - 1, Int((relY - curY) / lineHeight)))
                return offset + codeIdx
            }
            curY += codeHeight
            offset += codeLineCount
            if hasBottomGap {
                return offset
            }
        }
        return max(0, displayRange.count - 1)
    }
}
