import Foundation
import AnyDiffCore

/// Granularity of text selection within the MultiBuffer editor
enum SelectionGranularity: Sendable, Equatable {
    case character
    case word(initialStart: Int, initialEnd: Int, initialRow: MultiBufferRow)
    case line(initialRow: MultiBufferRow)
}

/// Cached section metrics for excerpt headers and content boundaries
struct FileSection: Sendable, Equatable {
    let info: ExcerptHeaderInfo
    var headerMinY: CGFloat
    var contentMaxY: CGFloat
}

/// Axis for scrollbar and scroll event filtering
enum ScrollAxis: Sendable, Equatable {
    case vertical
    case horizontal
}

/// Active drag state for overlay scrollbars
enum ScrollbarDragAxis: Sendable, Equatable {
    case vertical
    case horizontal
}

/// Anchor for preserving screen position across vertical expansions/folds
enum ScrollAnchor: Sendable, Equatable {
    case header(filePath: String)
    case code(bufferId: BufferId, bufferRow: BufferRow)
}
