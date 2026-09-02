import SwiftUI
import AppKit
import AnyDiffCore

public struct SearchMatchScrollRequest: Equatable {
    public let id: UInt64
    public let matchIndex: Int

    public init(id: UInt64, matchIndex: Int) {
        self.id = id
        self.matchIndex = matchIndex
    }
}

public struct EditorHostView: NSViewRepresentable {
    public var displayMap: DisplayMap
    public var theme: Theme
    public var fontSize: CGFloat
    public var isEditable: Bool
    public var selectedFilePath: String?
    public var viewStateResetToken: UInt64?
    public var searchMatches: [ProjectSearchMatch]
    public var activeMatchIndex: Int?
    public var searchMatchScrollRequest: SearchMatchScrollRequest?
    public var onCursorChange: (ExcerptLocation?, MultiBufferPoint) -> Void
    public var onAddCommentRequest: (String, Int) -> Void
    public var onContentEdited: (() -> Void)?

    public init(
        displayMap: DisplayMap,
        theme: Theme,
        fontSize: CGFloat = 13,
        isEditable: Bool = true,
        selectedFilePath: String? = nil,
        viewStateResetToken: UInt64? = nil,
        searchMatches: [ProjectSearchMatch] = [],
        activeMatchIndex: Int? = nil,
        searchMatchScrollRequest: SearchMatchScrollRequest? = nil,
        onCursorChange: @escaping (ExcerptLocation?, MultiBufferPoint) -> Void,
        onAddCommentRequest: @escaping (String, Int) -> Void,
        onContentEdited: (() -> Void)? = nil
    ) {
        self.displayMap = displayMap
        self.theme = theme
        self.fontSize = fontSize
        self.isEditable = isEditable
        self.selectedFilePath = selectedFilePath
        self.viewStateResetToken = viewStateResetToken
        self.searchMatches = searchMatches
        self.activeMatchIndex = activeMatchIndex
        self.searchMatchScrollRequest = searchMatchScrollRequest
        self.onCursorChange = onCursorChange
        self.onAddCommentRequest = onAddCommentRequest
        self.onContentEdited = onContentEdited
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
        let displayMapID = ObjectIdentifier(displayMap)
        context.coordinator.activeDisplayMapID = displayMapID
        context.coordinator.lastLoadRevisions[displayMapID] = displayMap.loadRevision
        DispatchQueue.main.async {
            // The DisplayMap may already contain loaded content when SwiftUI
            // creates this view, so there may be no revision transition to
            // trigger the initial cursor/focus setup.
            let firstResponder = editorView.window?.firstResponder
            let isAnotherControlFocused = firstResponder != nil && firstResponder !== editorView
            let shouldFocus = !isAnotherControlFocused
            editorView.resetCursorToFirstVisibleLine(shouldFocus: shouldFocus)
            if let path = selectedFilePath {
                context.coordinator.lastScrolledFilePaths[displayMapID] = path
                editorView.scrollToFilePath(path)
            }
            context.coordinator.saveCurrentViewState()
        }
        return editorView
    }

    public func updateNSView(_ editorView: CustomMultiBufferEditorView, context: Context) {
        context.coordinator.parent = self

        let displayMapID = ObjectIdentifier(displayMap)
        if let resetToken = viewStateResetToken,
           context.coordinator.lastViewStateResetTokens[displayMapID] != resetToken {
            context.coordinator.viewStates.removeValue(forKey: displayMapID)
            context.coordinator.lastScrolledFilePaths.removeValue(forKey: displayMapID)
            context.coordinator.lastViewStateResetTokens[displayMapID] = resetToken
            context.coordinator.lastScrolledMatchRequestId = nil
            editorView.scrollToTop()
        }
        let mapChanged = editorView.displayMap !== displayMap
        if mapChanged {
            // The state belongs to the map that was visible, not to the editor
            // view itself. Capture it before replacing the map reference.
            context.coordinator.saveCurrentViewState()
            // Assigning displayMap synchronously rebuilds layout. That rebuild
            // can clamp the old cursor and emit delegate callbacks before the
            // new map's snapshot has been restored, so those transient events
            // must not overwrite either map's saved UI state.
            context.coordinator.isSwitchingDisplayMap = true
            context.coordinator.activeDisplayMapID = displayMapID
            editorView.displayMap = displayMap
            context.coordinator.isSwitchingDisplayMap = false
        } else {
            editorView.syncLayoutIfNeeded()
        }

        let revisionChanged = context.coordinator.lastLoadRevisions[displayMapID] != displayMap.loadRevision
        if mapChanged || revisionChanged {
            context.coordinator.lastLoadRevisions[displayMapID] = displayMap.loadRevision
            let shouldKeepEditorFocus = editorView.window?.firstResponder === editorView
            // A map can be swapped in before its asynchronous load completes.
            // Do not overwrite an existing snapshot with an empty-map reset.
            if displayMap.displayLineCount > 0 {
                if let state = context.coordinator.viewStates[displayMapID] {
                    editorView.restoreViewState(state, shouldFocus: shouldKeepEditorFocus)
                } else {
                    editorView.resetCursorToFirstVisibleLine(shouldFocus: shouldKeepEditorFocus)
                }
                context.coordinator.saveCurrentViewState()
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

        if editorView.searchMatches != searchMatches {
            editorView.searchMatches = searchMatches
        }
        if editorView.activeMatchIndex != activeMatchIndex {
            editorView.activeMatchIndex = activeMatchIndex
        }

        if let scrollReq = searchMatchScrollRequest {
            if scrollReq.id != context.coordinator.lastScrolledMatchRequestId {
                context.coordinator.lastScrolledMatchRequestId = scrollReq.id
                DispatchQueue.main.async {
                    editorView.scrollToSearchMatch(at: scrollReq.matchIndex)
                    context.coordinator.saveCurrentViewState()
                }
            }
        } else {
            context.coordinator.lastScrolledMatchRequestId = nil
        }

        if !mapChanged, !revisionChanged,
           let path = selectedFilePath,
           path != context.coordinator.lastScrolledFilePaths[displayMapID] {
            context.coordinator.lastScrolledFilePaths[displayMapID] = path
            if editorView.window?.firstResponder !== editorView {
                DispatchQueue.main.async {
                    editorView.scrollToFilePath(path)
                    context.coordinator.saveCurrentViewState()
                }
            }
        }
    }

    public final class Coordinator: NSObject, CustomMultiBufferEditorDelegate {
        var parent: EditorHostView
        weak var editorView: CustomMultiBufferEditorView?
        var activeDisplayMapID: ObjectIdentifier?
        var isSwitchingDisplayMap = false
        var lastScrolledMatchRequestId: UInt64? = nil
        var viewStates: [ObjectIdentifier: EditorViewState] = [:]
        var lastScrolledFilePaths: [ObjectIdentifier: String] = [:]
        var lastLoadRevisions: [ObjectIdentifier: UInt64] = [:]
        var lastViewStateResetTokens: [ObjectIdentifier: UInt64] = [:]

        init(_ parent: EditorHostView) {
            self.parent = parent
        }

        public func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint) {
            guard !isSwitchingDisplayMap else { return }
            saveCurrentViewState()
            if let path = location?.filePath {
                if let mapID = activeDisplayMapID {
                    lastScrolledFilePaths[mapID] = path
                }
            }
            parent.onCursorChange(location, point)
        }

        public func editorDidRequestAddComment(filePath: String, lineNumber: Int) {
            parent.onAddCommentRequest(filePath, lineNumber)
        }

        public func editorDidScroll() {
            guard !isSwitchingDisplayMap else { return }
            saveCurrentViewState()
        }

        public func editorDidChangeContent() {
            guard !isSwitchingDisplayMap else { return }
            saveCurrentViewState()
            parent.onContentEdited?()
        }

        var currentViewState: EditorViewState? {
            guard let editorView else { return nil }
            return editorView.captureViewState()
        }

        func saveCurrentViewState() {
            guard let mapID = activeDisplayMapID,
                  let state = currentViewState else { return }
            viewStates[mapID] = state
            if let file = state.selectedFilePath {
                lastScrolledFilePaths[mapID] = file
            }
        }
    }
}
