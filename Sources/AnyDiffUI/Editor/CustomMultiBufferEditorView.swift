import Foundation
import AppKit
import CoreText
import AnyDiffCore

public protocol CustomMultiBufferEditorDelegate: AnyObject {
    func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint)
    func editorDidRequestAddComment(filePath: String, lineNumber: Int)
}

/// A high-performance, virtualized MultiBuffer Code Reviewer & Editor View built with CoreText
public final class CustomMultiBufferEditorView: NSView, NSTextInputClient {
    public weak var delegate: CustomMultiBufferEditorDelegate?

    public var displayMap: DisplayMap? {
        didSet {
            invalidateLayout()
        }
    }

    public var theme: Theme = .zedGray {
        didSet {
            needsDisplay = true
        }
    }

    public var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            updateFontMetrics()
            invalidateLayout()
        }
    }

    public var isEditable: Bool = true

    // Layout Metrics
    public private(set) var lineHeight: CGFloat = 22
    public private(set) var fontAscent: CGFloat = 14
    public private(set) var fontDescent: CGFloat = 4
    public private(set) var gutterWidth: CGFloat = 96
    public private(set) var excerptHeaderHeight: CGFloat = 34
    public private(set) var foldGapHeight: CGFloat = 26
    public private(set) var commentHeight: CGFloat = 64

    // Virtual Scrolling
    public var scrollOffsetY: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }
    public var scrollOffsetX: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }
    public private(set) var totalDocumentHeight: CGFloat = 0
    public private(set) var totalDocumentWidth: CGFloat = 0

    // Selection & Cursor State
    public var cursorPoint: MultiBufferPoint = .zero {
        didSet {
            resetCursorBlink()
            notifyCursorChange()
            ensureCursorVisible()
            needsDisplay = true
        }
    }
    public var selectionAnchor: MultiBufferPoint? = nil
    public var hasSelection: Bool {
        guard let anchor = selectionAnchor else { return false }
        return anchor != cursorPoint
    }

    // Cursor Animation
    private var cursorTimer: Timer?
    private var isCursorVisible: Bool = true

    // Hover State
    private var hoveredGutterLineIndex: Int? = nil
    private var trackingArea: NSTrackingArea?

    // Scrollbar Auto-Hide Animation
    private var scrollbarAlpha: CGFloat = 0.0
    private var scrollbarFadeTimer: Timer?
    private var fadeAnimationTimer: Timer?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init(displayMap: DisplayMap? = nil, theme: Theme = .zedDark) {
        self.displayMap = displayMap
        self.theme = theme
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        canDrawConcurrently = true
        updateFontMetrics()
        startCursorBlink()
    }

    deinit {
        cursorTimer?.invalidate()
        scrollbarFadeTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
    }

    private func showScrollbarsWithAutohide() {
        scrollbarFadeTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
        scrollbarAlpha = 1.0
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.startScrollbarFadeOut()
        }
        needsDisplay = true
    }

    private func startScrollbarFadeOut() {
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

    private func updateFontMetrics() {
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        fontAscent = CTFontGetAscent(ctFont)
        fontDescent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        lineHeight = max(18, ceil(fontAscent + fontDescent + leading + 4))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    // Zed-style Axis Lock & Ongoing Scroll Filter
    private enum ScrollAxis {
        case vertical
        case horizontal
    }
    private var scrollLockAxis: ScrollAxis? = nil
    private var lastScrollEventTime: Date = .distantPast

    public override func scrollWheel(with event: NSEvent) {
        let mult: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 24.0
        var dy = event.scrollingDeltaY * mult
        var dx = event.scrollingDeltaX * mult

        let now = Date()
        let timeSinceLastEvent = now.timeIntervalSince(lastScrollEventTime)
        lastScrollEventTime = now

        let isNewGesture = event.phase == .began || event.phase == .mayBegin || timeSinceLastEvent > 0.20
        let absX = abs(dx)
        let absY = abs(dy)

        if isNewGesture {
            // Determine dominant direction at start of gesture (Zed style)
            if absY >= absX {
                scrollLockAxis = .vertical
            } else {
                scrollLockAxis = .horizontal
            }
        } else if max(absX, absY) >= 6.0 {
            // Check if user deliberately switched direction with strong intent (>1.9x threshold)
            let unlockPercent: CGFloat = 1.9
            switch scrollLockAxis {
            case .vertical:
                if absX > absY && absX >= absY * unlockPercent {
                    scrollLockAxis = .horizontal
                }
            case .horizontal:
                if absY > absX && absY >= absX * unlockPercent {
                    scrollLockAxis = .vertical
                }
            case .none:
                break
            }
        }

        // Apply axis lock to completely eliminate accidental diagonal drifting
        switch scrollLockAxis {
        case .vertical:
            dx = 0
        case .horizontal:
            dy = 0
        case .none:
            break
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollLockAxis = nil
        }

        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        let maxScrollX = max(0, totalDocumentWidth - bounds.width)

        scrollOffsetY = max(0, min(maxScrollY, scrollOffsetY - dy))
        scrollOffsetX = max(0, min(maxScrollX, scrollOffsetX - dx))

        showScrollbarsWithAutohide()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateLayout()
    }

    public func invalidateLayout() {
        guard let displayMap = displayMap else {
            totalDocumentHeight = 0
            totalDocumentWidth = 0
            needsDisplay = true
            return
        }

        var totalHeight: CGFloat = 0
        var maxLineChars: Int = 80
        for line in displayMap.displayLines {
            switch line {
            case .excerptHeader:
                totalHeight += excerptHeaderHeight
            case .code(let info):
                totalHeight += lineHeight
                maxLineChars = max(maxLineChars, info.text.count)
            case .foldGap:
                totalHeight += foldGapHeight
            case .inlineComment:
                totalHeight += commentHeight
            }
        }
        totalHeight += 8 // Clean minimal 8px margin at bottom (no empty void)

        let charWidth = font.pointSize * 0.75
        let neededWidth = gutterWidth + CGFloat(maxLineChars) * charWidth + 100

        totalDocumentHeight = totalHeight
        totalDocumentWidth = max(bounds.width, neededWidth)

        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        let maxScrollX = max(0, totalDocumentWidth - bounds.width)
        scrollOffsetY = max(0, min(maxScrollY, scrollOffsetY))
        scrollOffsetX = max(0, min(maxScrollX, scrollOffsetX))

        needsDisplay = true
    }

    private func ensureCursorVisible() {
        guard let displayMap = displayMap else { return }
        var currentY: CGFloat = 0
        for line in displayMap.displayLines {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            if case .code(let info) = line, info.multiBufferRow == cursorPoint.row {
                let cursorY = currentY
                let margin: CGFloat = 30
                if cursorY < scrollOffsetY + margin {
                    scrollOffsetY = max(0, cursorY - margin)
                } else if cursorY + height > scrollOffsetY + bounds.height - margin {
                    let maxScrollY = max(0, totalDocumentHeight - bounds.height)
                    scrollOffsetY = min(maxScrollY, cursorY + height - bounds.height + margin)
                }
                return
            }
            currentY += height
        }
    }

    // MARK: - Cursor Blinking

    private func startCursorBlink() {
        cursorTimer?.invalidate()
        isCursorVisible = true
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isKeyWindow == true else { return }
            self.isCursorVisible.toggle()
            self.needsDisplay = true
        }
    }

    private func resetCursorBlink() {
        isCursorVisible = true
        startCursorBlink()
    }

    private func notifyCursorChange() {
        guard let mb = displayMap?.multiBuffer else { return }
        let loc = mb.location(for: cursorPoint)
        delegate?.editorDidChangeCursor(location: loc, point: cursorPoint)
    }

    // MARK: - Virtualized Rendering Engine

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let displayMap = displayMap else {
            theme.background.setFill()
            dirtyRect.fill()
            return
        }

        context.saveGState()
        context.clip(to: bounds)

        // 1. Draw Canvas Background
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        // 2. Pass 1: Draw Code Lines (content that scrolls horizontally under gutter)
        var currentY: CGFloat = 0
        let visibleMinY = scrollOffsetY
        let visibleMaxY = scrollOffsetY + bounds.height
        let lineWidth = max(bounds.width + scrollOffsetX, totalDocumentWidth)

        for (lineIdx, line) in displayMap.displayLines.enumerated() {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            let lineMinY = currentY
            currentY += height

            if lineMinY > visibleMaxY { break }
            guard lineMinY + height >= visibleMinY else { continue }

            let screenLineFrame = CGRect(
                x: -scrollOffsetX,
                y: lineMinY - scrollOffsetY,
                width: lineWidth,
                height: height
            )

            if case .code(let info) = line {
                drawCodeLine(info: info, lineIdx: lineIdx, in: screenLineFrame, context: context)
            }
        }

        // 3. Pass 2: Draw Sticky Gutters, Excerpt Headers, Fold Gaps & Comments (Sticky UI)
        currentY = 0
        for (lineIdx, line) in displayMap.displayLines.enumerated() {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            let lineMinY = currentY
            currentY += height

            if lineMinY > visibleMaxY { break }
            guard lineMinY + height >= visibleMinY else { continue }

            let screenY = lineMinY - scrollOffsetY

            switch line {
            case .excerptHeader(let info):
                let headerFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawExcerptHeader(info: info, in: headerFrame, context: context)

            case .code(let info):
                let gutterRect = CGRect(x: 0, y: screenY, width: gutterWidth, height: height)
                // Draw gutter cell background & border
                context.setFillColor(theme.gutterBackground.cgColor)
                context.fill(gutterRect)
                context.setStrokeColor(theme.excerptHeaderBorder.withAlphaComponent(0.4).cgColor)
                context.setLineWidth(1.0)
                context.strokeLineSegments(between: [
                    CGPoint(x: gutterWidth, y: screenY),
                    CGPoint(x: gutterWidth, y: screenY + height)
                ])
                drawGutter(for: info, lineIdx: lineIdx, in: gutterRect, context: context)

            case .foldGap(let info):
                let gapFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawFoldGap(info: info, lineIdx: lineIdx, in: gapFrame, context: context)

            case .inlineComment(let info):
                let commentFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawInlineComment(info: info, in: commentFrame, context: context)
            }
        }

        // 4. Draw Overlay Scrollbars with Auto-Hide Fade (Vertical & Horizontal)
        if scrollbarAlpha > 0.01 {
            let thumbColor = theme.gutterForeground.withAlphaComponent(0.45 * scrollbarAlpha)

            if totalDocumentHeight > bounds.height {
                let maxScrollY = totalDocumentHeight - bounds.height
                let progress = maxScrollY > 0 ? (scrollOffsetY / maxScrollY) : 0
                let thumbHeight = max(30, (bounds.height / totalDocumentHeight) * bounds.height)
                let thumbY = progress * (bounds.height - thumbHeight)
                let thumbRect = CGRect(x: bounds.width - 7, y: thumbY, width: 4, height: thumbHeight)

                context.setFillColor(thumbColor.cgColor)
                let path = CGPath(roundedRect: thumbRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                context.addPath(path)
                context.fillPath()
            }

            if totalDocumentWidth > bounds.width {
                let maxScrollX = totalDocumentWidth - bounds.width
                let progress = maxScrollX > 0 ? (scrollOffsetX / maxScrollX) : 0
                let scrollableWidth = bounds.width - gutterWidth - 10
                let thumbWidth = max(40, (scrollableWidth / totalDocumentWidth) * scrollableWidth)
                let thumbX = gutterWidth + progress * (scrollableWidth - thumbWidth)
                let thumbRect = CGRect(x: thumbX, y: bounds.height - 6, width: thumbWidth, height: 4)

                context.setFillColor(thumbColor.cgColor)
                let path = CGPath(roundedRect: thumbRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                context.addPath(path)
                context.fillPath()
            }
        }

        context.restoreGState()
    }

    // MARK: - Excerpt Header Drawing

    private func drawExcerptHeader(info: ExcerptHeaderInfo, in rect: CGRect, context: CGContext) {
        let fullWidth = bounds.width
        let headerRect = CGRect(x: 0, y: rect.minY, width: fullWidth, height: rect.height)

        // Header background spanning sticky width
        context.setFillColor(theme.excerptHeaderBackground.cgColor)
        context.fill(headerRect)

        // Top & Bottom border
        context.setStrokeColor(theme.excerptHeaderBorder.cgColor)
        context.setLineWidth(1.0)
        context.strokeLineSegments(between: [
            CGPoint(x: 0, y: rect.minY), CGPoint(x: fullWidth, y: rect.minY),
            CGPoint(x: 0, y: rect.maxY), CGPoint(x: fullWidth, y: rect.maxY)
        ])

        // File Status Stripe on the left of header
        let stripeColor: NSColor
        switch info.fileStatus {
        case .added: stripeColor = theme.diffAddedGutter
        case .deleted: stripeColor = theme.diffDeletedGutter
        default: stripeColor = theme.diffModifiedGutter
        }
        context.setFillColor(stripeColor.cgColor)
        context.fill(CGRect(x: 0, y: rect.minY, width: 4, height: rect.height))

        // Title and Breadcrumbs Text
        let pathAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: theme.foreground
        ]
        let pathStr = NSAttributedString(string: info.filePath, attributes: pathAttr)
        let ctLine = CTLineCreateWithAttributedString(pathStr)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 16, y: rect.minY + 22)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Diff Badges (+N -M)
        let badgeX: CGFloat = min(bounds.width - 150, 24 + CGFloat(info.filePath.count * 8))
        if info.additions > 0 {
            let addAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: theme.diffAddedGutter
            ]
            let addStr = NSAttributedString(string: "+\(info.additions)", attributes: addAttr)
            let addLine = CTLineCreateWithAttributedString(addStr)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: badgeX, y: rect.minY + 22)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(addLine, context)
            context.restoreGState()
        }

        if info.deletions > 0 {
            let delAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: theme.diffDeletedGutter
            ]
            let delStr = NSAttributedString(string: "-\(info.deletions)", attributes: delAttr)
            let delLine = CTLineCreateWithAttributedString(delStr)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: badgeX + 45, y: rect.minY + 22)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(delLine, context)
            context.restoreGState()
        }

        // Expand All / Collapse button text on right
        let actionStr = info.isCollapsed ? "Expand" : "Collapse"
        let actionAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.gutterForeground
        ]
        let actLine = CTLineCreateWithAttributedString(NSAttributedString(string: actionStr, attributes: actionAttr))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: bounds.width - 70, y: rect.minY + 22)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(actLine, context)
        context.restoreGState()
    }

    // MARK: - Code Line Drawing

    private func drawCodeLine(info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        let isCurrentCursorLine = (info.multiBufferRow == cursorPoint.row)
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
        let codeStartX = rect.minX + gutterWidth + 12
        let attrText = SyntaxHighlighter.shared.highlight(
            line: info.text,
            language: info.language,
            font: font,
            theme: theme
        )
        let ctLine = LineLayoutCache.shared.getOrCreateCTLine(attributedString: attrText)

        // Word Diff Highlight Rectangles
        if !info.wordDiffRanges.isEmpty {
            let wordBgColor = (info.diffKind == .added) ? theme.diffAddedWordHighlight : theme.diffDeletedWordHighlight
            context.setFillColor(wordBgColor.cgColor)
            for range in info.wordDiffRanges {
                let startX = LineLayoutCache.shared.xOffset(in: ctLine, for: range.lowerBound)
                let endX = LineLayoutCache.shared.xOffset(in: ctLine, for: range.upperBound)
                let wordRect = CGRect(x: codeStartX + startX, y: rect.minY + 2, width: max(4, endX - startX), height: rect.height - 4)
                let rounded = CGPath(roundedRect: wordRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(rounded)
                context.fillPath()
            }
        }

        // Text Selection Rectangles
        if hasSelection, let selRange = normalizedSelectionRange(),
           info.multiBufferRow >= selRange.lowerBound.row && info.multiBufferRow <= selRange.upperBound.row {
            let startCol = (info.multiBufferRow == selRange.lowerBound.row) ? selRange.lowerBound.column : 0
            let endCol = (info.multiBufferRow == selRange.upperBound.row) ? selRange.upperBound.column : info.text.count
            let startX = LineLayoutCache.shared.xOffset(in: ctLine, for: startCol)
            let endX = LineLayoutCache.shared.xOffset(in: ctLine, for: max(startCol, endCol))
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
        if isCurrentCursorLine && isCursorVisible && isEditable {
            let cursorX = codeStartX + LineLayoutCache.shared.xOffset(in: ctLine, for: cursorPoint.column)
            let cursorRect = CGRect(x: cursorX, y: rect.minY + 2, width: 2, height: rect.height - 4)
            context.setFillColor(theme.foreground.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Gutter Drawing

    private func drawGutter(for info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        // Diff Status Left Bar
        if info.diffKind == .added {
            context.setFillColor(theme.diffAddedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        } else if info.diffKind == .deleted {
            context.setFillColor(theme.diffDeletedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        }

        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        // Old Line Number (left column: x = 6..42)
        if let oldNum = info.oldLineNumber {
            let color = (info.diffKind == .deleted) ? theme.diffDeletedGutter : theme.gutterForeground
            let str = NSAttributedString(string: String(format: "%3d", oldNum), attributes: [
                .font: numFont,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(str)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 8, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        // New Line Number (middle column: x = 44..76)
        if let newNum = info.newLineNumber {
            let color = (info.diffKind == .added) ? theme.diffAddedGutter : theme.gutterForeground
            let str = NSAttributedString(string: String(format: "%3d", newNum), attributes: [
                .font: numFont,
                .foregroundColor: color
            ])
            let line = CTLineCreateWithAttributedString(str)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 44, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        // Diff Symbol (+ / -) on right of gutter
        if info.diffKind != .unchanged {
            let symbol = (info.diffKind == .added) ? "+" : "-"
            let symColor = (info.diffKind == .added) ? theme.diffAddedGutter : theme.diffDeletedGutter
            let symStr = NSAttributedString(string: symbol, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: symColor
            ])
            let symLine = CTLineCreateWithAttributedString(symStr)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 80, y: rect.minY + fontAscent + 2)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(symLine, context)
            context.restoreGState()
        }

        // Hover '+' button to add code review comment
        if hoveredGutterLineIndex == lineIdx {
            let btnRect = CGRect(x: 78, y: rect.minY + 3, width: 16, height: 16)
            context.setFillColor(theme.diffModifiedGutter.cgColor)
            let path = CGPath(roundedRect: btnRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.fillPath()

            let plusStr = NSAttributedString(string: "+", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.white
            ])
            let plusLine = CTLineCreateWithAttributedString(plusStr)
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 82, y: rect.minY + 14)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(plusLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Fold Gap Drawing

    private func drawFoldGap(info: DisplayFoldGapInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        context.setFillColor(theme.gutterBackground.cgColor)
        context.fill(rect)

        let label = "... \(info.hiddenCount) hidden lines  [Expand +10] ..."
        let str = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.foldPlaceholderForeground
        ])
        let line = CTLineCreateWithAttributedString(str)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: gutterWidth + 24, y: rect.minY + 18)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Inline Comment Drawing

    private func drawInlineComment(info: DisplayCommentInfo, in rect: CGRect, context: CGContext) {
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

    // MARK: - Mouse & Click Interaction

    public override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let docY = loc.y + scrollOffsetY
        guard let displayMap = displayMap else { return }

        var currentY: CGFloat = 0
        var foundGutterHover: Int? = nil

        for (idx, line) in displayMap.displayLines.enumerated() {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            let lineMinY = currentY
            currentY += height

            if lineMinY > docY {
                break
            }

            if docY >= lineMinY && docY <= currentY {
                if case .code = line, loc.x < gutterWidth {
                    foundGutterHover = idx
                }
                break
            }
        }

        if hoveredGutterLineIndex != foundGutterHover {
            hoveredGutterLineIndex = foundGutterHover
            needsDisplay = true
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        guard let displayMap = displayMap else { return }

        var currentY: CGFloat = 0
        for line in displayMap.displayLines {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            let lineMinY = currentY
            currentY += height

            if lineMinY > docY {
                break
            }

            if docY >= lineMinY && docY <= currentY {
                switch line {
                case .excerptHeader(let header):
                    if screenPoint.x > bounds.width - 80 {
                        displayMap.multiBuffer.toggleCollapse(at: header.excerptIndex)
                        displayMap.rebuild()
                        invalidateLayout()
                        return
                    }
                case .foldGap(let gap):
                    displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: gap.isTopGap ? 10 : 0, down: gap.isTopGap ? 0 : 10)
                    displayMap.rebuild()
                    invalidateLayout()
                    return
                case .code(let codeInfo):
                    if screenPoint.x < gutterWidth {
                        // Click in gutter on '+' button
                        let targetLine = codeInfo.newLineNumber ?? codeInfo.oldLineNumber ?? (codeInfo.bufferRow + 1)
                        if let loc = displayMap.multiBuffer.location(for: codeInfo.multiBufferRow) {
                            delegate?.editorDidRequestAddComment(filePath: loc.filePath, lineNumber: targetLine)
                        }
                        return
                    } else {
                        // Position cursor in code
                        let text = codeInfo.text
                        let attr = SyntaxHighlighter.shared.highlight(line: text, language: codeInfo.language, font: font, theme: theme)
                        let ctLine = LineLayoutCache.shared.getOrCreateCTLine(attributedString: attr)
                        let xOffset = max(0, docX - (gutterWidth + 12))
                        let charIdx = LineLayoutCache.shared.characterIndex(in: ctLine, at: xOffset)
                        cursorPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: min(text.count, charIdx))
                        selectionAnchor = cursorPoint
                        needsDisplay = true
                        return
                    }
                case .inlineComment:
                    break
                }
                break
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        guard let displayMap = displayMap else { return }

        var currentY: CGFloat = 0
        for line in displayMap.displayLines {
            let height: CGFloat
            switch line {
            case .excerptHeader: height = excerptHeaderHeight
            case .code: height = lineHeight
            case .foldGap: height = foldGapHeight
            case .inlineComment: height = commentHeight
            }

            let lineMinY = currentY
            currentY += height

            if lineMinY > docY {
                break
            }

            if docY >= lineMinY && docY <= currentY {
                if case .code(let codeInfo) = line {
                    let text = codeInfo.text
                    let attr = SyntaxHighlighter.shared.highlight(line: text, language: codeInfo.language, font: font, theme: theme)
                    let ctLine = LineLayoutCache.shared.getOrCreateCTLine(attributedString: attr)
                    let xOffset = max(0, docX - (gutterWidth + 12))
                    let charIdx = LineLayoutCache.shared.characterIndex(in: ctLine, at: xOffset)
                    cursorPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: min(text.count, charIdx))
                    needsDisplay = true
                }
                break
            }
        }
    }

    // MARK: - Keyboard & Text Editing

    public override func keyDown(with event: NSEvent) {
        guard displayMap != nil else { return }

        let isShift = event.modifierFlags.contains(.shift)
        let isCmd = event.modifierFlags.contains(.command)

        if isCmd {
            switch event.charactersIgnoringModifiers {
            case "z":
                if isShift {
                    redo(nil)
                } else {
                    undo(nil)
                }
                return
            case "a":
                selectAll(nil)
                return
            case "c":
                copy(nil)
                return
            case "x":
                cut(nil)
                return
            case "v":
                paste(nil)
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 123: // Left Arrow
            moveCursorLeft(expandSelection: isShift)
        case 124: // Right Arrow
            moveCursorRight(expandSelection: isShift)
        case 126: // Up Arrow
            moveCursorUp(expandSelection: isShift)
        case 125: // Down Arrow
            moveCursorDown(expandSelection: isShift)
        case 51: // Backspace
            guard isEditable else { return }
            deleteBackward(nil)
        case 117: // Forward Delete
            guard isEditable else { return }
            deleteForward(nil)
        case 36: // Enter
            guard isEditable else { return }
            insertNewline(nil)
        case 48: // Tab
            guard isEditable else { return }
            insertTab(nil)
        default:
            if let chars = event.characters, !chars.isEmpty, isEditable {
                insertText(chars, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func moveCursorLeft(expandSelection: Bool) {
        guard let mb = displayMap?.multiBuffer else { return }
        if cursorPoint.column > 0 {
            cursorPoint.column -= 1
        } else if cursorPoint.row > 0 {
            cursorPoint.row -= 1
            cursorPoint.column = mb.lineLength(at: cursorPoint.row)
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorRight(expandSelection: Bool) {
        guard let mb = displayMap?.multiBuffer else { return }
        let len = mb.lineLength(at: cursorPoint.row)
        if cursorPoint.column < len {
            cursorPoint.column += 1
        } else if cursorPoint.row < mb.lineCount - 1 {
            cursorPoint.row += 1
            cursorPoint.column = 0
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorUp(expandSelection: Bool) {
        guard let mb = displayMap?.multiBuffer else { return }
        if cursorPoint.row > 0 {
            cursorPoint.row -= 1
            cursorPoint.column = min(cursorPoint.column, mb.lineLength(at: cursorPoint.row))
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorDown(expandSelection: Bool) {
        guard let mb = displayMap?.multiBuffer else { return }
        if cursorPoint.row < mb.lineCount - 1 {
            cursorPoint.row += 1
            cursorPoint.column = min(cursorPoint.column, mb.lineLength(at: cursorPoint.row))
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let displayMap = displayMap, let text = string as? String else { return }
        let mb = displayMap.multiBuffer

        let rangeToReplace = normalizedSelectionRange() ?? (cursorPoint..<cursorPoint)
        let affectedRows = rangeToReplace.lowerBound.row..<(rangeToReplace.upperBound.row + 1)
        if displayMap.isDeleted(rowRange: affectedRows) {
            NSSound.beep()
            return
        }

        let newRange = mb.replace(range: rangeToReplace, with: text)
        cursorPoint = newRange.upperBound
        selectionAnchor = cursorPoint
        displayMap.rebuild()
        invalidateLayout()
    }

    public override func deleteBackward(_ sender: Any?) {
        guard let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer

        if let sel = normalizedSelectionRange() {
            let affectedRows = sel.lowerBound.row..<(sel.upperBound.row + 1)
            if displayMap.isDeleted(rowRange: affectedRows) {
                NSSound.beep()
                return
            }
            let pt = mb.delete(range: sel)
            cursorPoint = pt
            selectionAnchor = cursorPoint
        } else if cursorPoint.column > 0 {
            if displayMap.isDeleted(multiBufferRow: cursorPoint.row) {
                NSSound.beep()
                return
            }
            let start = MultiBufferPoint(row: cursorPoint.row, column: cursorPoint.column - 1)
            let pt = mb.delete(range: start..<cursorPoint)
            cursorPoint = pt
            selectionAnchor = cursorPoint
        } else if cursorPoint.row > 0 {
            if displayMap.isDeleted(multiBufferRow: cursorPoint.row) || displayMap.isDeleted(multiBufferRow: cursorPoint.row - 1) {
                NSSound.beep()
                return
            }
            let prevLen = mb.lineLength(at: cursorPoint.row - 1)
            let start = MultiBufferPoint(row: cursorPoint.row - 1, column: prevLen)
            let pt = mb.delete(range: start..<cursorPoint)
            cursorPoint = pt
            selectionAnchor = cursorPoint
        }
        displayMap.rebuild()
        invalidateLayout()
    }

    public override func deleteForward(_ sender: Any?) {
        guard let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer

        if let sel = normalizedSelectionRange() {
            let affectedRows = sel.lowerBound.row..<(sel.upperBound.row + 1)
            if displayMap.isDeleted(rowRange: affectedRows) {
                NSSound.beep()
                return
            }
            let pt = mb.delete(range: sel)
            cursorPoint = pt
            selectionAnchor = cursorPoint
        } else {
            if displayMap.isDeleted(multiBufferRow: cursorPoint.row) {
                NSSound.beep()
                return
            }
            let len = mb.lineLength(at: cursorPoint.row)
            if cursorPoint.column < len {
                let end = MultiBufferPoint(row: cursorPoint.row, column: cursorPoint.column + 1)
                let pt = mb.delete(range: cursorPoint..<end)
                cursorPoint = pt
                selectionAnchor = cursorPoint
            }
        }
        displayMap.rebuild()
        invalidateLayout()
    }

    public override func insertNewline(_ sender: Any?) {
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Undo & Redo

    @IBAction public func undo(_ sender: Any?) {
        guard let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popUndo() {
            for edit in transaction.edits.reversed() {
                if let buf = mb.buffer(for: edit.bufferId) {
                    buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.oldText)
                    if let base = mb.baseDirectory {
                        try? buf.saveToFile(baseDirectory: base)
                    }
                }
            }
            if let sel = transaction.selectionBefore {
                cursorPoint = sel.lowerBound
                selectionAnchor = sel.upperBound
            }
            displayMap.rebuild()
            invalidateLayout()
        }
    }

    @IBAction public func redo(_ sender: Any?) {
        guard let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popRedo() {
            for edit in transaction.edits {
                if let buf = mb.buffer(for: edit.bufferId) {
                    buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.newText)
                    if let base = mb.baseDirectory {
                        try? buf.saveToFile(baseDirectory: base)
                    }
                }
            }
            displayMap.rebuild()
            invalidateLayout()
        }
    }

    // MARK: - Selection & Clipboard

    private func normalizedSelectionRange() -> Range<MultiBufferPoint>? {
        guard let anchor = selectionAnchor, anchor != cursorPoint else { return nil }
        return min(anchor, cursorPoint)..<max(anchor, cursorPoint)
    }

    public override func selectAll(_ sender: Any?) {
        guard let mb = displayMap?.multiBuffer, mb.lineCount > 0 else { return }
        selectionAnchor = .zero
        let lastRow = mb.lineCount - 1
        cursorPoint = MultiBufferPoint(row: lastRow, column: mb.lineLength(at: lastRow))
        needsDisplay = true
    }

    public func copy(_ sender: Any?) {
        guard let mb = displayMap?.multiBuffer, let sel = normalizedSelectionRange() else { return }
        var copiedLines: [String] = []
        for r in sel.lowerBound.row...sel.upperBound.row {
            let line = mb.line(at: r)
            let start = (r == sel.lowerBound.row) ? sel.lowerBound.column : 0
            let end = (r == sel.upperBound.row) ? sel.upperBound.column : line.count
            let sub = String(line.prefix(end).suffix(max(0, end - start)))
            copiedLines.append(sub)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedLines.joined(separator: "\n"), forType: .string)
    }

    public func cut(_ sender: Any?) {
        copy(sender)
        deleteBackward(sender)
    }

    public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - NSTextInputClient Stubs

    public func hasMarkedText() -> Bool { false }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    public func unmarkText() {}
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    public override func doCommand(by selector: Selector) {}
}
