import SwiftUI
import AppKit
import AnyDiffCore

public struct EditorHostView: NSViewRepresentable {
    public var displayMap: DisplayMap
    public var theme: Theme
    public var fontSize: CGFloat
    public var isEditable: Bool
    public var selectedFilePath: String?
    public var onCursorChange: (ExcerptLocation?, MultiBufferPoint) -> Void
    public var onAddCommentRequest: (String, Int) -> Void

    public init(
        displayMap: DisplayMap,
        theme: Theme,
        fontSize: CGFloat = 13,
        isEditable: Bool = true,
        selectedFilePath: String? = nil,
        onCursorChange: @escaping (ExcerptLocation?, MultiBufferPoint) -> Void,
        onAddCommentRequest: @escaping (String, Int) -> Void
    ) {
        self.displayMap = displayMap
        self.theme = theme
        self.fontSize = fontSize
        self.isEditable = isEditable
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
        editorView.isEditable = isEditable
        editorView.delegate = context.coordinator
        context.coordinator.editorView = editorView
        context.coordinator.lastLoadRevision = displayMap.loadRevision
        DispatchQueue.main.async {
            // The DisplayMap may already contain loaded content when SwiftUI
            // creates this view, so there may be no revision transition to
            // trigger the initial cursor/focus setup.
            editorView.resetCursorToFirstVisibleLine()
            if let path = selectedFilePath {
                context.coordinator.lastScrolledFilePath = path
                editorView.scrollToFilePath(path)
            }
        }
        return editorView
    }

    public func updateNSView(_ editorView: CustomMultiBufferEditorView, context: Context) {
        context.coordinator.parent = self

        if editorView.displayMap !== displayMap {
            editorView.displayMap = displayMap
        } else {
            editorView.syncLayoutIfNeeded()
        }

        if context.coordinator.lastLoadRevision != displayMap.loadRevision {
            context.coordinator.lastLoadRevision = displayMap.loadRevision
            if let state = context.coordinator.savedViewState {
                editorView.restoreViewState(state)
            } else {
                editorView.resetCursorToFirstVisibleLine()
            }
        }
        if editorView.theme.id != theme.id {
            editorView.theme = theme
        }
        if editorView.font.pointSize != fontSize {
            editorView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if editorView.isEditable != isEditable {
            editorView.isEditable = isEditable
        }

        if let path = selectedFilePath, path != context.coordinator.lastScrolledFilePath {
            context.coordinator.lastScrolledFilePath = path
            if editorView.window?.firstResponder !== editorView {
                DispatchQueue.main.async {
                    editorView.scrollToFilePath(path)
                    context.coordinator.savedViewState = editorView.captureViewState()
                }
            }
        }
    }

    public final class Coordinator: NSObject, CustomMultiBufferEditorDelegate {
        var parent: EditorHostView
        weak var editorView: CustomMultiBufferEditorView?
        var lastScrolledFilePath: String? = nil
        var lastLoadRevision: UInt64 = 0
        var savedViewState: EditorViewState? = nil

        init(_ parent: EditorHostView) {
            self.parent = parent
        }

        public func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint) {
            if let ev = editorView {
                savedViewState = ev.captureViewState()
            }
            if let path = location?.filePath {
                lastScrolledFilePath = path
            }
            parent.onCursorChange(location, point)
        }

        public func editorDidRequestAddComment(filePath: String, lineNumber: Int) {
            parent.onAddCommentRequest(filePath, lineNumber)
        }

        public func editorDidScroll() {
            if let ev = editorView {
                savedViewState = ev.captureViewState()
                if let file = savedViewState?.selectedFilePath {
                    lastScrolledFilePath = file
                }
            }
        }
    }
}
