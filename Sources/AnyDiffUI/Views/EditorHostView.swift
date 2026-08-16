import SwiftUI
import AppKit
import AnyDiffCore

public struct EditorHostView: NSViewRepresentable {
    public var displayMap: DisplayMap
    public var theme: Theme
    public var fontSize: CGFloat
    public var selectedFilePath: String?
    public var onCursorChange: (ExcerptLocation?, MultiBufferPoint) -> Void
    public var onAddCommentRequest: (String, Int) -> Void

    public init(
        displayMap: DisplayMap,
        theme: Theme,
        fontSize: CGFloat = 13,
        selectedFilePath: String? = nil,
        onCursorChange: @escaping (ExcerptLocation?, MultiBufferPoint) -> Void,
        onAddCommentRequest: @escaping (String, Int) -> Void
    ) {
        self.displayMap = displayMap
        self.theme = theme
        self.fontSize = fontSize
        self.selectedFilePath = selectedFilePath
        self.onCursorChange = onCursorChange
        self.onAddCommentRequest = onAddCommentRequest
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> CustomMultiBufferEditorView {
        let editorView = CustomMultiBufferEditorView(displayMap: displayMap, theme: theme)
        editorView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editorView.delegate = context.coordinator
        context.coordinator.editorView = editorView
        if let path = selectedFilePath {
            context.coordinator.lastScrolledFilePath = path
            DispatchQueue.main.async {
                editorView.scrollToFilePath(path)
            }
        }
        return editorView
    }

    public func updateNSView(_ editorView: CustomMultiBufferEditorView, context: Context) {
        if editorView.displayMap !== displayMap {
            editorView.displayMap = displayMap
        }
        if editorView.theme.id != theme.id {
            editorView.theme = theme
        }
        if editorView.font.pointSize != fontSize {
            editorView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        editorView.invalidateLayout()

        if let path = selectedFilePath, path != context.coordinator.lastScrolledFilePath {
            context.coordinator.lastScrolledFilePath = path
            DispatchQueue.main.async {
                editorView.scrollToFilePath(path)
            }
        }
    }

    public final class Coordinator: NSObject, CustomMultiBufferEditorDelegate {
        var parent: EditorHostView
        weak var editorView: CustomMultiBufferEditorView?
        var lastScrolledFilePath: String? = nil

        init(_ parent: EditorHostView) {
            self.parent = parent
        }

        public func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint) {
            parent.onCursorChange(location, point)
        }

        public func editorDidRequestAddComment(filePath: String, lineNumber: Int) {
            parent.onAddCommentRequest(filePath, lineNumber)
        }
    }
}
