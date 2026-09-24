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
    public var onCloseFileRequest: ((String) -> Void)?
    public var onOpenExternalIDERequest: ((String, Int?) -> Void)?
    public var onPreviewMarkdownRequest: ((String) -> Void)?

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
        onContentEdited: (() -> Void)? = nil,
        onCloseFileRequest: ((String) -> Void)? = nil,
        onOpenExternalIDERequest: ((String, Int?) -> Void)? = nil,
        onPreviewMarkdownRequest: ((String) -> Void)? = nil
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
        self.onCloseFileRequest = onCloseFileRequest
        self.onOpenExternalIDERequest = onOpenExternalIDERequest
        self.onPreviewMarkdownRequest = onPreviewMarkdownRequest
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
        context.coordinator.lastLayoutModes[displayMapID] = displayMap.effectiveLayoutMode
        context.coordinator.lastSelectedFilePaths[displayMapID] = selectedFilePath
        DispatchQueue.main.async {
            // The DisplayMap may already contain loaded content when SwiftUI
            // creates this view, so there may be no revision transition to
            // trigger the initial cursor/focus setup.
            let firstResponder = editorView.window?.firstResponder
            let isAnotherControlFocused = firstResponder != nil && firstResponder !== editorView
            let shouldFocus = !isAnotherControlFocused
            editorView.resetCursorToFirstVisibleLine(shouldFocus: shouldFocus)
            if let path = selectedFilePath {
                editorView.scrollToFilePath(path)
            }
            context.coordinator.saveCurrentViewState()
        }
        return editorView
    }

    public func updateNSView(_ editorView: CustomMultiBufferEditorView, context: Context) {
        updateView(editorView, coordinator: context.coordinator)
    }

    public func updateView(_ editorView: CustomMultiBufferEditorView, coordinator: Coordinator) {
        coordinator.parent = self

        let displayMapID = ObjectIdentifier(displayMap)
        if let resetToken = viewStateResetToken,
           coordinator.lastViewStateResetTokens[displayMapID] != resetToken {
            coordinator.viewStates.removeValue(forKey: displayMapID)
            coordinator.lastSelectedFilePaths.removeValue(forKey: displayMapID)
            coordinator.lastViewStateResetTokens[displayMapID] = resetToken
            coordinator.lastScrolledMatchRequestId = nil
            editorView.scrollToTop()
        }
        let mapChanged = editorView.displayMap !== displayMap
        let layoutModeChanged = coordinator.lastLayoutModes[displayMapID] != displayMap.effectiveLayoutMode
        if mapChanged {
            // The state belongs to the map that was visible, not to the editor
            // view itself. Capture it before replacing the map reference.
            coordinator.saveCurrentViewState()
            // Assigning displayMap synchronously rebuilds layout. That rebuild
            // can clamp the old cursor and emit delegate callbacks before the
            // new map's snapshot has been restored, so those transient events
            // must not overwrite either map's saved UI state.
            coordinator.isSwitchingDisplayMap = true
            coordinator.activeDisplayMapID = displayMapID
            editorView.displayMap = displayMap
            coordinator.isSwitchingDisplayMap = false
        } else if layoutModeChanged {
            // Layout mode changed on the same map. Suppress transient cursor
            // clamping from overwriting the saved view state during layout sync.
            coordinator.isSwitchingDisplayMap = true
            editorView.syncLayoutIfNeeded()
            coordinator.isSwitchingDisplayMap = false
        } else {
            editorView.syncLayoutIfNeeded()
        }

        let revisionChanged = coordinator.lastLoadRevisions[displayMapID] != displayMap.loadRevision
        if mapChanged || revisionChanged || layoutModeChanged {
            coordinator.lastLoadRevisions[displayMapID] = displayMap.loadRevision
            coordinator.lastLayoutModes[displayMapID] = displayMap.effectiveLayoutMode
            let shouldKeepEditorFocus = editorView.window?.firstResponder === editorView
            // A map can be swapped in before its asynchronous load completes.
            // Do not overwrite an existing snapshot with an empty-map reset.
            if displayMap.displayLineCount > 0 {
                if shouldKeepEditorFocus && !mapChanged && !layoutModeChanged {
                    // Editor is actively focused and user may be typing; do not clobber
                    // their active cursor or selection with a stale snapshot on background reload,
                    // but pin the scroll anchor so layout shifts above don't displace the viewport.
                    if let state = coordinator.viewStates[displayMapID] ?? coordinator.currentViewState {
                        editorView.restoreScrollAnchor(from: state)
                    }
                    coordinator.saveCurrentViewState()
                } else if let state = coordinator.viewStates[displayMapID] ?? (mapChanged ? nil : coordinator.currentViewState) {
                    editorView.restoreViewState(state, shouldFocus: shouldKeepEditorFocus)
                    coordinator.saveCurrentViewState()
                } else if let path = selectedFilePath, displayMap.displayLineIndex(forFilePath: path, lineNumber: nil) != nil {
                    editorView.scrollToFilePath(path)
                    coordinator.saveCurrentViewState()
                } else {
                    editorView.resetCursorToFirstVisibleLine(shouldFocus: shouldKeepEditorFocus)
                    coordinator.saveCurrentViewState()
                }
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
            if scrollReq.id != coordinator.lastScrolledMatchRequestId {
                coordinator.lastScrolledMatchRequestId = scrollReq.id
                DispatchQueue.main.async {
                    editorView.scrollToSearchMatch(at: scrollReq.matchIndex)
                    coordinator.saveCurrentViewState()
                }
            }
        } else {
            coordinator.lastScrolledMatchRequestId = nil
        }

        if let path = selectedFilePath {
            if !mapChanged, !revisionChanged,
               path != coordinator.lastSelectedFilePaths[displayMapID] {
                coordinator.lastSelectedFilePaths[displayMapID] = path
                if editorView.window?.firstResponder !== editorView {
                    DispatchQueue.main.async {
                        editorView.scrollToFilePath(path)
                        coordinator.saveCurrentViewState()
                    }
                }
            } else {
                coordinator.lastSelectedFilePaths[displayMapID] = path
            }
        } else {
            coordinator.lastSelectedFilePaths.removeValue(forKey: displayMapID)
        }
    }

    public final class Coordinator: NSObject, CustomMultiBufferEditorDelegate {
        var parent: EditorHostView
        weak var editorView: CustomMultiBufferEditorView?
        var activeDisplayMapID: ObjectIdentifier?
        var isSwitchingDisplayMap = false
        var lastScrolledMatchRequestId: UInt64? = nil
        var viewStates: [ObjectIdentifier: EditorViewState] = [:]
        var lastSelectedFilePaths: [ObjectIdentifier: String] = [:]
        var lastLoadRevisions: [ObjectIdentifier: UInt64] = [:]
        var lastLayoutModes: [ObjectIdentifier: DiffLayoutMode] = [:]
        var lastViewStateResetTokens: [ObjectIdentifier: UInt64] = [:]

        init(_ parent: EditorHostView) {
            self.parent = parent
        }

        public func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint) {
            guard !isSwitchingDisplayMap else { return }
            saveCurrentViewState()
            if let path = location?.filePath {
                if let mapID = activeDisplayMapID {
                    lastSelectedFilePaths[mapID] = path
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

        public func editorDidRequestCloseFile(filePath: String) {
            parent.onCloseFileRequest?(filePath)
        }

        public func editorDidRequestOpenExternalIDE(filePath: String, lineNumber: Int?) {
            parent.onOpenExternalIDERequest?(filePath, lineNumber)
        }

        public func editorDidRequestPreviewMarkdown(filePath: String) {
            parent.onPreviewMarkdownRequest?(filePath)
        }

        var currentViewState: EditorViewState? {
            guard let editorView else { return nil }
            return editorView.captureViewState()
        }

        func saveCurrentViewState() {
            guard let mapID = activeDisplayMapID,
                  let state = currentViewState else { return }
            viewStates[mapID] = state
        }
    }
}
