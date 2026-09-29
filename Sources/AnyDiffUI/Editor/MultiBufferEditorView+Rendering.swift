import Foundation
import AppKit
import CoreText
import AnyDiffCore

extension MultiBufferEditorView {
    // MARK: - Virtualized Rendering Engine

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let displayMap = displayMap else {
            theme.background.setFill()
            dirtyRect.fill()
            return
        }

        let totalLines = displayMap.displayLineCount
        guard totalLines > 0 else {
            context.saveGState()
            context.setFillColor(theme.background.cgColor)
            context.fill(bounds)
            context.restoreGState()
            return
        }

        syncLayoutIfNeeded()

        guard !excerptLayouts.isEmpty else {
            context.saveGState()
            context.setFillColor(theme.background.cgColor)
            context.fill(bounds)
            context.restoreGState()
            return
        }

        context.saveGState()
        if contentCornerRadius > 0 {
            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: contentCornerRadius,
                cornerHeight: contentCornerRadius,
                transform: nil
            )
            context.addPath(path)
            context.clip()
        } else {
            context.clip(to: bounds)
        }

        // 1. Draw Canvas Background
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        let visibleMinY = scrollOffsetY
        let visibleMaxY = scrollOffsetY + bounds.height
        let lineWidth = max(bounds.width + scrollOffsetX, totalDocumentWidth)

        let rawStartIdx = lineIndex(atY: visibleMinY)
        let rawEndIdx = lineIndex(atY: visibleMaxY)
        let startIdx = max(0, min(totalLines - 1, rawStartIdx))
        let endIdx = max(startIdx, min(totalLines - 1, rawEndIdx + 1))

        guard startIdx <= endIdx && startIdx >= 0 && endIdx < totalLines else {
            context.restoreGState()
            return
        }

        // Pre-fetch all visible items in a single batch query for this frame
        let visibleItems = displayMap.visibleLines(in: startIdx..<(endIdx + 1))

        // 2. Pass 1: Draw Code Lines (content that scrolls horizontally under gutter)
        for item in visibleItems {
            let lineIdx = item.displayLineIndex
            let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
            let height = lineHeight(forDisplayLineIndex: lineIdx)
            let screenLineFrame = CGRect(
                x: -scrollOffsetX,
                y: lineMinY - scrollOffsetY,
                width: lineWidth,
                height: height
            )

            switch item.line {
            case .code(var info):
                if let mbRow = item.multiBufferRow {
                    info.multiBufferRow = mbRow
                }
                info.displayLineIndex = lineIdx
                drawCodeLine(info: info, lineIdx: lineIdx, in: screenLineFrame, context: context)

            case .splitCode(var sInfo):
                sInfo.displayLineIndex = lineIdx
                drawSplitCodeLine(info: sInfo, lineIdx: lineIdx, in: CGRect(x: 0, y: lineMinY - scrollOffsetY, width: bounds.width, height: height), context: context)

            default:
                break
            }
        }

        // 3. Pass 2: Draw Sticky Gutters, Excerpt Headers, Fold Gaps & Comments (Sticky UI)
        for item in visibleItems {
            let lineIdx = item.displayLineIndex
            let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
            let height = lineHeight(forDisplayLineIndex: lineIdx)
            let screenY = lineMinY - scrollOffsetY

            switch item.line {
            case .excerptHeader(let info):
                let headerFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawExcerptHeader(info: info, in: headerFrame, context: context)

            case .code(var info):
                if let mbRow = item.multiBufferRow {
                    info.multiBufferRow = mbRow
                }
                info.displayLineIndex = lineIdx
                let gutterRect = CGRect(x: 0, y: screenY, width: gutterWidth, height: height)
                context.setFillColor(theme.background.cgColor)
                context.fill(gutterRect)
                drawGutter(for: info, lineIdx: lineIdx, in: gutterRect, context: context)

            case .splitCode(let sInfo):
                drawSplitGuttersAndDivider(for: sInfo, lineIdx: lineIdx, in: CGRect(x: 0, y: screenY, width: bounds.width, height: height), context: context)

            case .foldGap(let info):
                let gapFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawFoldGap(info: info, lineIdx: lineIdx, in: gapFrame, context: context)

            case .inlineComment(let info):
                let commentFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawInlineComment(info: info, in: commentFrame, context: context)
            }
        }

        // 3.5. Draw Sticky Excerpt Header (pinned to top while scrolling through file contents)
        if let (stickyInfo, stickyFrame) = currentStickyHeader() {
            drawExcerptHeader(info: stickyInfo, in: stickyFrame, isSticky: true, context: context)
        }

        // 4. Draw Overlay Scrollbars with Auto-Hide Fade (Vertical & Horizontal)
        if scrollbarAlpha > 0.01 {
            let thumbColor = scrollbarThumbBaseColor.withAlphaComponent(0.45 * scrollbarAlpha)

            if visibleScrollbarAxis == .vertical, let geometry = verticalScrollbarGeometry() {
                context.setFillColor(thumbColor.cgColor)
                let path = CGPath(roundedRect: geometry.thumb, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(path)
                context.fillPath()
            }

            if visibleScrollbarAxis == .horizontal, let geometry = horizontalScrollbarGeometry() {
                context.setFillColor(thumbColor.cgColor)
                let path = CGPath(roundedRect: geometry.thumb, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(path)
                context.fillPath()
            }
        }

        context.restoreGState()
    }


    // MARK: - Code Line Drawing

    @inlinable
    func getOrCreateCTLine(for lineIdx: Int, text: String, language: String) -> CTLine {
        if let cached = lineCache.get(lineIndex: lineIdx) {
            return cached
        }
        let attrText = SyntaxHighlighter.shared.highlight(
            line: text,
            language: language,
            font: font,
            theme: theme
        )
        let created = CTLineCreateWithAttributedString(attrText)
        lineCache.set(lineIndex: lineIdx, ctLine: created)
        return created
    }

    func drawCodeLine(info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        let isCurrentCursorLine = window?.firstResponder === self && info.multiBufferRow == cursorPoint.row
        let fullLineWidth = max(rect.width, bounds.width + scrollOffsetX, totalDocumentWidth)

        // 1. Line Background (Diff Tint or Current Line Highlight)
        let bgRect = CGRect(x: rect.minX + gutterWidth, y: rect.minY, width: fullLineWidth, height: rect.height)
        if info.diffKind == .added {
            context.setFillColor(theme.diffAddedBackground.cgColor)
            context.fill(bgRect)
        } else if info.diffKind == .deleted {
            context.setFillColor(theme.diffDeletedBackground.cgColor)
            context.fill(bgRect)
        } else if isCurrentCursorLine {
            context.setFillColor(theme.currentLineBackground.cgColor)
            context.fill(bgRect)
        }

        // 2. Syntax Highlighting & Word Diff Highlighting
        let codeStartX = rect.minX + gutterWidth + Self.codeLeftPadding
        let ctLine = getOrCreateCTLine(for: lineIdx, text: info.text, language: info.language)

        // Word Diff Highlight Rectangles
        if !info.wordDiffRanges.isEmpty {
            let wordBgColor = (info.diffKind == .added) ? theme.diffAddedWordHighlight : theme.diffDeletedWordHighlight
            context.setFillColor(wordBgColor.cgColor)
            let horizontalPadding: CGFloat = 2
            for range in info.wordDiffRanges {
                let startX = ctLine.xOffset(for: range.lowerBound)
                let endX = ctLine.xOffset(for: range.upperBound)
                let wordRect = CGRect(
                    x: codeStartX + startX - horizontalPadding,
                    y: rect.minY + 2,
                    width: max(4, endX - startX) + (horizontalPadding * 2),
                    height: rect.height - 4
                )
                let rounded = CGPath(roundedRect: wordRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(rounded)
                context.fillPath()
            }
        }

        // Search Match Highlight Rectangles
        let lineNum = info.newLineNumber ?? info.oldLineNumber
        let filePath = (displayMap != nil && info.excerptIndex < (displayMap?.multiBuffer.excerpts.count ?? 0))
            ? displayMap?.multiBuffer.excerpts[info.excerptIndex].filePath
            : nil

        let rowMatches: [ProjectSearchMatch]?
        if let lineNum = lineNum, let path = filePath {
            rowMatches = searchMatchesByFileLine[SearchFileLineKey(filePath: path, lineNumber: lineNum)]
        } else {
            rowMatches = nil
        }

        if let matches = rowMatches, !matches.isEmpty {
            let activeId = activeMatchId
            let elapsed = CFAbsoluteTimeGetCurrent() - activeMatchPulseStartTime
            let isPulsing = elapsed < 0.45
            let pulseProgress = isPulsing ? max(0.0, min(1.0, elapsed / 0.45)) : 1.0
            // Smooth ease-out curve for the flash pulse
            let pulseIntensity = CGFloat(pow(1.0 - pulseProgress, 2.0))

            for match in matches {
                let isActive = (match.id == activeId)
                let bgColor: NSColor
                if isActive {
                    // Bright vibrant blue highlight for active match
                    bgColor = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.98, alpha: 0.72)
                } else {
                    // Amber/orange highlight for other matches
                    bgColor = NSColor(calibratedRed: 0.92, green: 0.58, blue: 0.18, alpha: 0.42)
                }
                context.setFillColor(bgColor.cgColor)

                let startX = ctLine.xOffset(forCharacterIndex: min(info.text.count, max(0, match.columnRange.lowerBound)), in: info.text)
                let endX = ctLine.xOffset(forCharacterIndex: min(info.text.count, max(match.columnRange.lowerBound, match.columnRange.upperBound)), in: info.text)
                let matchRect = CGRect(
                    x: codeStartX + startX - 1,
                    y: rect.minY + 2,
                    width: max(4, endX - startX) + 2,
                    height: rect.height - 4
                )
                let rounded = CGPath(roundedRect: matchRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(rounded)
                context.fillPath()

                if isActive {
                    // Crisp outline around active match
                    context.setStrokeColor(NSColor(calibratedRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.95).cgColor)
                    context.setLineWidth(1.2)
                    context.addPath(rounded)
                    context.strokePath()

                    // Flash Pulse animation ring & soft glow
                    if isPulsing && pulseIntensity > 0.01 {
                        let expandX = 5.0 * pulseIntensity
                        let expandY = 3.0 * pulseIntensity
                        let pulseRect = matchRect.insetBy(dx: -expandX, dy: -expandY)
                        let pulsePath = CGPath(roundedRect: pulseRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)

                        // Soft halo fill
                        context.setFillColor(NSColor(calibratedRed: 0.25, green: 0.65, blue: 1.0, alpha: 0.38 * pulseIntensity).cgColor)
                        context.addPath(pulsePath)
                        context.fillPath()

                        // Expanding luminous ring
                        context.setStrokeColor(NSColor(calibratedRed: 0.65, green: 0.88, blue: 1.0, alpha: 0.90 * pulseIntensity).cgColor)
                        context.setLineWidth(1.5 + (1.5 * pulseIntensity))
                        context.addPath(pulsePath)
                        context.strokePath()
                    }
                }
            }
        }

        // Text Selection Rectangles
        if hasSelection, let selRange = normalizedSelectionRange(),
           info.multiBufferRow >= selRange.lowerBound.row && info.multiBufferRow <= selRange.upperBound.row {
            let startCol = (info.multiBufferRow == selRange.lowerBound.row) ? selRange.lowerBound.column : 0
            let endCol = (info.multiBufferRow == selRange.upperBound.row) ? selRange.upperBound.column : info.text.count
            let startX = ctLine.xOffset(forCharacterIndex: min(info.text.count, max(0, startCol)), in: info.text)
            let endX = ctLine.xOffset(forCharacterIndex: min(info.text.count, max(startCol, endCol)), in: info.text)
            let selRect = CGRect(x: codeStartX + startX, y: rect.minY, width: max(3, endX - startX), height: rect.height)
            context.setFillColor(theme.selectionBackground.cgColor)
            context.fill(selRect)
        }

        // Draw Code Line Text
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: codeStartX, y: rect.minY + fontAscent + 2)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // 3. Draw Caret / Cursor if focused on this line
        if isCurrentCursorLine && isCursorVisible {
            let clampedCol = min(info.text.count, max(0, cursorPoint.column))
            let cursorX = codeStartX + ctLine.xOffset(forCharacterIndex: clampedCol, in: info.text)
            let cursorRect = CGRect(x: cursorX, y: rect.minY + 2, width: 2, height: rect.height - 4)
            context.setFillColor(theme.diffModifiedGutter.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Side-by-Side (Split Diff) Rendering

    struct SplitGeometry {
        let boundsWidth: CGFloat
        let gutterWidth: CGFloat
        let dividerWidth: CGFloat
        let columnWidth: CGFloat
        let leftGutterRect: CGRect
        let leftCodeRect: CGRect
        let dividerRect: CGRect
        let rightGutterRect: CGRect
        let rightCodeRect: CGRect
    }

    func splitGeometry(atY screenY: CGFloat, height: CGFloat) -> SplitGeometry {
        let gWidth: CGFloat = gutterWidth
        let dWidth: CGFloat = 1
        let availableWidth = max(bounds.width, 400)
        let totalGutterSpace = (gWidth * 2) + dWidth
        let totalCodeSpace = max(200, availableWidth - totalGutterSpace)
        let leftCodeWidth = max(80, min(totalCodeSpace - 80, round(totalCodeSpace * splitRatio)))

        let leftGutter = CGRect(x: 0, y: screenY, width: gWidth, height: height)
        let leftCode = CGRect(x: gWidth, y: screenY, width: leftCodeWidth, height: height)
        let divider = CGRect(x: gWidth + leftCodeWidth, y: screenY, width: dWidth, height: height)
        let rightGutter = CGRect(x: gWidth + leftCodeWidth + dWidth, y: screenY, width: gWidth, height: height)
        let rightCodeX = gWidth + leftCodeWidth + dWidth + gWidth
        let rightColWidth = max(80, availableWidth - rightCodeX)
        let rightCode = CGRect(x: rightCodeX, y: screenY, width: rightColWidth, height: height)

        return SplitGeometry(
            boundsWidth: availableWidth,
            gutterWidth: gWidth,
            dividerWidth: dWidth,
            columnWidth: leftCodeWidth,
            leftGutterRect: leftGutter,
            leftCodeRect: leftCode,
            dividerRect: divider,
            rightGutterRect: rightGutter,
            rightCodeRect: rightCode
        )
    }

    func drawSplitCodeLine(info: DisplaySplitCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        let geom = splitGeometry(atY: rect.minY, height: rect.height)
        let isLeftActive = (splitActiveColumn == .left)
        let leftRow = info.left.multiBufferRow ?? info.right.multiBufferRow
        let rightRow = info.right.multiBufferRow ?? info.left.multiBufferRow
        let isLeftCursorLine = window?.firstResponder === self && isLeftActive && leftRow == cursorPoint.row
        let isRightCursorLine = window?.firstResponder === self && !isLeftActive && rightRow == cursorPoint.row

        // 1. Draw Left Column (Old)
        if info.left.isSpacer {
            drawSpacerHatch(in: geom.leftCodeRect, context: context)
        } else {
            if info.left.diffKind == .deleted {
                context.setFillColor(theme.diffDeletedBackground.cgColor)
                context.fill(geom.leftCodeRect)
            } else if isLeftCursorLine {
                context.setFillColor(theme.currentLineBackground.cgColor)
                context.fill(geom.leftCodeRect)
            }

            context.saveGState()
            context.clip(to: geom.leftCodeRect)

            let leftStartX = geom.leftCodeRect.minX + Self.codeLeftPadding - scrollOffsetX
            let ctLine = getOrCreateCTLine(for: lineIdx * 2, text: info.left.text, language: info.language)

            // Word diff highlights on left
            if !info.left.wordDiffRanges.isEmpty {
                context.setFillColor(theme.diffDeletedWordHighlight.cgColor)
                for range in info.left.wordDiffRanges {
                    let sX = ctLine.xOffset(for: range.lowerBound)
                    let eX = ctLine.xOffset(for: range.upperBound)
                    let wRect = CGRect(x: leftStartX + sX - 2, y: rect.minY + 2, width: max(4, eX - sX) + 4, height: rect.height - 4)
                    let p = CGPath(roundedRect: wRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                    context.addPath(p)
                    context.fillPath()
                }
            }

            // Text Selection Rectangles on left
            if isLeftActive, hasSelection, let selRange = normalizedSelectionRange(),
               let mbRow = leftRow,
               mbRow >= selRange.lowerBound.row && mbRow <= selRange.upperBound.row {
                let startCol = (mbRow == selRange.lowerBound.row) ? selRange.lowerBound.column : 0
                let endCol = (mbRow == selRange.upperBound.row) ? selRange.upperBound.column : info.left.text.count
                if startCol < endCol {
                    let sX = ctLine.xOffset(for: startCol)
                    let eX = ctLine.xOffset(for: endCol)
                    context.setFillColor(theme.selectionBackground.cgColor)
                    let selRect = CGRect(x: leftStartX + sX, y: rect.minY, width: max(3, eX - sX), height: rect.height)
                    context.fill(selRect)
                }
            }

            // Draw Caret / Cursor if focused on left column
            if isLeftCursorLine && isCursorVisible {
                let clampedCol = min(info.left.text.count, max(0, cursorPoint.column))
                let cursorX = leftStartX + ctLine.xOffset(forCharacterIndex: clampedCol, in: info.left.text)
                let cursorRect = CGRect(x: cursorX, y: rect.minY + 2, width: 2, height: rect.height - 4)
                context.setFillColor(theme.diffModifiedGutter.cgColor)
                context.fill(cursorRect)
            }

            context.textMatrix = .identity
            context.translateBy(x: leftStartX, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }

        // 2. Draw Right Column (New / Modified)
        if info.right.isSpacer {
            drawSpacerHatch(in: geom.rightCodeRect, context: context)
        } else {
            if info.right.diffKind == .added {
                context.setFillColor(theme.diffAddedBackground.cgColor)
                context.fill(geom.rightCodeRect)
            } else if isRightCursorLine {
                context.setFillColor(theme.currentLineBackground.cgColor)
                context.fill(geom.rightCodeRect)
            }

            context.saveGState()
            context.clip(to: geom.rightCodeRect)

            let rightStartX = geom.rightCodeRect.minX + Self.codeLeftPadding - scrollOffsetX
            let ctLine = getOrCreateCTLine(for: (lineIdx * 2) + 1, text: info.right.text, language: info.language)

            // Word diff highlights on right
            if !info.right.wordDiffRanges.isEmpty {
                context.setFillColor(theme.diffAddedWordHighlight.cgColor)
                for range in info.right.wordDiffRanges {
                    let sX = ctLine.xOffset(for: range.lowerBound)
                    let eX = ctLine.xOffset(for: range.upperBound)
                    let wRect = CGRect(x: rightStartX + sX - 2, y: rect.minY + 2, width: max(4, eX - sX) + 4, height: rect.height - 4)
                    let p = CGPath(roundedRect: wRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                    context.addPath(p)
                    context.fillPath()
                }
            }

            // Text Selection Rectangles on right
            if !isLeftActive, hasSelection, let selRange = normalizedSelectionRange(),
               let mbRow = rightRow,
               mbRow >= selRange.lowerBound.row && mbRow <= selRange.upperBound.row {
                let startCol = (mbRow == selRange.lowerBound.row) ? selRange.lowerBound.column : 0
                let endCol = (mbRow == selRange.upperBound.row) ? selRange.upperBound.column : info.right.text.count
                if startCol < endCol {
                    let sX = ctLine.xOffset(for: startCol)
                    let eX = ctLine.xOffset(for: endCol)
                    context.setFillColor(theme.selectionBackground.cgColor)
                    let selRect = CGRect(x: rightStartX + sX, y: rect.minY, width: max(3, eX - sX), height: rect.height)
                    context.fill(selRect)
                }
            }

            // Draw Caret / Cursor if focused on right column
            if isRightCursorLine && isCursorVisible {
                let clampedCol = min(info.right.text.count, max(0, cursorPoint.column))
                let cursorX = rightStartX + ctLine.xOffset(forCharacterIndex: clampedCol, in: info.right.text)
                let cursorRect = CGRect(x: cursorX, y: rect.minY + 2, width: 2, height: rect.height - 4)
                context.setFillColor(theme.diffModifiedGutter.cgColor)
                context.fill(cursorRect)
            }

            context.textMatrix = .identity
            context.translateBy(x: rightStartX, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }

    func drawSpacerHatch(in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(theme.currentLineBackground.withAlphaComponent(0.18).cgColor)
        context.fill(rect)

        context.setStrokeColor(theme.excerptHeaderBorder.withAlphaComponent(0.40).cgColor)
        context.setLineWidth(1.0)
        let spacing: CGFloat = 10
        var startX = rect.minX - rect.height
        while startX < rect.maxX {
            context.move(to: CGPoint(x: startX, y: rect.maxY))
            context.addLine(to: CGPoint(x: startX + rect.height, y: rect.minY))
            startX += spacing
        }
        context.strokePath()
        context.restoreGState()
    }

    func drawSplitGuttersAndDivider(for info: DisplaySplitCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        let geom = splitGeometry(atY: rect.minY, height: rect.height)

        // 1. Center Divider (1px normal hairline, 2px accented when dragging)
        if isDraggingDivider {
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fill(CGRect(x: geom.dividerRect.minX - 0.5, y: rect.minY, width: 2, height: rect.height))
        } else {
            context.setFillColor(theme.excerptHeaderBorder.cgColor)
            context.fill(geom.dividerRect)
        }

        // 2. Left Gutter
        context.setFillColor(theme.background.cgColor)
        context.fill(geom.leftGutterRect)

        if info.left.diffKind == .deleted && !info.left.isSpacer {
            context.setFillColor(theme.diffDeletedBackground.cgColor)
            context.fill(geom.leftGutterRect)
            context.setFillColor(theme.diffDeletedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        }

        if let expandInfo = info.expandInfo {
            let btnRect = CGRect(x: 4, y: rect.minY + (rect.height - 16) / 2, width: 16, height: 16)
            drawExpandButton(expandInfo: expandInfo, in: btnRect, isHovered: hoveredGutterLineIndex == lineIdx, context: context)
        }

        if let num = info.left.lineNumber, !info.left.isSpacer {
            let color = (info.left.diffKind == .deleted) ? theme.diffDeletedGutter : theme.gutterForeground
            let str = NSAttributedString(string: "\(num)", attributes: [
                .font: Self.gutterFont,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(str)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let numWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let numX = geom.leftGutterRect.maxX - numWidth - 8

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: numX, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        // 3. Right Gutter
        context.setFillColor(theme.background.cgColor)
        context.fill(geom.rightGutterRect)

        if info.right.diffKind == .added && !info.right.isSpacer {
            context.setFillColor(theme.diffAddedBackground.cgColor)
            context.fill(geom.rightGutterRect)
            context.setFillColor(theme.diffAddedGutter.cgColor)
            context.fill(CGRect(x: geom.rightGutterRect.minX, y: rect.minY, width: 3, height: rect.height))
        }

        if let num = info.right.lineNumber, !info.right.isSpacer {
            let color = (info.right.diffKind == .added) ? theme.diffAddedGutter : theme.gutterForeground
            let str = NSAttributedString(string: "\(num)", attributes: [
                .font: Self.gutterFont,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(str)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let numWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let numX = geom.rightGutterRect.maxX - numWidth - 8

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: numX, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    // MARK: - Gutter Drawing

    func drawGutter(for info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        // Keep the line tint continuous through the gutter so line numbers have
        // the same background as the corresponding code line.
        switch info.diffKind {
        case .added:
            context.setFillColor(theme.diffAddedBackground.cgColor)
            context.fill(rect)
        case .deleted:
            context.setFillColor(theme.diffDeletedBackground.cgColor)
            context.fill(rect)
        case .unchanged, .header:
            break
        }

        // Diff Status Left Bar (3px stripe on left edge)
        if info.diffKind == .added {
            context.setFillColor(theme.diffAddedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        } else if info.diffKind == .deleted {
            context.setFillColor(theme.diffDeletedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        }

        // Expand Excerpt Button on the left
        if let expandInfo = info.expandInfo {
            let btnRect = CGRect(x: 4, y: rect.minY + (rect.height - 16) / 2, width: 16, height: 16)
            drawExpandButton(expandInfo: expandInfo, in: btnRect, isHovered: hoveredGutterLineIndex == lineIdx, context: context)
        }

        // Single Unified Line Number Column
        let lineNum = (info.diffKind == .deleted) ? info.oldLineNumber : (info.newLineNumber ?? info.oldLineNumber ?? (info.bufferRow + 1))
        if let num = lineNum {
            let color: NSColor
            switch info.diffKind {
            case .added:
                color = theme.diffAddedGutter
            case .deleted:
                color = theme.diffDeletedGutter
            case .unchanged, .header:
                color = theme.gutterForeground
            }

            let str = NSAttributedString(string: "\(num)", attributes: [
                .font: Self.gutterFont,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(str)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let numWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let numX = gutterWidth - numWidth - 8

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: numX, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    func drawExpandButton(expandInfo: ExpandInfo, in btnRect: CGRect, isHovered: Bool, context: CGContext) {
        context.saveGState()

        if isHovered {
            let bgPath = CGPath(roundedRect: btnRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            let hoverBackground = theme.isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.08)
            let hoverBorder = theme.isDark
                ? NSColor.white.withAlphaComponent(0.22)
                : NSColor.black.withAlphaComponent(0.16)
            context.setFillColor(hoverBackground.cgColor)
            context.addPath(bgPath)
            context.fillPath()

            context.setStrokeColor(hoverBorder.cgColor)
            context.setLineWidth(0.75)
            context.addPath(bgPath)
            context.strokePath()
        }

        let iconColor: NSColor = isHovered
            ? (theme.isDark ? .white : theme.foreground)
            : theme.gutterForeground.withAlphaComponent(0.7)
        context.setStrokeColor(iconColor.cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let cx = btnRect.midX
        let cy = btnRect.midY

        switch expandInfo.direction {
        case .up:
            context.move(to: CGPoint(x: cx - 3.2, y: cy + 4.5))
            context.addLine(to: CGPoint(x: cx + 3.2, y: cy + 4.5))
            context.move(to: CGPoint(x: cx, y: cy + 2.0))
            context.addLine(to: CGPoint(x: cx, y: cy - 4.5))
            context.move(to: CGPoint(x: cx - 3.0, y: cy - 1.5))
            context.addLine(to: CGPoint(x: cx, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx + 3.0, y: cy - 1.5))
            context.strokePath()

        case .down:
            context.move(to: CGPoint(x: cx - 3.2, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx + 3.2, y: cy - 4.5))
            context.move(to: CGPoint(x: cx, y: cy - 2.0))
            context.addLine(to: CGPoint(x: cx, y: cy + 4.5))
            context.move(to: CGPoint(x: cx - 3.0, y: cy + 1.5))
            context.addLine(to: CGPoint(x: cx, y: cy + 4.5))
            context.addLine(to: CGPoint(x: cx + 3.0, y: cy + 1.5))
            context.strokePath()

        case .upAndDown:
            context.move(to: CGPoint(x: cx - 2.5, y: cy - 2.0))
            context.addLine(to: CGPoint(x: cx, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx + 2.5, y: cy - 2.0))
            context.move(to: CGPoint(x: cx - 2.5, y: cy + 2.0))
            context.addLine(to: CGPoint(x: cx, y: cy + 4.5))
            context.addLine(to: CGPoint(x: cx + 2.5, y: cy + 2.0))
            context.move(to: CGPoint(x: cx, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx, y: cy + 4.5))
            context.strokePath()
        }

        context.restoreGState()
    }

    // MARK: - Fold Gap Drawing

    func drawFoldGap(info: DisplayFoldGapInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        context.setFillColor(theme.background.cgColor)
        context.fill(rect)

        let midY = floor(rect.midY) + 0.5

        // Gutter area background
        let gutterRect = CGRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height)
        context.setFillColor(theme.background.cgColor)
        context.fill(gutterRect)

        // Thin horizontal line across the entire editor width (from left edge to right edge)
        context.saveGState()
        let lineColor: NSColor = theme.isDark
            ? theme.foldPlaceholderForeground.withAlphaComponent(0.45)
            : theme.gutterForeground.withAlphaComponent(0.35)
        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1.0)
        context.strokeLineSegments(between: [
            CGPoint(x: 0, y: midY),
            CGPoint(x: rect.maxX, y: midY)
        ])
        context.restoreGState()
    }

    // MARK: - Inline Comment Drawing

    func drawInlineComment(info: DisplayCommentInfo, in rect: CGRect, context: CGContext) {
        let cardRect = CGRect(x: gutterWidth + 16, y: rect.minY + 4, width: min(650, bounds.width - gutterWidth - 32), height: rect.height - 8)

        // Card background & border
        context.setFillColor(theme.excerptHeaderBackground.cgColor)
        let path = CGPath(roundedRect: cardRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.fillPath()

        context.setStrokeColor(theme.diffModifiedGutter.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        // Author & Date
        let authorStr = NSAttributedString(string: "\(info.comment.author) (Code Reviewer)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: theme.foreground
        ])
        let authLine = CTLineCreateWithAttributedString(authorStr)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: cardRect.minX + 12, y: cardRect.minY + 18)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(authLine, context)
        context.restoreGState()

        // Comment content
        let contentStr = NSAttributedString(string: info.comment.content, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: theme.foreground.withAlphaComponent(0.9)
        ])
        let contentLine = CTLineCreateWithAttributedString(contentStr)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: cardRect.minX + 12, y: cardRect.minY + 38)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(contentLine, context)
        context.restoreGState()
    }
}
