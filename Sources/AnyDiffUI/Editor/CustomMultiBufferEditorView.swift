import Foundation
import AppKit
import CoreText
import Combine
import AnyDiffCore

public protocol CustomMultiBufferEditorDelegate: AnyObject {
    func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint)
    func editorDidRequestAddComment(filePath: String, lineNumber: Int)
}

/// A high-performance, virtualized MultiBuffer Code Reviewer & Editor View built with CoreText
public final class CustomMultiBufferEditorView: NSView, NSTextInputClient, NSUserInterfaceValidations {
    public weak var delegate: CustomMultiBufferEditorDelegate?
    private var displayMapCancellables = Set<AnyCancellable>()

    public var displayMap: DisplayMap? {
        didSet {
            displayMapCancellables.removeAll()
            displayMap?.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self, let dm = self.displayMap else { return }
                    if self.excerptLayouts.count != dm.excerptLocations.count {
                        self.invalidateLayout()
                    }
                }
                .store(in: &displayMapCancellables)
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
    private var contentTotalHeight: CGFloat = 0
    private var contentNeededWidth: CGFloat = 0

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

    private var activeSelectionGranularity: SelectionGranularity = .character
    private var isDraggingSelection: Bool = false

    public private(set) var excerptLayouts: [ExcerptLayout] = []
    private var excerptStartYs: [CGFloat] = []
    private var filePathToY: [String: CGFloat] = [:]
    private var cachedFileSections: [FileSection] = []

    // Cursor Animation
    private var cursorTimer: Timer?
    private var isCursorVisible: Bool = true

    // Hover State
    private var hoveredGutterLineIndex: Int? = nil
    private var trackingArea: NSTrackingArea?

    // Scrollbar Auto-Hide Animation
    private var scrollbarAlpha: CGFloat = 0.0
    private var visibleScrollbarAxis: ScrollAxis?
    private var scrollbarFadeTimer: Timer?
    private var fadeAnimationTimer: Timer?

    private var scrollbarDragAxis: ScrollbarDragAxis?
    private var scrollbarDragStartMousePosition: CGFloat = 0
    private var scrollbarDragStartOffset: CGFloat = 0

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

    private func showScrollbarsWithAutohide(for axis: ScrollAxis) {
        scrollbarFadeTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
        visibleScrollbarAxis = axis
        scrollbarAlpha = 1.0
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.startScrollbarFadeOut()
        }
        needsDisplay = true
    }

    private func startScrollbarFadeOut() {
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

    private func verticalScrollbarGeometry() -> (thumb: CGRect, hit: CGRect)? {
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

    private func horizontalScrollbarGeometry() -> (thumb: CGRect, hit: CGRect)? {
        let trackWidth = bounds.width - gutterWidth - 10
        guard totalDocumentWidth > bounds.width, trackWidth > 0, bounds.height > 0 else { return nil }

        let maxScrollX = totalDocumentWidth - bounds.width
        let thumbWidth = min(trackWidth, max(40, (trackWidth / totalDocumentWidth) * trackWidth))
        let travel = max(0, trackWidth - thumbWidth)
        let progress = maxScrollX > 0 ? scrollOffsetX / maxScrollX : 0
        let thumbX = gutterWidth + progress * travel
        let thumb = CGRect(x: thumbX, y: bounds.height - 8, width: thumbWidth, height: 6)
        let hit = thumb.insetBy(dx: -2, dy: -6).intersection(bounds)
        return (thumb, hit)
    }

    @discardableResult
    private func beginScrollbarDrag(at point: CGPoint) -> Bool {
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

    private func updateScrollbarDrag(at point: CGPoint) {
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
            let trackWidth = max(0, bounds.width - gutterWidth - 10)
            let travel = max(0, trackWidth - geometry.thumb.width)
            guard travel > 0 else { return }
            let delta = point.x - scrollbarDragStartMousePosition
            scrollOffsetX = max(0, min(maxScrollX, scrollbarDragStartOffset + delta * maxScrollX / travel))
            showScrollbarsWithAutohide(for: .horizontal)
        }

        needsDisplay = true
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
    private var scrollLockAxis: ScrollAxis? = nil
    private var lastScrollEventTime: Date = .distantPast

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
            // Determine dominant direction at start of gesture (Zed style)
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

        if event.phase == .ended || event.phase == .cancelled {
            scrollLockAxis = nil
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewportMetrics()
    }

    private func updateViewportMetrics() {
        totalDocumentHeight = contentTotalHeight
        totalDocumentWidth = max(bounds.width, contentNeededWidth)

        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        let maxScrollX = max(0, totalDocumentWidth - bounds.width)
        scrollOffsetY = max(0, min(maxScrollY, scrollOffsetY))
        scrollOffsetX = max(0, min(maxScrollX, scrollOffsetX))

        needsDisplay = true
    }

    public func syncLayoutIfNeeded() {
        let expectedCount = displayMap?.excerptLocations.count ?? 0
        if excerptLayouts.count != expectedCount {
            invalidateLayout()
        }
    }

    public func excerptIndex(atY y: CGFloat) -> Int {
        guard !excerptStartYs.isEmpty else { return 0 }
        let maxIdx = excerptStartYs.count - 1
        if y <= 0 { return 0 }
        if y >= excerptStartYs[maxIdx] { return maxIdx }

        var low = 0
        var high = maxIdx
        var best = 0

        while low <= high {
            let mid = (low + high) / 2
            if excerptStartYs[mid] <= y {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return min(maxIdx, max(0, best))
    }

    public func excerptIndex(forDisplayLineIndex lineIdx: Int) -> Int {
        guard !excerptLayouts.isEmpty else { return 0 }
        let maxIdx = excerptLayouts.count - 1
        var low = 0
        var high = maxIdx
        var best = 0

        while low <= high {
            let mid = (low + high) / 2
            if excerptLayouts[mid].displayRange.lowerBound <= lineIdx {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return min(maxIdx, max(0, best))
    }

    public func lineIndex(atY y: CGFloat) -> Int {
        let totalLines = displayMap?.displayLines.count ?? 0
        guard totalLines > 0, !excerptLayouts.isEmpty else { return 0 }
        let exIdx = excerptIndex(atY: y)
        guard exIdx < excerptLayouts.count else { return 0 }
        let ex = excerptLayouts[exIdx]
        guard !ex.displayRange.isEmpty else { return 0 }

        let relY = y - ex.startY
        let count = ex.lineRelativeY.count
        guard count > 0 else { return ex.displayRange.lowerBound }

        var low = 0
        var high = count - 1
        var best = 0

        while low <= high {
            let mid = (low + high) / 2
            if ex.lineRelativeY[mid] <= relY {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return min(ex.displayRange.upperBound - 1, ex.displayRange.lowerBound + best)
    }

    public func yOffset(forDisplayLineIndex lineIdx: Int) -> CGFloat {
        guard !excerptLayouts.isEmpty else { return 0 }
        let exIdx = excerptIndex(forDisplayLineIndex: lineIdx)
        guard exIdx < excerptLayouts.count else { return 0 }
        let ex = excerptLayouts[exIdx]
        let offset = lineIdx - ex.displayRange.lowerBound
        guard offset >= 0 && offset < ex.lineRelativeY.count else { return ex.startY }
        return ex.startY + ex.lineRelativeY[offset]
    }

    public func lineHeight(forDisplayLineIndex lineIdx: Int) -> CGFloat {
        guard !excerptLayouts.isEmpty else { return lineHeight }
        let exIdx = excerptIndex(forDisplayLineIndex: lineIdx)
        guard exIdx < excerptLayouts.count else { return lineHeight }
        let ex = excerptLayouts[exIdx]
        let offset = lineIdx - ex.displayRange.lowerBound
        guard offset >= 0 && offset < ex.lineRelativeY.count else { return lineHeight }
        if offset + 1 < ex.lineRelativeY.count {
            return ex.lineRelativeY[offset + 1] - ex.lineRelativeY[offset]
        } else {
            return ex.height - ex.lineRelativeY[offset]
        }
    }

    public func invalidateLayout() {
        guard let displayMap = displayMap else {
            contentTotalHeight = 0
            contentNeededWidth = 0
            totalDocumentHeight = 0
            totalDocumentWidth = 0
            excerptLayouts.removeAll(keepingCapacity: false)
            excerptStartYs.removeAll(keepingCapacity: false)
            filePathToY.removeAll(keepingCapacity: false)
            cachedFileSections.removeAll(keepingCapacity: false)
            needsDisplay = true
            return
        }

        var totalHeight: CGFloat = 0
        let maxLineChars: Int = displayMap.maxLineChars
        let totalExcerpts = displayMap.excerptLocations.count

        excerptLayouts.removeAll(keepingCapacity: true)
        excerptLayouts.reserveCapacity(totalExcerpts)
        excerptStartYs.removeAll(keepingCapacity: true)
        excerptStartYs.reserveCapacity(totalExcerpts)
        filePathToY.removeAll(keepingCapacity: true)
        filePathToY.reserveCapacity(totalExcerpts)
        cachedFileSections.removeAll(keepingCapacity: true)
        cachedFileSections.reserveCapacity(totalExcerpts)

        for (exIdx, loc) in displayMap.excerptLocations.enumerated() {
            let startY = totalHeight
            excerptStartYs.append(startY)

            let excerpt = displayMap.multiBuffer.excerpts[exIdx]
            var relOffsets: [CGFloat] = []
            relOffsets.reserveCapacity(loc.displayRange.count)
            var currentRelY: CGFloat = 0

            for lineIdx in loc.displayRange {
                relOffsets.append(currentRelY)
                let line = displayMap.displayLines[lineIdx]
                let h: CGFloat
                switch line {
                case .excerptHeader(let info):
                    h = excerptHeaderHeight
                    let headerY = startY + currentRelY
                    if let lastIdx = cachedFileSections.indices.last {
                        cachedFileSections[lastIdx].contentMaxY = headerY
                    }
                    cachedFileSections.append(FileSection(info: info, headerMinY: headerY, contentMaxY: headerY + h))
                    if filePathToY[info.filePath] == nil {
                        filePathToY[info.filePath] = headerY
                        if let lastSlash = info.filePath.lastIndex(of: "/") {
                            let name = String(info.filePath[info.filePath.index(after: lastSlash)...])
                            if filePathToY[name] == nil {
                                filePathToY[name] = headerY
                            }
                        }
                    }
                case .code:
                    h = lineHeight
                case .foldGap:
                    h = foldGapHeight
                case .inlineComment:
                    h = commentHeight
                }
                currentRelY += h
            }

            let exHeight = currentRelY
            excerptLayouts.append(ExcerptLayout(
                excerptIndex: exIdx,
                filePath: excerpt.filePath,
                displayRange: loc.displayRange,
                codeRange: loc.codeRange,
                startY: startY,
                height: exHeight,
                lineRelativeY: relOffsets
            ))
            totalHeight += exHeight
        }

        if let lastIdx = cachedFileSections.indices.last {
            cachedFileSections[lastIdx].contentMaxY = totalHeight
        }
        totalHeight += 8 // Clean minimal 8px margin at bottom

        let charWidth = font.pointSize * 0.75
        let neededWidth = gutterWidth + CGFloat(maxLineChars) * charWidth + 100
        self.contentTotalHeight = totalHeight
        self.contentNeededWidth = neededWidth

        updateViewportMetrics()
        clampCursorToValidBounds()
        needsDisplay = true
    }

    /// O(1) Fast scoped layout mutation for ONLY the edited excerpt
    private func updateLayoutAfterExcerptRebuild(excerptIdx: Int, displayDelta: Int, oldDisplayRange: Range<Int>) {
        guard let dm = displayMap, excerptIdx >= 0 && excerptIdx < excerptLayouts.count else {
            invalidateLayout()
            return
        }

        let loc = dm.excerptLocations[excerptIdx]
        let excerpt = dm.multiBuffer.excerpts[excerptIdx]
        let oldHeight = excerptLayouts[excerptIdx].height
        let startY = excerptLayouts[excerptIdx].startY

        var relOffsets: [CGFloat] = []
        relOffsets.reserveCapacity(loc.displayRange.count)
        var currentRelY: CGFloat = 0

        for lineIdx in loc.displayRange {
            relOffsets.append(currentRelY)
            let line = dm.displayLines[lineIdx]
            let h: CGFloat
            switch line {
            case .excerptHeader: h = excerptHeaderHeight
            case .code: h = lineHeight
            case .foldGap: h = foldGapHeight
            case .inlineComment: h = commentHeight
            }
            currentRelY += h
        }

        let newHeight = currentRelY
        let heightDelta = newHeight - oldHeight

        // 1. Update ONLY this excerpt layout
        excerptLayouts[excerptIdx] = ExcerptLayout(
            excerptIndex: excerptIdx,
            filePath: excerpt.filePath,
            displayRange: loc.displayRange,
            codeRange: loc.codeRange,
            startY: startY,
            height: newHeight,
            lineRelativeY: relOffsets
        )

        // 2. If height or line count changed, shift subsequent excerpt start positions
        if heightDelta != 0 || displayDelta != 0 {
            for j in (excerptIdx + 1)..<excerptLayouts.count {
                excerptLayouts[j].startY += heightDelta
                excerptLayouts[j].displayRange = dm.excerptLocations[j].displayRange
                excerptLayouts[j].codeRange = dm.excerptLocations[j].codeRange
                excerptStartYs[j] += heightDelta
            }

            if excerptIdx < cachedFileSections.count {
                for j in (excerptIdx + 1)..<cachedFileSections.count {
                    cachedFileSections[j].headerMinY += heightDelta
                    cachedFileSections[j].contentMaxY += heightDelta
                }
            }

            self.contentTotalHeight += heightDelta
            self.totalDocumentHeight = contentTotalHeight
        }

        updateViewportMetrics()
        clampCursorToValidBounds()
        needsDisplay = true
    }

    public func yOffset(for multiBufferRow: MultiBufferRow) -> CGFloat? {
        guard let dm = displayMap,
              let codeInfo = dm.codeInfo(for: multiBufferRow) else { return nil }
        return yOffset(forDisplayLineIndex: codeInfo.displayLineIndex)
    }

    public func clampCursorToValidBounds() {
        guard let dm = displayMap, dm.codeLineCount > 0 else { return }
        let minRow = dm.minCodeRow
        let maxRow = dm.maxCodeRow

        var row = cursorPoint.row
        if row < minRow {
            row = minRow
        } else if row > maxRow {
            row = maxRow
        } else if dm.codeInfo(for: row) == nil {
            if let next = dm.nextCodeRow(after: row) {
                row = next
            } else if let prev = dm.previousCodeRow(before: row) {
                row = prev
            } else {
                row = minRow
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
            if anchorRow < minRow {
                anchorRow = minRow
            } else if anchorRow > maxRow {
                anchorRow = maxRow
            } else if dm.codeInfo(for: anchorRow) == nil {
                if let next = dm.nextCodeRow(after: anchorRow) {
                    anchorRow = next
                } else if let prev = dm.previousCodeRow(before: anchorRow) {
                    anchorRow = prev
                } else {
                    anchorRow = minRow
                }
            }
            let anchorMaxCol = dm.lineLength(at: anchorRow)
            let anchorCol = max(0, min(anchor.column, anchorMaxCol))
            selectionAnchor = MultiBufferPoint(row: anchorRow, column: anchorCol)
        }
    }

    private func ensureCursorVisible() {
        guard let cursorY = yOffset(for: cursorPoint.row) else { return }
        let margin: CGFloat = 30
        if cursorY < scrollOffsetY + margin {
            scrollOffsetY = max(0, cursorY - margin)
        } else if cursorY + lineHeight > scrollOffsetY + bounds.height - margin {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            scrollOffsetY = min(maxScrollY, cursorY + lineHeight - bounds.height + margin)
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

        let totalLines = displayMap.displayLines.count
        guard totalLines > 0 else {
            context.saveGState()
            context.setFillColor(theme.background.cgColor)
            context.fill(bounds)
            context.restoreGState()
            return
        }

        if excerptLayouts.count != displayMap.excerptLocations.count {
            invalidateLayout()
        }

        guard !excerptLayouts.isEmpty else {
            context.saveGState()
            context.setFillColor(theme.background.cgColor)
            context.fill(bounds)
            context.restoreGState()
            return
        }

        context.saveGState()
        context.clip(to: bounds)

        // 1. Draw Canvas Background
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        let visibleMinY = scrollOffsetY
        let visibleMaxY = scrollOffsetY + bounds.height
        let lineWidth = max(bounds.width + scrollOffsetX, totalDocumentWidth)

        let startIdx = lineIndex(atY: visibleMinY)
        let endIdx = min(totalLines - 1, lineIndex(atY: visibleMaxY) + 1)

        guard startIdx <= endIdx && startIdx >= 0 && endIdx < totalLines else {
            context.restoreGState()
            return
        }

        // 2. Pass 1: Draw Code Lines (content that scrolls horizontally under gutter)
        for lineIdx in startIdx...endIdx {
            guard lineIdx >= 0 && lineIdx < totalLines else { continue }
            let line = displayMap.displayLines[lineIdx]
            if case .code(var info) = line {
                let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
                let height = lineHeight(forDisplayLineIndex: lineIdx)
                let screenLineFrame = CGRect(
                    x: -scrollOffsetX,
                    y: lineMinY - scrollOffsetY,
                    width: lineWidth,
                    height: height
                )
                if let mbRow = displayMap.multiBufferRow(forDisplayLineIndex: lineIdx) {
                    info.multiBufferRow = mbRow
                }
                info.displayLineIndex = lineIdx
                drawCodeLine(info: info, lineIdx: lineIdx, in: screenLineFrame, context: context)
            }
        }

        // 3. Pass 2: Draw Sticky Gutters, Excerpt Headers, Fold Gaps & Comments (Sticky UI)
        for lineIdx in startIdx...endIdx {
            guard lineIdx >= 0 && lineIdx < totalLines else { continue }
            let line = displayMap.displayLines[lineIdx]
            let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
            let height = lineHeight(forDisplayLineIndex: lineIdx)
            let screenY = lineMinY - scrollOffsetY

            switch line {
            case .excerptHeader(let info):
                let headerFrame = CGRect(x: 0, y: screenY, width: bounds.width, height: height)
                drawExcerptHeader(info: info, in: headerFrame, context: context)

            case .code(var info):
                if let mbRow = displayMap.multiBufferRow(forDisplayLineIndex: lineIdx) {
                    info.multiBufferRow = mbRow
                }
                info.displayLineIndex = lineIdx
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

    // MARK: - Pixel-Perfect Viewport Scroll Anchoring

    private func preserveScreenPosition(ofAnchor anchor: ScrollAnchor?, originalScreenY: CGFloat) {
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
        case .code(let bufId, let bRow):
            if let visualPt = dm.visualPoint(for: bufId, bufferPoint: BufferPoint(row: bRow, column: 0)) {
                newAbsY = yOffset(for: visualPt.row)
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

    private func preserveCursorAndSelection(around action: () -> Void) {
        guard let dm = displayMap else {
            action()
            return
        }
        let cursorLoc = dm.bufferLocation(for: cursorPoint)
        let anchorLoc = selectionAnchor.flatMap { dm.bufferLocation(for: $0) }
        let hadSelection = (selectionAnchor != nil && selectionAnchor != cursorPoint)

        action()

        dm.rebuild()
        invalidateLayout()

        if let loc = cursorLoc, let newVPoint = dm.visualPoint(for: loc.buffer.id, bufferPoint: loc.point) {
            cursorPoint = newVPoint
            if hadSelection, let aLoc = anchorLoc, let newAPoint = dm.visualPoint(for: aLoc.buffer.id, bufferPoint: aLoc.point) {
                selectionAnchor = newAPoint
            } else {
                selectionAnchor = newVPoint
            }
        }
    }

    // MARK: - Sticky Excerpt Header Computation

    private func currentStickyHeader() -> (info: ExcerptHeaderInfo, frame: CGRect)? {
        guard scrollOffsetY > 0, !cachedFileSections.isEmpty else { return nil }

        var low = 0
        var high = cachedFileSections.count - 1
        var candidateIdx: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if cachedFileSections[mid].headerMinY <= scrollOffsetY {
                candidateIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let idx = candidateIdx else { return nil }
        let section = cachedFileSections[idx]
        if scrollOffsetY > section.headerMinY && scrollOffsetY < section.contentMaxY {
            guard section.contentMaxY - section.headerMinY > excerptHeaderHeight else { return nil }

            let nextHeaderMinY: CGFloat? = (idx + 1 < cachedFileSections.count) ? cachedFileSections[idx + 1].headerMinY : nil

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
        let titleWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let titleStartX: CGFloat = 28
        let titleEndX = titleStartX + titleWidth

        // Diff Badges (+N -M) floated to the right edge of visible viewport
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

        let badgeRightMargin: CGFloat = 16
        let badgeSpacing: CGFloat = 10
        var totalBadgeWidth: CGFloat = 0
        if delLine != nil { totalBadgeWidth += delWidth }
        if addLine != nil { totalBadgeWidth += addWidth }
        if delLine != nil && addLine != nil { totalBadgeWidth += badgeSpacing }

        let badgeStartX = bounds.width - badgeRightMargin - totalBadgeWidth
        let minBadgeGap: CGFloat = 20
        let shouldDrawBadges = totalBadgeWidth > 0 && (badgeStartX >= titleEndX + minBadgeGap)

        // Draw title
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: titleStartX, y: rect.minY + 22)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Draw badges (pinned to right edge of viewport, hidden if title is too long)
        if shouldDrawBadges {
            var rightBadgeX = bounds.width - badgeRightMargin

            if let delLine = delLine {
                rightBadgeX -= delWidth
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: rightBadgeX, y: rect.minY + 22)
                context.scaleBy(x: 1.0, y: -1.0)
                CTLineDraw(delLine, context)
                context.restoreGState()
                rightBadgeX -= badgeSpacing // Spacing between + and - badges
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
        isDraggingSelection = false
        let screenPoint = convert(event.locationInWindow, from: nil)

        // Scrollbars are painted by this view, so handle their hit-testing
        // before the normal document/selection hit-testing.
        if beginScrollbarDrag(at: screenPoint) {
            return
        }

        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX
        let isShift = event.modifierFlags.contains(.shift)
        guard let displayMap = displayMap else { return }

        // 1. Check if user clicked on Sticky Excerpt Header
        if let (stickyInfo, stickyFrame) = currentStickyHeader(), stickyFrame.contains(screenPoint) {
            displayMap.multiBuffer.toggleCollapse(filePath: stickyInfo.filePath)
            displayMap.rebuild()
            invalidateLayout()
            return
        }

        // 2. Search through visible display lines using O(log N) line index
        let totalLines = displayMap.displayLines.count
        guard totalLines > 0 else { return }

        let lineIdx = lineIndex(atY: docY)
        let line = displayMap.displayLines[lineIdx]
        let lineMinY = yOffset(forDisplayLineIndex: lineIdx)
        let height = lineHeight(forDisplayLineIndex: lineIdx)
        let lineMaxY = lineMinY + height

        if docY >= lineMinY && docY <= lineMaxY {
            switch line {
            case .excerptHeader(let header):
                displayMap.multiBuffer.toggleCollapse(filePath: header.filePath)
                displayMap.rebuild()
                invalidateLayout()
                return
            case .foldGap(let gap):
                selectionAnchor = cursorPoint
                var anchor: ScrollAnchor? = nil
                var anchorScreenY: CGFloat = 0

                if gap.isTopGap {
                    if lineIdx + 1 < totalLines, case .code(let c) = displayMap.displayLines[lineIdx + 1] {
                        if c.excerptIndex >= 0 && c.excerptIndex < displayMap.multiBuffer.excerpts.count {
                            let exc = displayMap.multiBuffer.excerpts[c.excerptIndex]
                            anchor = .code(bufferId: exc.bufferId, bufferRow: c.bufferRow)
                        }
                        anchorScreenY = yOffset(forDisplayLineIndex: lineIdx + 1) - scrollOffsetY
                    }
                } else {
                    if lineIdx > 0 {
                        let prevLine = displayMap.displayLines[lineIdx - 1]
                        switch prevLine {
                        case .excerptHeader(let h):
                            anchor = .header(filePath: h.filePath)
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx - 1) - scrollOffsetY
                        case .code(let c):
                            if c.excerptIndex >= 0 && c.excerptIndex < displayMap.multiBuffer.excerpts.count {
                                let exc = displayMap.multiBuffer.excerpts[c.excerptIndex]
                                anchor = .code(bufferId: exc.bufferId, bufferRow: c.bufferRow)
                            }
                            anchorScreenY = yOffset(forDisplayLineIndex: lineIdx - 1) - scrollOffsetY
                        default:
                            break
                        }
                    }
                }

                preserveCursorAndSelection {
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
                        anchor = .code(bufferId: exc.bufferId, bufferRow: codeInfo.bufferRow)
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
                    selectionAnchor = targetPoint
                    cursorPoint = targetPoint
                    needsDisplay = true
                    return
                } else {
                    // Position cursor in code
                    isDraggingSelection = true
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
                return
            }
        }

        isDraggingSelection = true
        activeSelectionGranularity = .character
        if docY > totalDocumentHeight, let lastCode = displayMap.lastCodeInfo {
            let targetPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
            if !isShift || selectionAnchor == nil {
                selectionAnchor = targetPoint
            }
            cursorPoint = targetPoint
            needsDisplay = true
        } else if docY < 0, let firstCode = displayMap.firstCodeInfo {
            let targetPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
            if !isShift || selectionAnchor == nil {
                selectionAnchor = targetPoint
            }
            cursorPoint = targetPoint
            needsDisplay = true
        }
    }

    public override func mouseDragged(with event: NSEvent) {
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
        guard lineIdx >= 0 && lineIdx < displayMap.displayLines.count else { return }
        let line = displayMap.displayLines[lineIdx]

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
            needsDisplay = true
        } else {
            if docY > totalDocumentHeight, let lastCode = displayMap.lastCodeInfo {
                cursorPoint = MultiBufferPoint(row: lastCode.multiBufferRow, column: lastCode.text.count)
                needsDisplay = true
            } else if docY < 0, let firstCode = displayMap.firstCodeInfo {
                cursorPoint = MultiBufferPoint(row: firstCode.multiBufferRow, column: 0)
                needsDisplay = true
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let axis = scrollbarDragAxis {
            scrollbarDragAxis = nil
            showScrollbarsWithAutohide(for: axis == .vertical ? .vertical : .horizontal)
        }
        isDraggingSelection = false
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
            let currentScreenY = (yOffset(for: cursorRow) ?? 0) - scrollOffsetY

            var anchor: ScrollAnchor? = nil
            if let loc = displayMap.bufferLocation(for: cursorPoint) {
                anchor = .code(bufferId: loc.buffer.id, bufferRow: loc.point.row)
            }

            preserveCursorAndSelection {
                displayMap.multiBuffer.expandExcerptAt(point: cursorPoint, lines: 5, direction: .upAndDown)
            }

            preserveScreenPosition(ofAnchor: anchor, originalScreenY: currentScreenY)
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
                if isEditable {
                    _ = displayMap?.multiBuffer.flushImmediateSave()
                }
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
        guard isEditable, let displayMap = displayMap else { return }
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
        let lineDelta = (newBufRange.upperBound.row - oldEnd.row)
        updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: startLoc.excerptIndex, lineDelta: lineDelta)

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

        let excerptIdx = startLoc.excerptIndex
        if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
            updateLayoutAfterExcerptRebuild(
                excerptIdx: excerptIdx,
                displayDelta: deltas.displayDelta,
                oldDisplayRange: deltas.oldDisplayRange
            )
            if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
                cursorPoint = newVisualPt
            } else {
                cursorPoint = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
            }
        } else {
            displayMap.rebuild()
            invalidateLayout()
            if let newVisualPt = displayMap.visualPoint(for: buf.id, bufferPoint: newBufRange.upperBound) {
                cursorPoint = newVisualPt
            } else {
                cursorPoint = MultiBufferPoint(row: rangeToReplace.lowerBound.row, column: newBufRange.upperBound.column)
            }
        }
        selectionAnchor = cursorPoint
        ensureCursorVisible()
        resetCursorBlink()
        needsDisplay = true
    }

    public override func deleteBackward(_ sender: Any?) {
        guard isEditable, let displayMap = displayMap else { return }
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
            let lineDelta = (newRange.upperBound.row - bPt.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(bufferId: buf.id, range: start..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)

            let excerptIdx = loc.excerptIndex
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                } else {
                    cursorPoint = MultiBufferPoint(row: cursorPoint.row, column: max(0, cursorPoint.column - 1))
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                } else {
                    cursorPoint = MultiBufferPoint(row: cursorPoint.row, column: max(0, cursorPoint.column - 1))
                }
            }
            selectionAnchor = cursorPoint
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
        } else if bPt.row > 0 {
            let prevLen = buf.lineLength(at: bPt.row - 1)
            let start = BufferPoint(row: bPt.row - 1, column: prevLen)
            let oldExact = buf.text(in: start..<bPt)
            let newRange = buf.replace(start: start, end: bPt, with: "")
            let lineDelta = (newRange.upperBound.row - bPt.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(bufferId: buf.id, range: start..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)

            let excerptIdx = loc.excerptIndex
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                } else {
                    cursorPoint = MultiBufferPoint(row: max(0, cursorPoint.row - 1), column: prevLen)
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                } else {
                    cursorPoint = MultiBufferPoint(row: max(0, cursorPoint.row - 1), column: prevLen)
                }
            }
            selectionAnchor = cursorPoint
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
        }
    }

    public override func deleteForward(_ sender: Any?) {
        guard isEditable, let displayMap = displayMap else { return }
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
            let lineDelta = (newRange.upperBound.row - end.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(bufferId: buf.id, range: bPt..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)

            let excerptIdx = loc.excerptIndex
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                }
            }
            selectionAnchor = cursorPoint
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
        } else if bPt.row < buf.lineCount - 1 {
            let end = BufferPoint(row: bPt.row + 1, column: 0)
            let oldExact = buf.text(in: bPt..<end)
            let newRange = buf.replace(start: bPt, end: end, with: "")
            let lineDelta = (newRange.upperBound.row - end.row)
            updateExcerptsAfterEdit(bufferId: buf.id, excerptIndex: loc.excerptIndex, lineDelta: lineDelta)
            let edit = TextEdit(bufferId: buf.id, range: bPt..<newRange.upperBound, oldText: oldExact, newText: "")
            let tx = EditTransaction(edits: [edit], selectionBefore: cursorPoint..<cursorPoint, selectionAfter: nil)
            mb.undoManager.push(transaction: tx)
            mb.scheduleDebouncedSave(delayMs: 200)

            let excerptIdx = loc.excerptIndex
            if let deltas = displayMap.rebuildExcerpt(at: excerptIdx) {
                updateLayoutAfterExcerptRebuild(
                    excerptIdx: excerptIdx,
                    displayDelta: deltas.displayDelta,
                    oldDisplayRange: deltas.oldDisplayRange
                )
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                }
            } else {
                displayMap.rebuild()
                invalidateLayout()
                if let vPt = displayMap.visualPoint(for: buf.id, bufferPoint: newRange.upperBound) {
                    cursorPoint = vPt
                }
            }
            selectionAnchor = cursorPoint
            ensureCursorVisible()
            resetCursorBlink()
            needsDisplay = true
        }
    }

    private func updateExcerptsAfterEdit(bufferId: BufferId, excerptIndex: Int, lineDelta: Int) {
        guard lineDelta != 0, let mb = displayMap?.multiBuffer, excerptIndex >= 0 && excerptIndex < mb.excerpts.count else { return }
        var excerpt = mb.excerpts[excerptIndex]
        let newUpper = max(excerpt.bufferRange.lowerBound, excerpt.bufferRange.upperBound + lineDelta)
        excerpt.bufferRange = excerpt.bufferRange.lowerBound..<newUpper
        mb.updateExcerptBufferRange(at: excerptIndex, range: excerpt.bufferRange)

        for i in (excerptIndex + 1)..<mb.excerpts.count {
            if mb.excerpts[i].bufferId == bufferId {
                let oldRange = mb.excerpts[i].bufferRange
                let newLower = max(newUpper, oldRange.lowerBound + lineDelta)
                let newUpperSub = max(newLower, oldRange.upperBound + lineDelta)
                mb.updateExcerptBufferRange(at: i, range: newLower..<newUpperSub)
            }
        }

        if let curB = mb.buffers[bufferId] {
            for otherBuf in mb.buffers.values where otherBuf.filePath == curB.filePath && otherBuf.id != curB.id {
                if otherBuf.startLineNumber >= curB.startLineNumber {
                    otherBuf.startLineNumber += lineDelta
                }
            }
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
        guard isEditable, let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popUndo() {
            for edit in transaction.edits.reversed() {
                if let buf = mb.buffer(for: edit.bufferId) {
                    let oldEndRow = edit.range.upperBound.row
                    let newRange = buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.oldText)
                    let lineDelta = newRange.upperBound.row - oldEndRow
                    if lineDelta != 0, let excerptIdx = mb.excerpts.firstIndex(where: { $0.bufferId == edit.bufferId }) {
                        updateExcerptsAfterEdit(bufferId: edit.bufferId, excerptIndex: excerptIdx, lineDelta: lineDelta)
                    }
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
        guard isEditable, let displayMap = displayMap else { return }
        let mb = displayMap.multiBuffer
        if let transaction = mb.undoManager.popRedo() {
            for edit in transaction.edits {
                if let buf = mb.buffer(for: edit.bufferId) {
                    let oldEndRow = edit.range.upperBound.row
                    let newRange = buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.newText)
                    let lineDelta = newRange.upperBound.row - oldEndRow
                    if lineDelta != 0, let excerptIdx = mb.excerpts.firstIndex(where: { $0.bufferId == edit.bufferId }) {
                        updateExcerptsAfterEdit(bufferId: edit.bufferId, excerptIndex: excerptIdx, lineDelta: lineDelta)
                    }
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
