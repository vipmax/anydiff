import Foundation
import AppKit
import AnyDiffCore

extension MultiBufferEditorView {
    func showScrollbarsWithAutohide(for axis: ScrollAxis) {
        scrollbarFadeTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
        visibleScrollbarAxis = axis
        scrollbarAlpha = 1.0
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.startScrollbarFadeOut()
        }
        needsDisplay = true
    }

    public func resetCursorToFirstVisibleLine(shouldFocus: Bool = true) {
        guard let displayMap, let firstRow = displayMap.firstVisibleCodeRow else {
            selectionAnchor = nil
            cursorPoint = .zero
            if shouldFocus {
                focusAfterLoadIfPossible()
            }
            return
        }

        selectionAnchor = nil
        cursorPoint = MultiBufferPoint(row: firstRow, column: 0)
        scrollOffsetY = 0
        scrollOffsetX = 0
        if shouldFocus {
            focusAfterLoadIfPossible()
        }
    }

    /// Captures the active cursor position, source line numbers, and top visible line scroll anchor
    public func captureViewState() -> EditorViewState {
        guard let dm = displayMap else {
            return EditorViewState(cursorAnchor: nil, scrollAnchor: nil, scrollOffsetX: scrollOffsetX, selectedFilePath: nil)
        }

        // 1. Capture Cursor and Selection Anchors
        let cursorAnchor = editorCursorAnchor(for: cursorPoint, in: dm)
        let selectionState: EditorCursorAnchor?
        if let selectionAnchor, selectionAnchor != cursorPoint {
            selectionState = editorCursorAnchor(for: selectionAnchor, in: dm)
        } else {
            selectionState = nil
        }

        // 2. Capture Scroll Anchor (top visible line on screen)
        var scrollAnchor: EditorScrollAnchor? = nil
        let topLineIdx = lineIndex(atY: scrollOffsetY)
        if topLineIdx >= 0 && topLineIdx < dm.displayLineCount {
            let lineY = yOffset(forDisplayLineIndex: topLineIdx)
            let pixelOffset = scrollOffsetY - lineY
            if let fastAnchor = dm.fastScrollAnchor(forDisplayLineIndex: topLineIdx) {
                scrollAnchor = EditorScrollAnchor(
                    filePath: fastAnchor.filePath,
                    lineNumber: fastAnchor.lineNumber,
                    isHeader: fastAnchor.isHeader,
                    pixelOffsetInLine: pixelOffset,
                    isOldSide: fastAnchor.isOldSide
                )
            }
        }

        let currentFile = scrollAnchor?.filePath ?? cursorAnchor?.filePath
        return EditorViewState(
            cursorAnchor: cursorAnchor,
            selectionAnchor: selectionState,
            scrollAnchor: scrollAnchor,
            scrollOffsetX: scrollOffsetX,
            selectedFilePath: currentFile
        )
    }

    func editorCursorAnchor(for point: MultiBufferPoint, in dm: DisplayMap) -> EditorCursorAnchor? {
        if dm.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left,
           let split = dm.splitCodeInfo(for: point.row),
           let oldLine = split.left.lineNumber {
            let excerpt = dm.multiBuffer.excerpts[split.excerptIndex]
            return EditorCursorAnchor(filePath: excerpt.filePath, lineNumber: oldLine, column: point.column, isOldSide: true)
        }
        guard let loc = dm.fastSourceLocation(forCodeRow: point.row) else {
            return nil
        }
        let isDel = dm.isDeleted(multiBufferRow: point.row)
        return EditorCursorAnchor(
            filePath: loc.filePath,
            lineNumber: loc.lineNumber,
            column: point.column,
            isOldSide: isDel
        )
    }

    /// Restores the editor's cursor and viewport anchor across diff reloads
    public func restoreViewState(_ state: EditorViewState, shouldFocus: Bool = true) {
        invalidateLayout()
        syncLayoutIfNeeded()

        guard let dm = displayMap, dm.displayLineCount > 0 else {
            resetCursorToFirstVisibleLine(shouldFocus: shouldFocus)
            return
        }

        // 1. Restore Cursor Anchor
        var restoredCursor = false
        if let cAnchor = state.cursorAnchor,
           let mbRow = dm.codeRow(forFilePath: cAnchor.filePath, lineNumber: cAnchor.lineNumber, isOldSide: cAnchor.isOldSide) {
            if dm.effectiveLayoutMode == .sideBySide {
                if let split = dm.splitCodeInfo(for: mbRow) {
                    if split.right.isSpacer {
                        splitActiveColumn = .left
                    } else if split.left.isSpacer {
                        splitActiveColumn = .right
                    } else {
                        splitActiveColumn = cAnchor.isOldSide ? .left : .right
                    }
                } else {
                    splitActiveColumn = cAnchor.isOldSide ? .left : .right
                }
            }
            let maxCol = activeLineLength(at: mbRow)
            let clampedCol = max(0, min(maxCol, cAnchor.column))
            let restoredCursorPoint = MultiBufferPoint(row: mbRow, column: clampedCol)

            var restoredAnchor: MultiBufferPoint? = nil
            if let sAnchor = state.selectionAnchor,
               let selectionRow = dm.codeRow(forFilePath: sAnchor.filePath, lineNumber: sAnchor.lineNumber, isOldSide: sAnchor.isOldSide) {
                let selectionMaxCol = activeLineLength(at: selectionRow)
                let candidateAnchor = MultiBufferPoint(
                    row: selectionRow,
                    column: max(0, min(selectionMaxCol, sAnchor.column))
                )
                if candidateAnchor != restoredCursorPoint {
                    restoredAnchor = candidateAnchor
                }
            }

            self.selectionAnchor = restoredAnchor
            self.cursorPoint = restoredCursorPoint
            restoredCursor = true
        }

        // 2. Restore Scroll Position using Scroll Anchor (keeps viewport pinned)
        var restoredScroll = false
        if let sAnchor = state.scrollAnchor,
           let targetLineIdx = dm.displayLineIndex(
                forFilePath: sAnchor.filePath,
                lineNumber: sAnchor.lineNumber,
                isHeader: sAnchor.isHeader,
                isOldSide: sAnchor.isOldSide
           ) {
            let targetY = yOffset(forDisplayLineIndex: targetLineIdx)
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            self.scrollOffsetY = max(0, min(maxScrollY, targetY + sAnchor.pixelOffsetInLine))
            self.scrollOffsetX = max(0, state.scrollOffsetX)
            restoredScroll = true
        }

        if !restoredScroll {
            if let sAnchor = state.scrollAnchor,
               let targetLineIdx = dm.displayLineIndex(forFilePath: sAnchor.filePath, lineNumber: nil, isHeader: true) {
                let targetY = yOffset(forDisplayLineIndex: targetLineIdx)
                let maxScrollY = max(0, totalDocumentHeight - bounds.height)
                self.scrollOffsetY = max(0, min(maxScrollY, targetY))
                restoredScroll = true
            } else if let path = state.selectedFilePath,
               let targetLineIdx = dm.displayLineIndex(forFilePath: path, lineNumber: nil, isHeader: true) {
                let targetY = yOffset(forDisplayLineIndex: targetLineIdx)
                let maxScrollY = max(0, totalDocumentHeight - bounds.height)
                self.scrollOffsetY = max(0, min(maxScrollY, targetY))
                restoredScroll = true
            } else {
                // The anchored file may have disappeared (for example after
                // a commit/checkout/delete). Keep the viewport within valid bounds
                // at the current position instead of jumping to 0.
                let maxScrollY = max(0, totalDocumentHeight - bounds.height)
                self.scrollOffsetY = max(0, min(maxScrollY, self.scrollOffsetY))
                if !restoredCursor {
                    resetCursorToFirstVisibleLine(shouldFocus: shouldFocus)
                }
            }
        }

        // Restore horizontal position even when the vertical anchor is no longer
        // available and we had to fall back to the selected file or first line.
        self.scrollOffsetX = max(0, state.scrollOffsetX)

        if restoredCursor && !restoredScroll {
            ensureCursorVisible()
        }

        needsDisplay = true
        if shouldFocus {
            focusAfterLoadIfPossible()
        }
        let loc = dm.excerptLocation(for: cursorPoint)
        delegate?.editorDidChangeCursor(location: loc, point: cursorPoint)
        delegate?.editorDidScroll()
    }

    /// Restores only the scroll viewport anchor across diff reloads without mutating active cursor or selection
    public func restoreScrollAnchor(from state: EditorViewState) {
        invalidateLayout()
        syncLayoutIfNeeded()

        guard let dm = displayMap, dm.displayLineCount > 0 else { return }

        if let sAnchor = state.scrollAnchor,
           let targetLineIdx = dm.displayLineIndex(
                forFilePath: sAnchor.filePath,
                lineNumber: sAnchor.lineNumber,
                isHeader: sAnchor.isHeader,
                isOldSide: sAnchor.isOldSide
           ) {
            let targetY = yOffset(forDisplayLineIndex: targetLineIdx)
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            self.scrollOffsetY = max(0, min(maxScrollY, targetY + sAnchor.pixelOffsetInLine))
        } else if let sAnchor = state.scrollAnchor,
                  let targetLineIdx = dm.displayLineIndex(forFilePath: sAnchor.filePath, lineNumber: nil, isHeader: true) {
            let targetY = yOffset(forDisplayLineIndex: targetLineIdx)
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            self.scrollOffsetY = max(0, min(maxScrollY, targetY))
        } else {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            self.scrollOffsetY = max(0, min(maxScrollY, self.scrollOffsetY))
        }

        self.scrollOffsetX = max(0, state.scrollOffsetX)
        needsDisplay = true
        delegate?.editorDidScroll()
    }

    public func focus() {
        if let window {
            window.makeFirstResponder(self)
            resetCursorBlink()
            needsDisplay = true
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
                self.resetCursorBlink()
                self.needsDisplay = true
            }
        }
    }

    func focusAfterLoadIfPossible() {
        focus()
    }

    func startScrollbarFadeOut() {
        guard scrollbarDragAxis == nil else { return }
        fadeAnimationTimer?.invalidate()
        fadeAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.scrollbarAlpha -= 0.12
            if self.scrollbarAlpha <= 0 {
                self.scrollbarAlpha = 0
                timer.invalidate()
            }
            self.needsDisplay = true
        }
    }

    func verticalScrollbarGeometry() -> (thumb: CGRect, hit: CGRect)? {
        guard totalDocumentHeight > bounds.height, bounds.height > 0 else { return nil }

        let maxScrollY = totalDocumentHeight - bounds.height
        let thumbHeight = min(bounds.height, max(30, (bounds.height / totalDocumentHeight) * bounds.height))
        let travel = max(0, bounds.height - thumbHeight)
        let progress = maxScrollY > 0 ? scrollOffsetY / maxScrollY : 0
        let thumbY = progress * travel
        let thumb = CGRect(x: bounds.width - 9, y: thumbY, width: 6, height: thumbHeight)
        let hit = thumb.insetBy(dx: -6, dy: -2).intersection(bounds)
        return (thumb, hit)
    }

    func horizontalScrollbarGeometry() -> (thumb: CGRect, hit: CGRect)? {
        let leftMargin = (displayMap?.effectiveLayoutMode == .sideBySide) ? 0 : gutterWidth
        let trackWidth = bounds.width - leftMargin - 10
        guard totalDocumentWidth > bounds.width, trackWidth > 0, bounds.height > 0 else { return nil }

        let maxScrollX = totalDocumentWidth - bounds.width
        let thumbWidth = min(trackWidth, max(40, (trackWidth / totalDocumentWidth) * trackWidth))
        let travel = max(0, trackWidth - thumbWidth)
        let progress = maxScrollX > 0 ? scrollOffsetX / maxScrollX : 0
        let thumbX = leftMargin + progress * travel
        let thumb = CGRect(x: thumbX, y: bounds.height - 8, width: thumbWidth, height: 6)
        let hit = thumb.insetBy(dx: -2, dy: -6).intersection(bounds)
        return (thumb, hit)
    }

    @discardableResult
    func beginScrollbarDrag(at point: CGPoint) -> Bool {
        if visibleScrollbarAxis == .vertical,
           let geometry = verticalScrollbarGeometry(), geometry.hit.contains(point) {
            scrollbarDragAxis = .vertical
            scrollbarDragStartMousePosition = point.y
            scrollbarDragStartOffset = scrollOffsetY
            showScrollbarsWithAutohide(for: .vertical)
            return true
        }

        if visibleScrollbarAxis == .horizontal,
           let geometry = horizontalScrollbarGeometry(), geometry.hit.contains(point) {
            scrollbarDragAxis = .horizontal
            scrollbarDragStartMousePosition = point.x
            scrollbarDragStartOffset = scrollOffsetX
            showScrollbarsWithAutohide(for: .horizontal)
            return true
        }

        return false
    }

    func updateScrollbarDrag(at point: CGPoint) {
        guard let axis = scrollbarDragAxis else { return }

        switch axis {
        case .vertical:
            guard let geometry = verticalScrollbarGeometry() else { return }
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            let travel = max(0, bounds.height - geometry.thumb.height)
            guard travel > 0 else { return }
            let delta = point.y - scrollbarDragStartMousePosition
            scrollOffsetY = max(0, min(maxScrollY, scrollbarDragStartOffset + delta * maxScrollY / travel))
            showScrollbarsWithAutohide(for: .vertical)

        case .horizontal:
            guard let geometry = horizontalScrollbarGeometry() else { return }
            let maxScrollX = max(0, totalDocumentWidth - bounds.width)
            let leftMargin = (displayMap?.effectiveLayoutMode == .sideBySide) ? 0 : gutterWidth
            let trackWidth = max(0, bounds.width - leftMargin - 10)
            let travel = max(0, trackWidth - geometry.thumb.width)
            guard travel > 0 else { return }
            let delta = point.x - scrollbarDragStartMousePosition
            scrollOffsetX = max(0, min(maxScrollX, scrollbarDragStartOffset + delta * maxScrollX / travel))
            showScrollbarsWithAutohide(for: .horizontal)
        }

        needsDisplay = true
    }

    public override func scrollWheel(with event: NSEvent) {
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 24.0
        var dy = event.scrollingDeltaY * mult
        var dx = event.scrollingDeltaX * mult

        let now = Date()
        let timeSinceLastEvent = now.timeIntervalSince(lastScrollEventTime)
        lastScrollEventTime = now

        let isNewGesture = event.phase == .began || event.phase == .mayBegin || timeSinceLastEvent > 0.35
        let absX = abs(dx)
        let absY = abs(dy)

        if isNewGesture || scrollLockAxis == nil {
            // Determine dominant direction at start of gesture
            if absY >= absX {
                scrollLockAxis = .vertical
            } else {
                scrollLockAxis = .horizontal
            }
        }

        // Keep one axis for the complete gesture. The nil guard above also
        // covers momentum events arriving immediately after .ended.
        switch scrollLockAxis {
        case .vertical:
            dx = 0
        case .horizontal:
            dy = 0
        case .none:
            break
        }

        let scrollbarAxis = scrollLockAxis ?? .vertical

        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        let maxScrollX = max(0, totalDocumentWidth - bounds.width)

        scrollOffsetY = max(0, min(maxScrollY, scrollOffsetY - dy))
        scrollOffsetX = max(0, min(maxScrollX, scrollOffsetX - dx))

        showScrollbarsWithAutohide(for: scrollbarAxis)

        if let win = window {
            let currentMouse = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(currentMouse) {
                updateCloseHoverState(at: currentMouse)
            } else if hoveredCloseFilePath != nil {
                hoveredCloseFilePath = nil
                needsDisplay = true
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollLockAxis = nil
        }
    }


    // MARK: - Navigation & File Scrolling

    public func scrollToFilePath(_ filePath: String) {
        let targetLast = (filePath as NSString).lastPathComponent
        if let targetY = filePathToY[filePath] ?? filePathToY[targetLast] {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            scrollOffsetY = max(0, min(maxScrollY, targetY))
            scrollOffsetX = 0
            showScrollbarsWithAutohide(for: .vertical)
            needsDisplay = true
        }
    }

    public func scrollToTop() {
        scrollOffsetY = 0
        scrollOffsetX = 0
        showScrollbarsWithAutohide(for: .vertical)
        needsDisplay = true
    }

    public func scrollToSearchMatch(at index: Int) {
        guard index >= 0, index < searchMatches.count else { return }
        let match = searchMatches[index]
        self.activeMatchIndex = index

        guard let displayMap = displayMap else {
            needsDisplay = true
            return
        }

        let mbRow = displayMap.codeRow(forFilePath: match.filePath, lineNumber: match.lineNumber) ?? match.multiBufferRow
        guard let row = mbRow else {
            needsDisplay = true
            return
        }

        if let displayLineIdx = displayMap.displayLineIndex(forMultiBufferRow: row) {
            let targetY = CGFloat(displayLineIdx) * lineHeight
            let viewportHeight = bounds.height
            let centeredY = max(0, targetY - (viewportHeight / 2) + (lineHeight / 2))
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            scrollOffsetY = min(maxScrollY, centeredY)
            showScrollbarsWithAutohide(for: .vertical)
        }
        needsDisplay = true
    }

    @discardableResult
    public func navigateTo(filePath: String, lineNumber: Int? = nil, endLineNumber: Int? = nil, shouldFocus: Bool = true) -> Bool {
        syncLayoutIfNeeded()
        guard let dm = displayMap, let targetFile = dm.matchFilePath(filePath) else {
            return false
        }

        if let line = lineNumber {
            if let row = dm.codeRow(forFilePath: targetFile, lineNumber: line) {
                if let endLine = endLineNumber, endLine > line,
                   let endRow = dm.codeRow(forFilePath: targetFile, lineNumber: endLine) {
                    let endCol = dm.lineLength(at: endRow)
                    selectionAnchor = MultiBufferPoint(row: row, column: 0)
                    cursorPoint = MultiBufferPoint(row: endRow, column: endCol)
                } else {
                    selectionAnchor = nil
                    cursorPoint = MultiBufferPoint(row: row, column: 0)
                }

                if let displayLineIdx = dm.displayLineIndex(forMultiBufferRow: row) {
                    let targetY = CGFloat(displayLineIdx) * lineHeight
                    let viewportHeight = bounds.height
                    let centeredY = max(0, targetY - (viewportHeight / 2) + (lineHeight / 2))
                    let maxScrollY = max(0, totalDocumentHeight - bounds.height)
                    scrollOffsetY = min(maxScrollY, centeredY)
                    showScrollbarsWithAutohide(for: .vertical)
                }
                if shouldFocus {
                    focus()
                }
                needsDisplay = true
                return true
            }
        }

        scrollToFilePath(targetFile)
        if shouldFocus {
            focus()
        }
        return true
    }

    @objc func handleFocusFileNotification(_ notification: Notification) {
        if let request = notification.object as? FileNavigationRequest {
            _ = navigateTo(filePath: request.filePath, lineNumber: request.lineNumber, endLineNumber: request.endLineNumber, shouldFocus: true)
        } else if let path = notification.object as? String {
            scrollToFilePath(path)
            focus()
        }
    }

    // MARK: - Hunk Navigation

    @objc public func goToNextHunk(_ sender: Any? = nil) {
        guard let dm = displayMap, !dm.multiBuffer.excerpts.isEmpty else { return }
        let total = dm.multiBuffer.excerpts.count
        guard total > 0 else { return }

        let currentIdx = currentHunkIndex()
        let nextIdx = (currentIdx + 1) % total
        navigateToHunk(at: nextIdx)
    }

    @objc public func goToPreviousHunk(_ sender: Any? = nil) {
        guard let dm = displayMap, !dm.multiBuffer.excerpts.isEmpty else { return }
        let total = dm.multiBuffer.excerpts.count
        guard total > 0 else { return }

        let currentIdx = currentHunkIndex()
        let prevIdx = (currentIdx - 1 + total) % total
        navigateToHunk(at: prevIdx)
    }

    @objc func handleGoToNextHunkNotification(_ notification: Notification) {
        goToNextHunk()
    }

    @objc func handleGoToPreviousHunkNotification(_ notification: Notification) {
        goToPreviousHunk()
    }

    func currentHunkIndex() -> Int {
        guard let dm = displayMap, !dm.multiBuffer.excerpts.isEmpty else { return 0 }

        // 1. If cursor is on screen, use cursor's excerpt
        if let cy = yOffset(for: cursorPoint.row),
           cy >= scrollOffsetY && cy <= scrollOffsetY + bounds.height {
            if let idx = dm.excerptIndex(forCodeRow: cursorPoint.row) {
                return idx
            }
        }

        // 2. Otherwise, use visible line near top of viewport
        let visibleLine = lineIndex(atY: scrollOffsetY + 40)
        if let idx = dm.excerptIndex(forDisplayLineIndex: visibleLine) {
            return idx
        }

        return 0
    }

    public func navigateToHunk(at targetIdx: Int) {
        guard let dm = displayMap, targetIdx >= 0, targetIdx < dm.multiBuffer.excerpts.count else { return }

        // 1. If the file/excerpt is collapsed, expand it!
        let excerpt = dm.multiBuffer.excerpts[targetIdx]
        if excerpt.isCollapsed {
            dm.multiBuffer.expand(filePath: excerpt.filePath)
            dm.rebuild()
            invalidateLayout()
        }

        // 2. Find target MultiBuffer row and display line in target hunk
        guard targetIdx < dm.excerptLocations.count else { return }
        let loc = dm.excerptLocations[targetIdx]

        var targetMBRow: Int? = nil
        var targetDisplayIdx: Int = loc.displayRange.lowerBound

        // Search for the first addition/deletion line in this excerpt
        for dispIdx in loc.displayRange {
            guard let line = dm.displayLine(at: dispIdx) else { continue }
            switch line {
            case .code(let info):
                if targetMBRow == nil {
                    targetMBRow = info.multiBufferRow
                    targetDisplayIdx = dispIdx
                }
                if info.diffKind == .added || info.diffKind == .deleted {
                    targetMBRow = info.multiBufferRow
                    targetDisplayIdx = dispIdx
                    break
                }
            case .splitCode(let split):
                if targetMBRow == nil {
                    targetMBRow = split.right.multiBufferRow ?? split.left.multiBufferRow
                    targetDisplayIdx = dispIdx
                }
                if split.left.diffKind == .deleted || split.right.diffKind == .added {
                    targetMBRow = split.right.multiBufferRow ?? split.left.multiBufferRow
                    targetDisplayIdx = dispIdx
                    break
                }
            default:
                break
            }
            if targetMBRow != nil && targetDisplayIdx == dispIdx {
                if case .code(let info) = line, info.diffKind == .added || info.diffKind == .deleted {
                    break
                }
                if case .splitCode(let split) = line, split.left.diffKind == .deleted || split.right.diffKind == .added {
                    break
                }
            }
        }

        let finalRow = targetMBRow ?? loc.codeRange.lowerBound
        self.cursorPoint = MultiBufferPoint(row: finalRow, column: 0)
        self.selectionAnchor = nil

        // 3. Scroll viewport so the target hunk is framed nicely (~28% down from viewport top)
        let targetY = CGFloat(targetDisplayIdx) * lineHeight
        let viewportHeight = bounds.height
        let idealScrollY = max(0, targetY - (viewportHeight * 0.28))
        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        scrollOffsetY = max(0, min(maxScrollY, idealScrollY))
        scrollOffsetX = 0
        showScrollbarsWithAutohide(for: .vertical)

        // 4. Focus editor and update cursor blink
        focus()
        resetCursorBlink()
        needsDisplay = true

        // 5. Notify delegate to update sidebar selected file
        let locForCursor = dm.excerptLocation(for: cursorPoint)
        delegate?.editorDidChangeCursor(location: locForCursor, point: cursorPoint)
    }


    // MARK: - Pixel-Perfect Viewport Scroll Anchoring

    func preserveScreenPosition(ofAnchor anchor: ScrollAnchor?, originalScreenY: CGFloat) {
        guard let dm = displayMap else { return }
        dm.rebuild()
        invalidateLayout()

        guard let anchor = anchor else {
            needsDisplay = true
            return
        }

        let newAbsY: CGFloat?
        switch anchor {
        case .header(let path):
            newAbsY = filePathToY[path] ?? filePathToY[(path as NSString).lastPathComponent]
        case .line(let path, let lineNum):
            if let targetLineIdx = dm.displayLineIndex(forFilePath: path, lineNumber: lineNum, isHeader: false) {
                newAbsY = yOffset(forDisplayLineIndex: targetLineIdx)
            } else {
                newAbsY = nil
            }
        }

        if let absY = newAbsY {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            let targetScrollY = absY - originalScreenY
            scrollOffsetY = max(0, min(maxScrollY, targetScrollY))
        }
        needsDisplay = true
    }

    func preserveCursorAndSelection(around action: () -> Void) {
        guard let dm = displayMap else {
            action()
            return
        }

        struct CursorState {
            let filePath: String
            let lineNumber: Int
            let column: Int
        }

        let cursorState: CursorState?
        if let cInfo = dm.codeInfo(for: cursorPoint.row),
           cInfo.excerptIndex >= 0 && cInfo.excerptIndex < dm.multiBuffer.excerpts.count {
            let exc = dm.multiBuffer.excerpts[cInfo.excerptIndex]
            let lineNum = cInfo.newLineNumber ?? cInfo.oldLineNumber ?? ((dm.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + cInfo.bufferRow)
            cursorState = CursorState(filePath: exc.filePath, lineNumber: lineNum, column: cursorPoint.column)
        } else {
            cursorState = nil
        }

        let anchorState: CursorState?
        let hadSelection = (selectionAnchor != nil && selectionAnchor != cursorPoint)
        if hadSelection,
           let aPoint = selectionAnchor,
           let aInfo = dm.codeInfo(for: aPoint.row),
           aInfo.excerptIndex >= 0 && aInfo.excerptIndex < dm.multiBuffer.excerpts.count {
            let exc = dm.multiBuffer.excerpts[aInfo.excerptIndex]
            let lineNum = aInfo.newLineNumber ?? aInfo.oldLineNumber ?? ((dm.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + aInfo.bufferRow)
            anchorState = CursorState(filePath: exc.filePath, lineNumber: lineNum, column: aPoint.column)
        } else {
            anchorState = nil
        }

        action()

        dm.rebuild()
        invalidateLayout()

        if let cs = cursorState, let newRow = dm.codeRow(forFilePath: cs.filePath, lineNumber: cs.lineNumber) {
            let maxCol = dm.lineLength(at: newRow)
            let newCursorPoint = MultiBufferPoint(row: newRow, column: min(maxCol, cs.column))

            var newAnchor: MultiBufferPoint? = nil
            if let asState = anchorState, let newAnchorRow = dm.codeRow(forFilePath: asState.filePath, lineNumber: asState.lineNumber) {
                let aMaxCol = dm.lineLength(at: newAnchorRow)
                let candidate = MultiBufferPoint(row: newAnchorRow, column: min(aMaxCol, asState.column))
                if candidate != newCursorPoint {
                    newAnchor = candidate
                }
            }
            selectionAnchor = newAnchor
            cursorPoint = newCursorPoint
        }
    }
}
