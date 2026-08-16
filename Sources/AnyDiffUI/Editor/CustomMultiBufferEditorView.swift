import Foundation
import AppKit
import CoreText
import AnyDiffCore

public protocol CustomMultiBufferEditorDelegate: AnyObject {
    func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint)
    func editorDidRequestAddComment(filePath: String, lineNumber: Int)
}

/// A high-performance, virtualized MultiBuffer Code Reviewer & Editor View built with CoreText
public final class CustomMultiBufferEditorView: NSView, NSTextInputClient, NSUserInterfaceValidations {
    public weak var delegate: CustomMultiBufferEditorDelegate?

    public var displayMap: DisplayMap? {
        didSet {
            invalidateLayout()
        }
    }

    public var theme: Theme = .zedGray {
        didSet {
            // CTLine stores resolved foreground colors, so cached lines must be
            // discarded when the palette changes (including system appearance changes).
            LineLayoutCache.shared.clear()
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
    public private(set) var gutterWidth: CGFloat = 58
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

    // Selection Granularity Mode (1-click char, 2-click word, 3-click line)
    private enum SelectionGranularity {
        case character
        case word(initialStart: Int, initialEnd: Int, initialRow: MultiBufferRow)
        case line(initialRow: MultiBufferRow)
    }
    private var activeSelectionGranularity: SelectionGranularity = .character

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
        cachedFileSections = nil
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

        clampCursorToValidBounds()
        needsDisplay = true
    }

    public func clampCursorToValidBounds() {
        guard let dm = displayMap, dm.codeLineCount > 0 else { return }
        let validRows = dm.codeLines.map(\.multiBufferRow)
        var row = cursorPoint.row
        if !validRows.contains(row) {
            if let closest = validRows.min(by: { abs($0 - row) < abs($1 - row) }) {
                row = closest
            } else {
                row = dm.minCodeRow
            }
        }
        let maxCol = dm.lineLength(at: row)
        let col = max(0, min(cursorPoint.column, maxCol))
        let clamped = MultiBufferPoint(row: row, column: col)
        if clamped != cursorPoint {
            cursorPoint = clamped
        }
        if let anchor = selectionAnchor {
            var anchorRow = anchor.row
            if !validRows.contains(anchorRow) {
                if let closest = validRows.min(by: { abs($0 - anchorRow) < abs($1 - anchorRow) }) {
                    anchorRow = closest
                } else {
                    anchorRow = dm.minCodeRow
                }
            }
            let anchorMaxCol = dm.lineLength(at: anchorRow)
            let anchorCol = max(0, min(anchor.column, anchorMaxCol))
            selectionAnchor = MultiBufferPoint(row: anchorRow, column: anchorCol)
        }
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
        guard let dm = displayMap else { return }
        let loc = dm.excerptLocation(for: cursorPoint)
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
                context.setFillColor(theme.background.cgColor)
                context.fill(gutterRect)
                drawGutter(for: info, lineIdx: lineIdx, in: gutterRect, context: context)

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

    // MARK: - Pixel-Perfect Viewport Scroll Anchoring

    private func preserveScreenPosition(ofCodeRow codeRow: Int, originalScreenY: CGFloat) {
        guard let dm = displayMap else { return }
        dm.rebuild()
        invalidateLayout()

        var newAbsY: CGFloat = 0
        var found = false
        for line in dm.displayLines {
            if case .code(let info) = line, info.multiBufferRow == codeRow {
                found = true
                break
            }
            switch line {
            case .excerptHeader: newAbsY += excerptHeaderHeight
            case .code: newAbsY += lineHeight
            case .foldGap: newAbsY += foldGapHeight
            case .inlineComment: newAbsY += commentHeight
            }
        }

        if found {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            let targetScrollY = newAbsY - originalScreenY
            scrollOffsetY = max(0, min(maxScrollY, targetScrollY))
        }
        needsDisplay = true
    }

    // MARK: - Sticky Excerpt Header Computation

    private struct FileSection {
        let info: ExcerptHeaderInfo
        let headerMinY: CGFloat
        var contentMaxY: CGFloat
    }

    private var cachedFileSections: [FileSection]? = nil

    private func computeFileSections() -> [FileSection] {
        if let cached = cachedFileSections { return cached }
        guard let displayMap = displayMap else { return [] }
        var sections: [FileSection] = []
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

            switch line {
            case .excerptHeader(let info):
                if let lastIdx = sections.indices.last {
                    sections[lastIdx].contentMaxY = lineMinY
                }
                sections.append(FileSection(info: info, headerMinY: lineMinY, contentMaxY: currentY))
            default:
                if let lastIdx = sections.indices.last {
                    sections[lastIdx].contentMaxY = currentY
                }
            }
        }
        self.cachedFileSections = sections
        return sections
    }

    private func currentStickyHeader() -> (info: ExcerptHeaderInfo, frame: CGRect)? {
        guard scrollOffsetY > 0 else { return nil }
        let sections = computeFileSections()
        for (i, section) in sections.enumerated() {
            // Check if scrollOffsetY is within this file section and past its original header position
            if scrollOffsetY > section.headerMinY && scrollOffsetY < section.contentMaxY {
                // If the entire section is just the header (e.g. collapsed), no sticky needed
                guard section.contentMaxY - section.headerMinY > excerptHeaderHeight else { continue }

                let nextHeaderMinY: CGFloat? = (i + 1 < sections.count) ? sections[i + 1].headerMinY : nil

                // Pinned at y = 0, but if the next header is approaching, smoothly push this one up
                var stickyScreenY: CGFloat = 0
                if let nextMinY = nextHeaderMinY {
                    let nextScreenY = nextMinY - scrollOffsetY
                    if nextScreenY < excerptHeaderHeight {
                        stickyScreenY = nextScreenY - excerptHeaderHeight
                    }
                }
                let stickyFrame = CGRect(x: 0, y: stickyScreenY, width: bounds.width, height: excerptHeaderHeight)
                return (section.info, stickyFrame)
            }
        }
        return nil
    }

    // MARK: - Excerpt Header Drawing

    private func drawExcerptHeader(info: ExcerptHeaderInfo, in rect: CGRect, isSticky: Bool = false, context: CGContext) {
        let fullWidth = bounds.width
        let headerRect = CGRect(x: 0, y: rect.minY, width: fullWidth, height: rect.height)

        if isSticky {
            // Keep the sticky header separation subtle in both appearances.
            context.saveGState()
            let shadowColor = theme.isDark
                ? NSColor.black.withAlphaComponent(0.22)
                : NSColor.black.withAlphaComponent(0.08)
            context.setFillColor(shadowColor.cgColor)
            context.fill(CGRect(x: 0, y: rect.maxY, width: fullWidth, height: 1))
            context.restoreGState()
        }

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

        // Smooth rounded vector chevron indicator matching native macOS
        let cx: CGFloat = 16
        let cy: CGFloat = rect.minY + (rect.height / 2)
        context.saveGState()
        context.setStrokeColor(theme.gutterForeground.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if info.isCollapsed {
            // chevron.right (>)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 2.5, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx + 2.5, y: cy))
            context.addLine(to: CGPoint(x: cx - 2.5, y: cy + 4.5))
            context.strokePath()
        } else {
            // chevron.down (v)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 4.5, y: cy - 2.5))
            context.addLine(to: CGPoint(x: cx, y: cy + 2.5))
            context.addLine(to: CGPoint(x: cx + 4.5, y: cy - 2.5))
            context.strokePath()
        }
        context.restoreGState()

        // Title and Breadcrumbs Text
        let pathAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: theme.foreground
        ]
        let pathStr = NSAttributedString(string: info.filePath, attributes: pathAttr)
        let ctLine = CTLineCreateWithAttributedString(pathStr)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 28, y: rect.minY + 22)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Diff Badges (+N -M) floated to the right edge of header
        var rightBadgeX = bounds.width + scrollOffsetX - 20

        var delLine: CTLine?
        var delWidth: CGFloat = 0
        if info.deletions > 0 {
            let delAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: theme.diffDeletedGutter
            ]
            let delStr = NSAttributedString(string: "-\(info.deletions)", attributes: delAttr)
            let line = CTLineCreateWithAttributedString(delStr)
            delWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            delLine = line
        }

        var addLine: CTLine?
        var addWidth: CGFloat = 0
        if info.additions > 0 {
            let addAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: theme.diffAddedGutter
            ]
            let addStr = NSAttributedString(string: "+\(info.additions)", attributes: addAttr)
            let line = CTLineCreateWithAttributedString(addStr)
            addWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            addLine = line
        }

        if let delLine = delLine {
            rightBadgeX -= delWidth
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rightBadgeX, y: rect.minY + 22)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(delLine, context)
            context.restoreGState()
            rightBadgeX -= 12 // Spacing between + and - badges
        }

        if let addLine = addLine {
            rightBadgeX -= addWidth
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rightBadgeX, y: rect.minY + 22)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(addLine, context)
            context.restoreGState()
        }
    }

    // MARK: - Code Line Drawing

    private func drawCodeLine(info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
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
            let startX = LineLayoutCache.shared.xOffset(in: ctLine, for: min(info.text.count, max(0, startCol)))
            let endX = LineLayoutCache.shared.xOffset(in: ctLine, for: min(info.text.count, max(startCol, endCol)))
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
            let cursorX = codeStartX + LineLayoutCache.shared.xOffset(in: ctLine, for: clampedCol)
            let cursorRect = CGRect(x: cursorX, y: rect.minY + 2, width: 2, height: rect.height - 4)
            context.setFillColor(theme.diffModifiedGutter.cgColor)
            context.fill(cursorRect)
        }
    }

    // MARK: - Gutter Drawing

    private func drawGutter(for info: DisplayCodeLineInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        // Diff Status Left Bar (3px stripe on left edge)
        if info.diffKind == .added {
            context.setFillColor(theme.diffAddedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        } else if info.diffKind == .deleted {
            context.setFillColor(theme.diffDeletedGutter.cgColor)
            context.fill(CGRect(x: 0, y: rect.minY, width: 3, height: rect.height))
        }

        // Expand Excerpt Button (Zed Style) on the left
        if let expandInfo = info.expandInfo {
            let btnRect = CGRect(x: 4, y: rect.minY + (rect.height - 16) / 2, width: 16, height: 16)
            drawExpandButton(expandInfo: expandInfo, in: btnRect, isHovered: hoveredGutterLineIndex == lineIdx, context: context)
        }

        // Single Unified Line Number Column (Zed Style)
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

            let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let str = NSAttributedString(string: "\(num)", attributes: [
                .font: numFont,
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

    private func drawExpandButton(expandInfo: ExpandInfo, in btnRect: CGRect, isHovered: Bool, context: CGContext) {
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

    private func drawFoldGap(info: DisplayFoldGapInfo, lineIdx: Int, in rect: CGRect, context: CGContext) {
        context.setFillColor(theme.background.cgColor)
        context.fill(rect)

        let label = "⋯   \(info.hiddenCount) hidden lines   [Expand all]   ⋯"
        let str = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.foldPlaceholderForeground
        ])
        let line = CTLineCreateWithAttributedString(str)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: gutterWidth + 24, y: rect.minY + 16)
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

    // MARK: - Mouse Event Handling

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        let isShift = event.modifierFlags.contains(.shift)
        guard let displayMap = displayMap else { return }

        // 1. Check if user clicked on Sticky Excerpt Header
        if let (stickyInfo, stickyFrame) = currentStickyHeader(), stickyFrame.contains(screenPoint) {
            displayMap.multiBuffer.toggleCollapse(at: stickyInfo.excerptIndex)
            displayMap.rebuild()
            invalidateLayout()
            return
        }

        // 2. Search through visible display lines
        var currentY: CGFloat = 0
        var clickedInDocument = false

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
                clickedInDocument = true
                switch line {
                case .excerptHeader(let header):
                    displayMap.multiBuffer.toggleCollapse(at: header.excerptIndex)
                    displayMap.rebuild()
                    invalidateLayout()
                    return
                case .foldGap(let gap):
                    var anchorCodeRow: Int = 0
                    var anchorScreenY: CGFloat = 0
                    var curY: CGFloat = 0
                    for l in displayMap.displayLines {
                        if case .foldGap(let g) = l, g == gap { break }
                        if case .code(let c) = l {
                            anchorCodeRow = c.multiBufferRow
                            anchorScreenY = curY - scrollOffsetY
                        }
                        switch l {
                        case .excerptHeader: curY += excerptHeaderHeight
                        case .code: curY += lineHeight
                        case .foldGap: curY += foldGapHeight
                        case .inlineComment: curY += commentHeight
                        }
                    }

                    if gap.isTopGap {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: gap.hiddenCount, down: 0)
                    } else if gap.isBottomGap {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: gap.hiddenCount)
                    } else if let _ = gap.nextExcerptIndex {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: gap.hiddenCount)
                        displayMap.multiBuffer.mergeAdjacentExcerpts()
                    } else {
                        displayMap.multiBuffer.expandExcerpt(at: gap.excerptIndex, up: 0, down: gap.hiddenCount)
                    }

                    preserveScreenPosition(ofCodeRow: anchorCodeRow, originalScreenY: anchorScreenY)
                    return
                case .code(let codeInfo):
                    if screenPoint.x <= 22, let exp = codeInfo.expandInfo {
                        let isFullExpand = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
                        let lineScreenY = lineMinY - scrollOffsetY
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
                        preserveScreenPosition(ofCodeRow: codeInfo.multiBufferRow, originalScreenY: lineScreenY)
                        return
                    } else if screenPoint.x < gutterWidth {
                        let targetPoint = MultiBufferPoint(row: codeInfo.multiBufferRow, column: 0)
                        activeSelectionGranularity = .character
                        selectionAnchor = targetPoint
                        cursorPoint = targetPoint
                        needsDisplay = true
                        return
                    } else {
                        // Position cursor in code
                        let text = codeInfo.text
                        let attr = SyntaxHighlighter.shared.highlight(line: text, language: codeInfo.language, font: font, theme: theme)
                        let ctLine = LineLayoutCache.shared.getOrCreateCTLine(attributedString: attr)
                        let xOffset = max(0, docX - (gutterWidth + 12))
                        let charIdx = LineLayoutCache.shared.characterIndex(in: ctLine, at: xOffset)
                        let col = max(0, min(text.count, charIdx))
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
                            if !isShift || selectionAnchor == nil {
                                selectionAnchor = targetPoint
                            }
                            cursorPoint = targetPoint
                        }
                        needsDisplay = true
                        return
                    }
                case .inlineComment:
                    break
                }
                break
            }
        }

        if !clickedInDocument {
            activeSelectionGranularity = .character
            if docY > currentY, let lastCode = displayMap.codeLines.last {
                let targetPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
                if !isShift || selectionAnchor == nil {
                    selectionAnchor = targetPoint
                }
                cursorPoint = targetPoint
                needsDisplay = true
            } else if docY < 0, let firstCode = displayMap.codeLines.first {
                let targetPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
                if !isShift || selectionAnchor == nil {
                    selectionAnchor = targetPoint
                }
                cursorPoint = targetPoint
                needsDisplay = true
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        guard let displayMap = displayMap else { return }

        var currentY: CGFloat = 0
        var handled = false

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
                    let col = max(0, min(text.count, charIdx))
                    let targetRow = codeInfo.multiBufferRow

                    switch activeSelectionGranularity {
                    case .character:
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
                    handled = true
                    needsDisplay = true
                }
                break
            }
        }

        if !handled {
            if docY > currentY, let lastCode = displayMap.codeLines.last {
                cursorPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
                needsDisplay = true
            } else if docY < 0, let firstCode = displayMap.codeLines.first {
                cursorPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
                needsDisplay = true
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        activeSelectionGranularity = .character
    }

    // MARK: - Word Boundary Utilities

    private func isWordChar(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    /// Finds exact word range for double-click selection without grabbing adjacent spaces or punctuation
    private func wordRange(in text: String, at index: Int) -> (start: Int, end: Int) {
        let chars = Array(text)
        guard !chars.isEmpty else { return (0, 0) }

        var targetIndex = min(index, chars.count - 1)
        if targetIndex < 0 { targetIndex = 0 }

        // If clicked at end of line / right after word char on space, adjust to the word char
        if targetIndex > 0 && index == chars.count && isWordChar(chars[targetIndex - 1]) {
            targetIndex = targetIndex - 1
        } else if targetIndex > 0 && chars[targetIndex].isWhitespace && isWordChar(chars[targetIndex - 1]) {
            targetIndex = targetIndex - 1
        }

        let char = chars[targetIndex]

        if isWordChar(char) {
            var start = targetIndex
            while start > 0 && isWordChar(chars[start - 1]) {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && isWordChar(chars[end]) {
                end += 1
            }
            return (start, end)
        } else if char.isWhitespace {
            var start = targetIndex
            while start > 0 && chars[start - 1].isWhitespace {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && chars[end].isWhitespace {
                end += 1
            }
            return (start, end)
        } else {
            // Punctuation / symbol
            var start = targetIndex
            while start > 0 && !isWordChar(chars[start - 1]) && !chars[start - 1].isWhitespace {
                start -= 1
            }
            var end = targetIndex
            while end < chars.count && !isWordChar(chars[end]) && !chars[end].isWhitespace {
                end += 1
            }
            return (start, end)
        }
    }

    private func findPreviousWordBoundary(in text: String, from index: Int) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty && index > 0 else { return 0 }
        var i = min(index, chars.count)
        while i > 0 && !isWordChar(chars[i - 1]) {
            i -= 1
        }
        while i > 0 && isWordChar(chars[i - 1]) {
            i -= 1
        }
        return max(0, i)
    }

    private func findNextWordBoundary(in text: String, from index: Int) -> Int {
        let chars = Array(text)
        guard !chars.isEmpty && index < chars.count else { return text.count }
        var i = max(0, index)
        while i < chars.count && !isWordChar(chars[i]) {
            i += 1
        }
        while i < chars.count && isWordChar(chars[i]) {
            i += 1
        }
        return min(chars.count, i)
    }

    // MARK: - Keyboard & Text Input (Cocoa Standard Key Binding Responding)

    public override func keyDown(with event: NSEvent) {
        guard let displayMap = displayMap else { return }

        // Shift + Enter (Expand Excerpt around current cursor location, matching Zed shortcut)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            let cursorRow = cursorPoint.row
            var currentScreenY: CGFloat = 0
            for line in displayMap.displayLines {
                if case .code(let c) = line, c.multiBufferRow == cursorRow {
                    break
                }
                switch line {
                case .excerptHeader: currentScreenY += excerptHeaderHeight
                case .code: currentScreenY += lineHeight
                case .foldGap: currentScreenY += foldGapHeight
                case .inlineComment: currentScreenY += commentHeight
                }
            }
            currentScreenY -= scrollOffsetY

            displayMap.multiBuffer.expandExcerptAt(point: cursorPoint, lines: 5, direction: .upAndDown)
            preserveScreenPosition(ofCodeRow: cursorRow, originalScreenY: currentScreenY)
            return
        }

        interpretKeyEvents([event])
    }

    public override func doCommand(by selector: Selector) {
        if responds(to: selector) {
            perform(selector, with: nil)
        } else {
            super.doCommand(by: selector)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "s" {
                _ = displayMap?.multiBuffer.flushImmediateSave()
                return true
            }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return hasSelection
        case #selector(paste(_:)):
            return isEditable
        case #selector(selectAll(_:)):
            return (displayMap?.codeLineCount ?? 0) > 0
        case #selector(undo(_:)):
            return displayMap?.multiBuffer.undoManager.canUndo ?? false
        case #selector(redo(_:)):
            return displayMap?.multiBuffer.undoManager.canRedo ?? false
        default:
            return true
        }
    }

    // MARK: - Standard Key Binding Selectors (NSStandardKeyBindingResponding)

    @objc public override func moveLeft(_ sender: Any?) {
        moveCursorLeft(expandSelection: false)
    }

    @objc public override func moveRight(_ sender: Any?) {
        moveCursorRight(expandSelection: false)
    }

    @objc public override func moveUp(_ sender: Any?) {
        moveCursorUp(expandSelection: false)
    }

    @objc public override func moveDown(_ sender: Any?) {
        moveCursorDown(expandSelection: false)
    }

    @objc public override func moveLeftAndModifySelection(_ sender: Any?) {
        moveCursorLeft(expandSelection: true)
    }

    @objc public override func moveRightAndModifySelection(_ sender: Any?) {
        moveCursorRight(expandSelection: true)
    }

    @objc public override func moveUpAndModifySelection(_ sender: Any?) {
        moveCursorUp(expandSelection: true)
    }

    @objc public override func moveDownAndModifySelection(_ sender: Any?) {
        moveCursorDown(expandSelection: true)
    }

    @objc public override func moveWordLeft(_ sender: Any?) {
        moveCursorWordLeft(expandSelection: false)
    }

    @objc public override func moveWordRight(_ sender: Any?) {
        moveCursorWordRight(expandSelection: false)
    }

    @objc public override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveCursorWordLeft(expandSelection: true)
    }

    @objc public override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveCursorWordRight(expandSelection: true)
    }

    @objc public override func moveToBeginningOfLine(_ sender: Any?) {
        moveCursorToLineStart(expandSelection: false)
    }

    @objc public override func moveToEndOfLine(_ sender: Any?) {
        moveCursorToLineEnd(expandSelection: false)
    }

    @objc public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        moveCursorToLineStart(expandSelection: true)
    }

    @objc public override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        moveCursorToLineEnd(expandSelection: true)
    }

    @objc public override func moveToBeginningOfDocument(_ sender: Any?) {
        moveCursorToDocumentStart(expandSelection: false)
    }

    @objc public override func moveToEndOfDocument(_ sender: Any?) {
        moveCursorToDocumentEnd(expandSelection: false)
    }

    @objc public override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursorToDocumentStart(expandSelection: true)
    }

    @objc public override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        moveCursorToDocumentEnd(expandSelection: true)
    }

    @objc public override func pageUp(_ sender: Any?) {
        pageUpMovement(expandSelection: false)
    }

    @objc public override func pageDown(_ sender: Any?) {
        pageDownMovement(expandSelection: false)
    }

    @objc public override func pageUpAndModifySelection(_ sender: Any?) {
        pageUpMovement(expandSelection: true)
    }

    @objc public override func pageDownAndModifySelection(_ sender: Any?) {
        pageDownMovement(expandSelection: true)
    }

    @objc public override func deleteWordBackward(_ sender: Any?) {
        guard isEditable, displayMap != nil else { return }
        if hasSelection {
            deleteBackward(sender)
            return
        }
        let oldCursor = cursorPoint
        moveCursorWordLeft(expandSelection: false)
        let newCursor = cursorPoint
        cursorPoint = oldCursor
        let range = min(newCursor, oldCursor)..<max(newCursor, oldCursor)
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    @objc public override func deleteWordForward(_ sender: Any?) {
        guard isEditable, displayMap != nil else { return }
        if hasSelection {
            deleteForward(sender)
            return
        }
        let oldCursor = cursorPoint
        moveCursorWordRight(expandSelection: false)
        let newCursor = cursorPoint
        cursorPoint = oldCursor
        let range = min(oldCursor, newCursor)..<max(oldCursor, newCursor)
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    @objc public override func deleteToBeginningOfLine(_ sender: Any?) {
        guard isEditable else { return }
        let oldCursor = cursorPoint
        let range = MultiBufferPoint(row: oldCursor.row, column: 0)..<oldCursor
        selectionAnchor = range.lowerBound
        cursorPoint = range.upperBound
        deleteBackward(sender)
    }

    private func moveCursorLeft(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        if cursorPoint.column > 0 {
            cursorPoint.column -= 1
        } else if let prevRow = dm.previousCodeRow(before: cursorPoint.row) {
            cursorPoint.row = prevRow
            cursorPoint.column = dm.lineLength(at: prevRow)
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorRight(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let currentLen = dm.lineLength(at: cursorPoint.row)
        if cursorPoint.column < currentLen {
            cursorPoint.column += 1
        } else if let nextRow = dm.nextCodeRow(after: cursorPoint.row) {
            cursorPoint.row = nextRow
            cursorPoint.column = 0
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorUp(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        if let prevRow = dm.previousCodeRow(before: cursorPoint.row) {
            cursorPoint.row = prevRow
            cursorPoint.column = min(cursorPoint.column, dm.lineLength(at: prevRow))
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorDown(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        if let nextRow = dm.nextCodeRow(after: cursorPoint.row) {
            cursorPoint.row = nextRow
            cursorPoint.column = min(cursorPoint.column, dm.lineLength(at: nextRow))
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorWordLeft(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        if cursorPoint.column > 0 {
            let line = dm.lineText(at: cursorPoint.row) ?? ""
            cursorPoint.column = findPreviousWordBoundary(in: line, from: cursorPoint.column)
        } else if let prevRow = dm.previousCodeRow(before: cursorPoint.row) {
            cursorPoint.row = prevRow
            cursorPoint.column = dm.lineLength(at: prevRow)
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorWordRight(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let line = dm.lineText(at: cursorPoint.row) ?? ""
        if cursorPoint.column < line.count {
            cursorPoint.column = findNextWordBoundary(in: line, from: cursorPoint.column)
        } else if let nextRow = dm.nextCodeRow(after: cursorPoint.row) {
            cursorPoint.row = nextRow
            cursorPoint.column = 0
        }
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorToLineStart(expandSelection: Bool) {
        cursorPoint.column = 0
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorToLineEnd(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        cursorPoint.column = dm.lineLength(at: cursorPoint.row)
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorToDocumentStart(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        cursorPoint = MultiBufferPoint(row: dm.minCodeRow, column: 0)
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func moveCursorToDocumentEnd(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let lastRow = dm.maxCodeRow
        cursorPoint = MultiBufferPoint(row: lastRow, column: dm.lineLength(at: lastRow))
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func pageUpMovement(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let linesPerPage = max(1, Int(bounds.height / lineHeight) - 2)
        var targetRow = cursorPoint.row
        for _ in 0..<linesPerPage {
            if let prev = dm.previousCodeRow(before: targetRow) {
                targetRow = prev
            } else {
                break
            }
        }
        cursorPoint.row = targetRow
        cursorPoint.column = min(cursorPoint.column, dm.lineLength(at: targetRow))
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    private func pageDownMovement(expandSelection: Bool) {
        guard let dm = displayMap else { return }
        let linesPerPage = max(1, Int(bounds.height / lineHeight) - 2)
        var targetRow = cursorPoint.row
        for _ in 0..<linesPerPage {
            if let next = dm.nextCodeRow(after: targetRow) {
                targetRow = next
            } else {
                break
            }
        }
        cursorPoint.row = targetRow
        cursorPoint.column = min(cursorPoint.column, dm.lineLength(at: targetRow))
        if !expandSelection { selectionAnchor = cursorPoint }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        guard let displayMap = displayMap else { return }
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        let mb = displayMap.multiBuffer

        let rangeToReplace = normalizedSelectionRange() ?? (cursorPoint..<cursorPoint)
        let affectedRows = rangeToReplace.lowerBound.row..<(rangeToReplace.upperBound.row + 1)
        if displayMap.isDeleted(rowRange: affectedRows) {
            NSSound.beep()
            return
        }

        guard let startLoc = displayMap.bufferLocation(for: rangeToReplace.lowerBound),
              let endLoc = displayMap.bufferLocation(for: rangeToReplace.upperBound),
              !startLoc.isDeleted && !endLoc.isDeleted else {
            NSSound.beep()
            return
        }

        let buf = startLoc.buffer
        let oldStart = min(startLoc.point, endLoc.point)
        let oldEnd = max(startLoc.point, endLoc.point)
        let oldExactText = (oldStart < oldEnd) ? buf.text(in: oldStart..<oldEnd) : ""

        let newBufRange = buf.replace(start: oldStart, end: oldEnd, with: text)

        let edit = TextEdit(
            bufferId: buf.id,
            range: oldStart..<newBufRange.upperBound,
            oldText: oldExactText,
            newText: text
        )
        let transaction = EditTransaction(
            edits: [edit],
            selectionBefore: rangeToReplace,
            selectionAfter: nil
        )
        mb.undoManager.push(transaction: transaction)

        mb.scheduleDebouncedSave(delayMs: 200)

        displayMap.rebuild()
        invalidateLayout()

        if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
            cursorPoint = newVisualPt
        } else {
            cursorPoint = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
        }
        selectionAnchor = cursorPoint
        needsDisplay = true
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
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        guard let loc = displayMap.bufferLocation(for: cursorPoint), !loc.isDeleted else {
            NSSound.beep()
            return
        }

        let buf = loc.buffer
        let bPt = loc.point

        if bPt.column > 0 {
            let start = BufferPoint(row: bPt.row, column: bPt.column - 1)
            let oldExact = buf.text(in: start..<bPt)
            let newRange = buf.replace(start: start, end: bPt, with: "")
            let edit = TextEdit(bufferId: buf.id, range: start..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)
            displayMap.rebuild()
            invalidateLayout()
            if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                cursorPoint = vPt
            } else {
                cursorPoint = MultiBufferPoint(row: cursorPoint.row, column: max(0, cursorPoint.column - 1))
            }
            selectionAnchor = cursorPoint
            needsDisplay = true
        } else if bPt.row > 0 {
            let prevLen = buf.lineLength(at: bPt.row - 1)
            let start = BufferPoint(row: bPt.row - 1, column: prevLen)
            let oldExact = buf.text(in: start..<bPt)
            let newRange = buf.replace(start: start, end: bPt, with: "")
            let edit = TextEdit(bufferId: buf.id, range: start..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)
            displayMap.rebuild()
            invalidateLayout()
            if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                cursorPoint = vPt
            } else {
                cursorPoint = MultiBufferPoint(row: max(0, cursorPoint.row - 1), column: prevLen)
            }
            selectionAnchor = cursorPoint
            needsDisplay = true
        }
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
            insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }

        guard let loc = displayMap.bufferLocation(for: cursorPoint), !loc.isDeleted else {
            NSSound.beep()
            return
        }

        let buf = loc.buffer
        let bPt = loc.point
        let lineLen = buf.lineLength(at: bPt.row)

        if bPt.column < lineLen {
            let end = BufferPoint(row: bPt.row, column: bPt.column + 1)
            let oldExact = buf.text(in: bPt..<end)
            let newRange = buf.replace(start: bPt, end: end, with: "")
            let edit = TextEdit(bufferId: buf.id, range: bPt..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)
            displayMap.rebuild()
            invalidateLayout()
            if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                cursorPoint = vPt
            }
            selectionAnchor = cursorPoint
            needsDisplay = true
        } else if bPt.row < buf.lineCount - 1 {
            let end = BufferPoint(row: bPt.row + 1, column: 0)
            let oldExact = buf.text(in: bPt..<end)
            let newRange = buf.replace(start: bPt, end: end, with: "")
            let edit = TextEdit(bufferId: buf.id, range: bPt..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)
            displayMap.rebuild()
            invalidateLayout()
            if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                cursorPoint = vPt
            }
            selectionAnchor = cursorPoint
            needsDisplay = true
        }
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
                }
            }
            mb.scheduleDebouncedSave(delayMs: 200)
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
                }
            }
            mb.scheduleDebouncedSave(delayMs: 200)
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
        guard let dm = displayMap, dm.codeLineCount > 0 else { return }
        let firstRow = dm.minCodeRow
        let lastRow = dm.maxCodeRow
        selectionAnchor = MultiBufferPoint(row: firstRow, column: 0)
        cursorPoint = MultiBufferPoint(row: lastRow, column: dm.lineLength(at: lastRow))
        needsDisplay = true
    }

    @objc @IBAction public func copy(_ sender: Any?) {
        guard let dm = displayMap, let sel = normalizedSelectionRange() else { return }
        var copiedLines: [String] = []
        for r in sel.lowerBound.row...sel.upperBound.row {
            guard let line = dm.lineText(at: r) else { continue }
            let start = (r == sel.lowerBound.row) ? sel.lowerBound.column : 0
            let end = (r == sel.upperBound.row) ? sel.upperBound.column : line.count
            let clampedStart = max(0, min(line.count, start))
            let clampedEnd = max(clampedStart, min(line.count, end))
            let startIndex = line.index(line.startIndex, offsetBy: clampedStart)
            let endIndex = line.index(line.startIndex, offsetBy: clampedEnd)
            copiedLines.append(String(line[startIndex..<endIndex]))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedLines.joined(separator: "\n"), forType: .string)
    }

    @objc @IBAction public func cut(_ sender: Any?) {
        copy(sender)
        deleteBackward(sender)
    }

    @objc @IBAction public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - NSTextInputClient Stubs

    public func hasMarkedText() -> Bool { false }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        insertText(string, replacementRange: replacementRange)
    }
    public func unmarkText() {}
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}
