import Foundation
import AppKit
import CoreText
import AnyDiffCore

extension MultiBufferEditorView {
    // MARK: - Mouse Event Handling

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDraggingSelection = false
        let screenPoint = convert(event.locationInWindow, from: nil)

        // Scrollbars are painted by this view, so handle their hit-testing
        // before the normal document/selection hit-testing.
        if beginScrollbarDrag(at: screenPoint) {
            return
        }

        // Side-by-side divider dragging & double-click reset
        if displayMap?.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: 0, height: bounds.height)
            let dividerHitRect = CGRect(x: geom.dividerRect.midX - 5, y: 0, width: 10, height: bounds.height)
            if dividerHitRect.contains(screenPoint) {
                if event.clickCount == 2 {
                    splitRatio = 0.5
                    return
                }
                isDraggingDivider = true
                NSCursor.resizeLeftRight.push()
                needsDisplay = true
                return
            }
        }

        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        let isShift = event.modifierFlags.contains(.shift)
        guard let displayMap = displayMap else { return }

        // 1. Check if user clicked on Sticky Excerpt Header
        if let (stickyInfo, stickyFrame) = currentStickyHeader(), stickyFrame.contains(screenPoint) {
            let isMd = stickyInfo.filePath.hasSuffix(".md") || stickyInfo.filePath.hasSuffix(".markdown") || stickyInfo.filePath.hasSuffix(".mdx")
            if isMd && previewButtonRect(in: stickyFrame, for: stickyInfo).contains(screenPoint) {
                delegate?.editorDidRequestPreviewMarkdown(filePath: stickyInfo.filePath)
                return
            }
            let closeRect = closeButtonRect(in: stickyFrame)
            if closeRect.contains(screenPoint) {
                delegate?.editorDidRequestCloseFile(filePath: stickyInfo.filePath)
                return
            }
            if event.modifierFlags.contains(.option) {
                delegate?.editorDidRequestOpenExternalIDE(filePath: stickyInfo.filePath, lineNumber: nil)
                return
            }
            displayMap.multiBuffer.toggleCollapse(filePath: stickyInfo.filePath)
            displayMap.rebuild()
            invalidateLayout()
            return
        }

        // 2. Search through visible display lines using O(log N) line index
        let totalLines = displayMap.displayLineCount
        guard totalLines > 0 else { return }

        let lineIdx = lineIndex(atY: docY)
        guard let line = displayMap.displayLine(at: lineIdx) else { return }
        let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
        let height = lineHeight(forDisplayLineIndex: lineIdx)
        let lineMaxY = lineMinY + height

        if docY >= lineMinY && docY <= lineMaxY {
            switch line {
            case .excerptHeader(let header):
                let headerRect = CGRect(x: 0, y: lineMinY, width: bounds.width, height: height)
                let isMd = header.filePath.hasSuffix(".md") || header.filePath.hasSuffix(".markdown") || header.filePath.hasSuffix(".mdx")
                let clickPoint = CGPoint(x: screenPoint.x, y: docY)
                if isMd && previewButtonRect(in: headerRect, for: header).contains(clickPoint) {
                    delegate?.editorDidRequestPreviewMarkdown(filePath: header.filePath)
                    return
                }
                let closeRect = closeButtonRect(in: headerRect)
                if closeRect.contains(clickPoint) {
                    delegate?.editorDidRequestCloseFile(filePath: header.filePath)
                    return
                }
                if event.modifierFlags.contains(.option) {
                    delegate?.editorDidRequestOpenExternalIDE(filePath: header.filePath, lineNumber: nil)
                    return
                }
                displayMap.multiBuffer.toggleCollapse(filePath: header.filePath)
                displayMap.rebuild()
                invalidateLayout()
                return
            case .foldGap(let gap):
                selectionAnchor = cursorPoint
                var anchor: ScrollAnchor? = nil
                var anchorScreenY: CGFloat = 0

                if gap.isTopGap {
                    if lineIdx + 1 < totalLines, let nextLine = displayMap.displayLine(at: lineIdx + 1) {
                        if case .code(let c) = nextLine {
                            if c.excerptIndex >= 0 && c.excerptIndex < displayMap.multiBuffer.excerpts.count {
                                let exc = displayMap.multiBuffer.excerpts[c.excerptIndex]
                                let lineNum = c.newLineNumber ?? c.oldLineNumber ?? ((displayMap.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + c.bufferRow)
                                anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                            }
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx + 1) - scrollOffsetY
                        } else if case .splitCode(let sc) = nextLine {
                            if sc.excerptIndex >= 0 && sc.excerptIndex < displayMap.multiBuffer.excerpts.count {
                                let exc = displayMap.multiBuffer.excerpts[sc.excerptIndex]
                                let lineNum = sc.right.lineNumber ?? sc.left.lineNumber ?? 1
                                anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                            }
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx + 1) - scrollOffsetY
                        }
                    }
                } else {
                    if lineIdx > 0, let prevLine = displayMap.displayLine(at: lineIdx - 1) {
                        switch prevLine {
                        case .excerptHeader(let h):
                            anchor = .header(filePath: h.filePath)
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx - 1) - scrollOffsetY
                        case .code(let c):
                            if c.excerptIndex >= 0 && c.excerptIndex < displayMap.multiBuffer.excerpts.count {
                                let exc = displayMap.multiBuffer.excerpts[c.excerptIndex]
                                let lineNum = c.newLineNumber ?? c.oldLineNumber ?? ((displayMap.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + c.bufferRow)
                                anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                            }
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx - 1) - scrollOffsetY
                        case .splitCode(let sc):
                            if sc.excerptIndex >= 0 && sc.excerptIndex < displayMap.multiBuffer.excerpts.count {
                                let exc = displayMap.multiBuffer.excerpts[sc.excerptIndex]
                                let lineNum = sc.right.lineNumber ?? sc.left.lineNumber ?? 1
                                anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                            }
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx - 1) - scrollOffsetY
                        default:
                            break
                        }
                    }
                }

                preserveCursorAndSelection {
                    let expansionCount = gap.isCountKnown ? gap.hiddenCount : 5
                    if gap.isTopGap {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: expansionCount, down: 0)
                    } else if gap.isBottomGap {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: expansionCount)
                    } else if let _ = gap.nextExcerptIndex {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: expansionCount)
                        displayMap.multiBuffer.mergeAdjacentExcerpts()
                    } else {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: expansionCount)
                    }
                }

                preserveScreenPosition(ofAnchor: anchor, originalScreenY: anchorScreenY)
                return
            case .code(let codeInfo):
                if screenPoint.x <= 28, let exp = codeInfo.expandInfo {
                    let isFullExpand = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
                    let lineScreenY = lineMinY - scrollOffsetY
                    selectionAnchor = cursorPoint
                    var anchor: ScrollAnchor? = nil
                    if codeInfo.excerptIndex >= 0 && codeInfo.excerptIndex < displayMap.multiBuffer.excerpts.count {
                        let exc = displayMap.multiBuffer.excerpts[codeInfo.excerptIndex]
                        let lineNum = codeInfo.newLineNumber ?? codeInfo.oldLineNumber ?? ((displayMap.multiBuffer.buffer(for: exc.bufferId)?.startLineNumber ?? 1) + codeInfo.bufferRow)
                        anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                    }
                    preserveCursorAndSelection {
                        if isFullExpand {
                            displayMap.multiBuffer.expandExcerptAll(at: exp.excerptIndex)
                        } else {
                            switch exp.direction {
                            case .up:
                                displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 5, down: 0)
                            case .down:
                                displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 0, down: 5)
                            case .upAndDown:
                                let relY = screenPoint.y - lineScreenY
                                if relY < height / 2 {
                                    displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 5, down: 0)
                                } else {
                                    displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 0, down: 5)
                                }
                            }
                        }
                    }
                    preserveScreenPosition(ofAnchor: anchor, originalScreenY: lineScreenY)
                    return
                } else if screenPoint.x < gutterWidth {
                    isDraggingSelection = true
                    let targetPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: 0)
                    activeSelectionGranularity = .character
                    selectionAnchor = nil
                    cursorPoint = targetPoint
                    needsDisplay = true
                    return
                } else {
                    // Position cursor in code
                    isDraggingSelection = true
                    let text = codeInfo.text
                    let ctLine = getOrCreateCTLine(for: lineIdx, text: text, language: codeInfo.language)
                    let xOffset = max(0, docX - (gutterWidth + Self.codeLeftPadding))
                    let col = ctLine.characterIndex(at: xOffset, in: text)
                    let targetPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: col)

                    if event.clickCount == 2 {
                        let (wordStart, wordEnd) = wordRange(in: text, at: col)
                        activeSelectionGranularity = .word(initialStart: wordStart, initialEnd: wordEnd, initialRow: codeInfo.multiBufferRow)
                        selectionAnchor = MultiBufferPoint(row: codeInfo.multiBufferRow, column: wordStart)
                        cursorPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: wordEnd)
                    } else if event.clickCount >= 3 {
                        activeSelectionGranularity = .line(initialRow: codeInfo.multiBufferRow)
                        selectionAnchor = MultiBufferPoint(row: codeInfo.multiBufferRow, column: 0)
                        cursorPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: text.count)
                    } else {
                        activeSelectionGranularity = .character
                        if isShift {
                            if selectionAnchor == nil {
                                selectionAnchor = cursorPoint
                            }
                        } else {
                            selectionAnchor = nil
                        }
                        cursorPoint = targetPoint
                    }
                    needsDisplay = true
                    return
                }
            case .splitCode(let splitInfo):
                let geom = splitGeometry(atY: lineMinY - scrollOffsetY, height: height)
                if screenPoint.x <= 28, let exp = splitInfo.expandInfo {
                    let isFullExpand = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
                    let lineScreenY = lineMinY - scrollOffsetY
                    selectionAnchor = cursorPoint
                    var anchor: ScrollAnchor? = nil
                    if splitInfo.excerptIndex >= 0 && splitInfo.excerptIndex < displayMap.multiBuffer.excerpts.count {
                        let exc = displayMap.multiBuffer.excerpts[splitInfo.excerptIndex]
                        let lineNum = splitInfo.right.lineNumber ?? splitInfo.left.lineNumber ?? 1
                        anchor = .line(filePath: exc.filePath, lineNumber: lineNum)
                    }
                    preserveCursorAndSelection {
                        if isFullExpand {
                            displayMap.multiBuffer.expandExcerptAll(at: exp.excerptIndex)
                        } else {
                            switch exp.direction {
                            case .up:
                                displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 5, down: 0)
                            case .down:
                                displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 0, down: 5)
                            case .upAndDown:
                                let relY = screenPoint.y - lineScreenY
                                if relY < height / 2 {
                                    displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 5, down: 0)
                                } else {
                                    displayMap.multiBuffer.expandExcerpt(at: exp.excerptIndex, up: 0, down: 5)
                                }
                            }
                        }
                    }
                    preserveScreenPosition(ofAnchor: anchor, originalScreenY: lineScreenY)
                    return
                } else if screenPoint.x < geom.dividerRect.minX,
                          let leftRow = splitInfo.left.multiBufferRow ?? splitInfo.right.multiBufferRow {
                    splitActiveColumn = .left
                    isDraggingSelection = true
                    let text = splitInfo.left.text
                    let ctLine = getOrCreateCTLine(for: lineIdx * 2, text: text, language: splitInfo.language)
                    let xOffset = max(0, screenPoint.x + scrollOffsetX - geom.leftCodeRect.minX - Self.codeLeftPadding)
                    let col = ctLine.characterIndex(at: xOffset, in: text)
                    let targetPoint = MultiBufferPoint(row: leftRow, column: col)

                    if event.clickCount == 2 {
                        let (wordStart, wordEnd) = wordRange(in: text, at: col)
                        activeSelectionGranularity = .word(initialStart: wordStart, initialEnd: wordEnd, initialRow: leftRow)
                        selectionAnchor = MultiBufferPoint(row: leftRow, column: wordStart)
                        cursorPoint = MultiBufferPoint(row: leftRow, column: wordEnd)
                    } else if event.clickCount >= 3 {
                        activeSelectionGranularity = .line(initialRow: leftRow)
                        selectionAnchor = MultiBufferPoint(row: leftRow, column: 0)
                        cursorPoint = MultiBufferPoint(row: leftRow, column: text.count)
                    } else {
                        activeSelectionGranularity = .character
                        if isShift {
                            if selectionAnchor == nil {
                                selectionAnchor = cursorPoint
                            }
                        } else {
                            selectionAnchor = nil
                        }
                        cursorPoint = targetPoint
                    }
                    needsDisplay = true
                    return
                } else if screenPoint.x >= geom.dividerRect.minX,
                          let rightRow = splitInfo.right.multiBufferRow ?? splitInfo.left.multiBufferRow {
                    splitActiveColumn = .right
                    isDraggingSelection = true
                    let text = splitInfo.right.text
                    let ctLine = getOrCreateCTLine(for: (lineIdx * 2) + 1, text: text, language: splitInfo.language)
                    let xOffset = max(0, screenPoint.x + scrollOffsetX - geom.rightCodeRect.minX - Self.codeLeftPadding)
                    let col = ctLine.characterIndex(at: xOffset, in: text)
                    let targetPoint = MultiBufferPoint(row: rightRow, column: col)

                    if event.clickCount == 2 {
                        let (wordStart, wordEnd) = wordRange(in: text, at: col)
                        activeSelectionGranularity = .word(initialStart: wordStart, initialEnd: wordEnd, initialRow: rightRow)
                        selectionAnchor = MultiBufferPoint(row: rightRow, column: wordStart)
                        cursorPoint = MultiBufferPoint(row: rightRow, column: wordEnd)
                    } else if event.clickCount >= 3 {
                        activeSelectionGranularity = .line(initialRow: rightRow)
                        selectionAnchor = MultiBufferPoint(row: rightRow, column: 0)
                        cursorPoint = MultiBufferPoint(row: rightRow, column: text.count)
                    } else {
                        activeSelectionGranularity = .character
                        if isShift {
                            if selectionAnchor == nil {
                                selectionAnchor = cursorPoint
                            }
                        } else {
                            selectionAnchor = nil
                        }
                        cursorPoint = targetPoint
                    }
                    needsDisplay = true
                    return
                }
            case .inlineComment:
                return
            }
        }

        isDraggingSelection = true
        activeSelectionGranularity = .character
        if docY > totalDocumentHeight, let lastCode = displayMap.lastCodeInfo {
            let targetPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
            if isShift {
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
            } else {
                selectionAnchor = nil
            }
            cursorPoint = targetPoint
            needsDisplay = true
        } else if docY < 0, let firstCode = displayMap.firstCodeInfo {
            let targetPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
            if isShift {
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
            } else {
                selectionAnchor = nil
            }
            cursorPoint = targetPoint
            needsDisplay = true
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDraggingDivider {
            let screenPoint = convert(event.locationInWindow, from: nil)
            let gWidth: CGFloat = gutterWidth
            let dWidth: CGFloat = 1
            let availableWidth = max(bounds.width, 400)
            let totalGutterSpace = (gWidth * 2) + dWidth
            let totalCodeSpace = max(200, availableWidth - totalGutterSpace)
            let targetLeftCodeWidth = screenPoint.x - gWidth
            let newRatio = max(0.15, min(0.85, targetLeftCodeWidth / totalCodeSpace))
            splitRatio = newRatio
            return
        }

        if scrollbarDragAxis != nil {
            updateScrollbarDrag(at: convert(event.locationInWindow, from: nil))
            return
        }

        guard isDraggingSelection else { return }
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        guard let displayMap = displayMap, !excerptLayouts.isEmpty else { return }

        let lineIdx = lineIndex(atY: docY)
        guard lineIdx >= 0 && lineIdx < displayMap.displayLineCount,
              let line = displayMap.displayLine(at: lineIdx) else { return }

        if case .code(let codeInfo) = line {
            let text = codeInfo.text
            let ctLine = getOrCreateCTLine(for: lineIdx, text: text, language: codeInfo.language)
            let xOffset = max(0, docX - (gutterWidth + Self.codeLeftPadding))
            let col = ctLine.characterIndex(at: xOffset, in: text)
            let targetRow = codeInfo.multiBufferRow

            switch activeSelectionGranularity {
            case .character:
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
                cursorPoint = MultiBufferPoint(row: targetRow, column: col)
            case .word(let initStart, let initEnd, let initRow):
                let (curWordStart, curWordEnd) = wordRange(in: text, at: col)
                if targetRow > initRow || (targetRow == initRow && col >= initStart) {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initStart)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: curWordEnd)
                } else {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initEnd)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: curWordStart)
                }
            case .line(let initRow):
                if targetRow >= initRow {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: 0)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: text.count)
                } else {
                    let initLen = displayMap.lineLength(at: initRow)
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initLen)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: 0)
                }
            }
            needsDisplay = true
        } else if case .splitCode(let splitInfo) = line {
            let isLeft = (splitActiveColumn == .left)
            guard let targetRow = isLeft ? (splitInfo.left.multiBufferRow ?? splitInfo.right.multiBufferRow)
                                         : (splitInfo.right.multiBufferRow ?? splitInfo.left.multiBufferRow) else { return }
            let geom = splitGeometry(atY: docY - scrollOffsetY, height: lineHeight)
            let text = isLeft ? splitInfo.left.text : splitInfo.right.text
            let ctLine = getOrCreateCTLine(for: (lineIdx * 2) + (isLeft ? 0 : 1), text: text, language: splitInfo.language)
            let codeMinX = isLeft ? geom.leftCodeRect.minX : geom.rightCodeRect.minX
            let xOffset = max(0, screenPoint.x + scrollOffsetX - codeMinX - Self.codeLeftPadding)
            let col = ctLine.characterIndex(at: xOffset, in: text)

            switch activeSelectionGranularity {
            case .character:
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
                cursorPoint = MultiBufferPoint(row: targetRow, column: col)
            case .word(let initStart, let initEnd, let initRow):
                let (curWordStart, curWordEnd) = wordRange(in: text, at: col)
                if targetRow > initRow || (targetRow == initRow && col >= initStart) {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initStart)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: curWordEnd)
                } else {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initEnd)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: curWordStart)
                }
            case .line(let initRow):
                if targetRow >= initRow {
                    selectionAnchor = MultiBufferPoint(row: initRow, column: 0)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: text.count)
                } else {
                    let initLen = activeLineLength(at: initRow)
                    selectionAnchor = MultiBufferPoint(row: initRow, column: initLen)
                    cursorPoint = MultiBufferPoint(row: targetRow, column: 0)
                }
            }
            needsDisplay = true
        } else {
            if docY > totalDocumentHeight, let lastCode = displayMap.lastCodeInfo {
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
                cursorPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
                needsDisplay = true
            } else if docY < 0, let firstCode = displayMap.firstCodeInfo {
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint
                }
                cursorPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
                needsDisplay = true
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if isDraggingDivider {
            isDraggingDivider = false
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if let axis = scrollbarDragAxis {
            scrollbarDragAxis = nil
            showScrollbarsWithAutohide(for: axis == .vertical ? .vertical : .horizontal)
        }
        isDraggingSelection = false
        activeSelectionGranularity = .character
        checkAndPublishSelectionQuote()
    }

    public override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        checkAndPublishSelectionQuote()
    }

    public func checkAndPublishSelectionQuote() {
        guard let dm = displayMap else {
            if let lastId = lastPublishedQuoteId {
                SelectionQuoteStore.shared.clearQuote(scopedToId: lastId)
                lastPublishedQuoteId = nil
            }
            return
        }

        guard hasSelection, let sel = normalizedSelectionRange(), !sel.isEmpty else {
            if let lastId = lastPublishedQuoteId {
                SelectionQuoteStore.shared.clearQuote(scopedToId: lastId)
                lastPublishedQuoteId = nil
            }
            return
        }

        guard let text = dm.getSelectionText(for: sel), text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            if let lastId = lastPublishedQuoteId {
                SelectionQuoteStore.shared.clearQuote(scopedToId: lastId)
                lastPublishedQuoteId = nil
            }
            return
        }

        let startRow = sel.lowerBound.row
        let endRow = (sel.upperBound.row > sel.lowerBound.row && sel.upperBound.column == 0)
            ? sel.upperBound.row - 1
            : sel.upperBound.row

        let startLoc = dm.fastSourceLocation(forCodeRow: startRow)
        let endLoc = dm.fastSourceLocation(forCodeRow: endRow)

        let isSingleFile = (startLoc != nil && endLoc != nil && startLoc?.filePath == endLoc?.filePath)
        let resolvedFilePath = isSingleFile ? startLoc?.filePath : nil
        let fileName = resolvedFilePath.map { ($0 as NSString).lastPathComponent } ?? "selection"

        let lineRange: ClosedRange<Int>?
        if isSingleFile, let s = startLoc?.lineNumber, let e = endLoc?.lineNumber {
            lineRange = min(s, e)...max(s, e)
        } else {
            lineRange = nil
        }

        let linesLabel: String
        if let range = lineRange {
            linesLabel = range.lowerBound == range.upperBound ? " (L\(range.lowerBound))" : " (L\(range.lowerBound)-\(range.upperBound))"
        } else {
            linesLabel = ""
        }

        let quoteId = "editor:\(resolvedFilePath ?? "multibuffer")"
        let quote = SelectionQuote(
            id: quoteId,
            text: text,
            source: .editor,
            label: "\(fileName)\(linesLabel)",
            filePath: resolvedFilePath,
            displayPath: resolvedFilePath,
            lineRange: lineRange,
            language: resolvedFilePath.map { Buffer.detectLanguage(for: $0) }
        )
        lastPublishedQuoteId = quoteId
        SelectionQuoteStore.shared.setQuote(quote)
    }

    @discardableResult
    func updateCloseHoverState(at screenPoint: CGPoint) -> Bool {
        var shouldHandCursor = false
        var hoveredFilePath: String? = nil
        var hoveredPrevPath: String? = nil

        if let (stickyInfo, stickyFrame) = currentStickyHeader(), stickyFrame.contains(screenPoint) {
            let isMd = stickyInfo.filePath.hasSuffix(".md") || stickyInfo.filePath.hasSuffix(".markdown") || stickyInfo.filePath.hasSuffix(".mdx")
            if isMd && previewButtonRect(in: stickyFrame, for: stickyInfo).contains(screenPoint) {
                shouldHandCursor = true
                hoveredPrevPath = stickyInfo.filePath
            }
            let closeRect = closeButtonRect(in: stickyFrame)
            if closeRect.contains(screenPoint) {
                shouldHandCursor = true
                hoveredFilePath = stickyInfo.filePath
            }
        } else if let displayMap = displayMap {
            let docY = screenPoint.y + scrollOffsetY
            let lineIdx = lineIndex(atY: docY)
            if let line = displayMap.displayLine(at: lineIdx), case .excerptHeader(let header) = line {
                let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
                let height = lineHeight(forDisplayLineIndex: lineIdx)
                let headerRect = CGRect(x: 0, y: lineMinY, width: bounds.width, height: height)
                let pt = CGPoint(x: screenPoint.x, y: docY)
                let isMd = header.filePath.hasSuffix(".md") || header.filePath.hasSuffix(".markdown") || header.filePath.hasSuffix(".mdx")
                if isMd && previewButtonRect(in: headerRect, for: header).contains(pt) {
                    shouldHandCursor = true
                    hoveredPrevPath = header.filePath
                }
                let closeRect = closeButtonRect(in: headerRect)
                if closeRect.contains(pt) {
                    shouldHandCursor = true
                    hoveredFilePath = header.filePath
                }
            }
        }

        var didChange = false
        if hoveredFilePath != hoveredCloseFilePath {
            hoveredCloseFilePath = hoveredFilePath
            didChange = true
        }
        if hoveredPrevPath != hoveredPreviewFilePath {
            hoveredPreviewFilePath = hoveredPrevPath
            didChange = true
        }
        if didChange {
            needsDisplay = true
        }

        if hoveredPrevPath != nil {
            toolTip = "Preview Markdown (⌘E)"
        } else if hoveredFilePath != nil {
            toolTip = "Close file"
        } else {
            toolTip = nil
        }

        if shouldHandCursor {
            NSCursor.pointingHand.set()
        }
        return shouldHandCursor
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let screenPoint = convert(event.locationInWindow, from: nil)
        updateCloseHoverState(at: screenPoint)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        toolTip = nil
        var didChange = false
        if hoveredCloseFilePath != nil {
            hoveredCloseFilePath = nil
            didChange = true
        }
        if hoveredPreviewFilePath != nil {
            hoveredPreviewFilePath = nil
            didChange = true
        }
        if didChange {
            needsDisplay = true
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if displayMap?.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: 0, height: bounds.height)
            let dividerHitRect = CGRect(x: geom.dividerRect.midX - 5, y: 0, width: 10, height: bounds.height)
            addCursorRect(dividerHitRect, cursor: .resizeLeftRight)
        }
    }
}
