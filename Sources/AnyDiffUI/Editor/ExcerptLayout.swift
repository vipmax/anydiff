import Foundation
import AnyDiffCore

/// Hierarchical Excerpt-Based Spatial Layout Model for Virtualized Editing
public struct ExcerptLayout: Sendable, Equatable {
    public var excerptIndex: Int
    public var filePath: String
    public var displayRange: Range<Int>
    public var codeRange: Range<Int>
    public var startY: CGFloat
    public var height: CGFloat
    public var lineRelativeY: [CGFloat]

    public init(
        excerptIndex: Int,
        filePath: String,
        displayRange: Range<Int>,
        codeRange: Range<Int>,
        startY: CGFloat,
        height: CGFloat,
        lineRelativeY: [CGFloat]
    ) {
        self.excerptIndex = excerptIndex
        self.filePath = filePath
        self.displayRange = displayRange
        self.codeRange = codeRange
        self.startY = startY
        self.height = height
        self.lineRelativeY = lineRelativeY
    }
}
