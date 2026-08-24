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
    case line(filePath: String, lineNumber: Int)
}

/// Anchor for preserving the exact viewport position across diff reloads
public struct EditorScrollAnchor: Sendable, Equatable {
    public let filePath: String
    public let lineNumber: Int?
    public let isHeader: Bool
    public let pixelOffsetInLine: CGFloat

    public init(
        filePath: String,
        lineNumber: Int?,
        isHeader: Bool = false,
        pixelOffsetInLine: CGFloat = 0
    ) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.isHeader = isHeader
        self.pixelOffsetInLine = pixelOffsetInLine
    }
}

/// Anchor for preserving cursor position across diff reloads
public struct EditorCursorAnchor: Sendable, Equatable {
    public let filePath: String
    public let lineNumber: Int
    public let column: Int

    public init(
        filePath: String,
        lineNumber: Int,
        column: Int
    ) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.column = column
    }
}

/// Encapsulates the complete anchor-based cursor and viewport state of CustomMultiBufferEditorView
public struct EditorViewState: Sendable, Equatable {
    public let cursorAnchor: EditorCursorAnchor?
    public let selectionAnchor: EditorCursorAnchor?
    public let scrollAnchor: EditorScrollAnchor?
    public let scrollOffsetX: CGFloat
    public let selectedFilePath: String?

    public init(
        cursorAnchor: EditorCursorAnchor?,
        selectionAnchor: EditorCursorAnchor? = nil,
        scrollAnchor: EditorScrollAnchor?,
        scrollOffsetX: CGFloat = 0,
        selectedFilePath: String? = nil
    ) {
        self.cursorAnchor = cursorAnchor
        self.selectionAnchor = selectionAnchor
        self.scrollAnchor = scrollAnchor
        self.scrollOffsetX = scrollOffsetX
        self.selectedFilePath = selectedFilePath
    }
}

extension Notification.Name {
    static let focusFileInEditor = Notification.Name("AnyDiff_focusFileInEditor")
}
