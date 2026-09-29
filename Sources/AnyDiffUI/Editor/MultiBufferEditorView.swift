import Foundation
import AppKit
import CoreText
import Combine
import AnyDiffCore

public protocol MultiBufferEditorDelegate: AnyObject {
    func editorDidChangeCursor(location: ExcerptLocation?, point: MultiBufferPoint)
    func editorDidRequestAddComment(filePath: String, lineNumber: Int)
    func editorDidScroll()
    func editorDidChangeContent()
    func editorDidRequestCloseFile(filePath: String)
    func editorDidRequestOpenExternalIDE(filePath: String, lineNumber: Int?)
    func editorDidRequestPreviewMarkdown(filePath: String)
}

public extension MultiBufferEditorDelegate {
    func editorDidScroll() {}
    func editorDidChangeContent() {}
    func editorDidRequestCloseFile(filePath: String) {}
    func editorDidRequestOpenExternalIDE(filePath: String, lineNumber: Int?) {}
    func editorDidRequestPreviewMarkdown(filePath: String) {}
}

/// A high-performance, virtualized MultiBuffer Code Reviewer & Editor View built with CoreText
public final class MultiBufferEditorView: NSView, NSTextInputClient, NSUserInterfaceValidations {
    public weak var delegate: MultiBufferEditorDelegate?
    public var onContentEdited: (() -> Void)? = nil
    var displayMapCancellables = Set<AnyCancellable>()

    public var displayMap: DisplayMap? {
        didSet {
            displayMapCancellables.removeAll()
            displayMap?.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.invalidateLayout()
                }
                .store(in: &displayMapCancellables)
            invalidateLayout()
        }
    }

    public var theme: Theme = .vesper {
        didSet {
            // CTLine stores resolved foreground colors, so cached lines must be
            // discarded when the palette changes (including system appearance changes).
            SyntaxHighlighter.shared.clearCache()
            lineCache.clear()
            needsDisplay = true
        }
    }

    /// Direct-mapped CoreText line cache owned per editor instance (lock-free)
    public let lineCache = LineRenderCache()

    /// Ratio of code space allocated to the left (old) column in side-by-side mode (0.15 ... 0.85)
    public var splitRatio: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "anyDiffSplitRatio")
        return (saved >= 0.15 && saved <= 0.85) ? CGFloat(saved) : 0.5
    }() {
        didSet {
            UserDefaults.standard.set(Double(splitRatio), forKey: "anyDiffSplitRatio")
            updateViewportMetrics()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    public enum SplitActiveColumn: Sendable, Equatable {
        case left
        case right
    }

    public internal(set) var splitActiveColumn: SplitActiveColumn = .right
    var isDraggingDivider: Bool = false
    var lastLayoutMode: DiffLayoutMode? = nil
    var lastRebuildVersion: UInt64 = 0

    /// Adjusts the scrollbar thumb for enough contrast in both appearances.
    var scrollbarThumbBaseColor: NSColor {
        if theme.isDark {
            return theme.gutterForeground.blended(withFraction: 0.70, of: .white)
                ?? theme.gutterForeground
        }
        return theme.gutterForeground.blended(withFraction: 0.30, of: .black)
            ?? theme.gutterForeground
    }

    public var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet {
            updateFontMetrics()
            invalidateLayout()
        }
    }

    public var isEditable: Bool = true
    /// Blocks mutations while keeping cursor movement, selection, copying,
    /// and scrolling available to read-only consumers such as tool output.
    public var ignoreEdits: Bool = false

    /// Optional clipping radius for embedded read-only editor surfaces such
    /// as agent tool output. The default keeps the main editor unchanged.
    public var contentCornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var editingEnabled: Bool {
        isEditable && !ignoreEdits && !(displayMap?.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left)
    }

    func activeLineLength(at row: MultiBufferRow) -> Int {
        guard let dm = displayMap else { return 0 }
        if dm.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left {
            return dm.splitCodeInfo(for: row)?.left.text.count ?? dm.lineLength(at: row)
        }
        return dm.lineLength(at: row)
    }

    func activeLineText(at row: MultiBufferRow) -> String? {
        guard let dm = displayMap else { return nil }
        if dm.effectiveLayoutMode == .sideBySide && splitActiveColumn == .left {
            return dm.splitCodeInfo(for: row)?.left.text ?? dm.lineText(at: row)
        }
        return dm.lineText(at: row)
    }

    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let headerTitleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let headerDirectoryFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    static let previewSymbolImage: NSImage? = {
        NSImage(systemSymbolName: "eye", accessibilityDescription: "Preview Markdown")
            ?? NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Preview Markdown")
    }()

    // Layout Metrics
    public internal(set) var lineHeight: CGFloat = 22
    public internal(set) var fontAscent: CGFloat = 14
    public internal(set) var fontDescent: CGFloat = 4
    public internal(set) var gutterWidth: CGFloat = 58
    static let codeLeftPadding: CGFloat = 12
    public internal(set) var excerptHeaderHeight: CGFloat = 34
    public internal(set) var foldGapHeight: CGFloat = 20
    public internal(set) var commentHeight: CGFloat = 64

    // Virtual Scrolling
    public var scrollOffsetY: CGFloat = 0 {
        didSet {
            delegate?.editorDidScroll()
            needsDisplay = true
        }
    }
    public var scrollOffsetX: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }
    public internal(set) var totalDocumentHeight: CGFloat = 0
    public internal(set) var totalDocumentWidth: CGFloat = 0
    var contentTotalHeight: CGFloat = 0
    var contentNeededWidth: CGFloat = 0

    // Selection & Cursor State
    public var cursorPoint: MultiBufferPoint = .zero {
        didSet {
            resetCursorBlink()
            let sel = normalizedSelectionRange()
            displayMap?.selectionRange = sel
            displayMap?.multiBuffer.selectionRange = sel
            notifyCursorChange()
            ensureCursorVisible()
            needsDisplay = true
        }
    }
    public var selectionAnchor: MultiBufferPoint? = nil {
        didSet {
            let sel = normalizedSelectionRange()
            displayMap?.selectionRange = sel
            displayMap?.multiBuffer.selectionRange = sel
        }
    }
    public var hasSelection: Bool {
        guard let anchor = selectionAnchor else { return false }
        return anchor != cursorPoint
    }

    // Search Matches & Highlighting (Project Search)
    public var searchMatches: [ProjectSearchMatch] = [] {
        didSet {
            rebuildSearchMatchIndex()
            needsDisplay = true
        }
    }
    public var activeMatchIndex: Int? = nil {
        didSet {
            if activeMatchIndex != oldValue && activeMatchIndex != nil {
                triggerActiveMatchPulse()
            }
            needsDisplay = true
        }
    }
    var activeMatchPulseStartTime: CFAbsoluteTime = 0
    var activeMatchPulseTimer: Timer? = nil

    func triggerActiveMatchPulse() {
        activeMatchPulseStartTime = CFAbsoluteTimeGetCurrent()
        activeMatchPulseTimer?.invalidate()
        activeMatchPulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - self.activeMatchPulseStartTime
            if elapsed >= 0.45 {
                timer.invalidate()
                self.activeMatchPulseTimer = nil
            }
            self.needsDisplay = true
        }
    }

    struct SearchFileLineKey: Hashable {
        let filePath: String
        let lineNumber: Int
    }
    var searchMatchesByFileLine: [SearchFileLineKey: [ProjectSearchMatch]] = [:]
    var activeMatchId: UUID? {
        guard let idx = activeMatchIndex, idx >= 0, idx < searchMatches.count else { return nil }
        return searchMatches[idx].id
    }

    func rebuildSearchMatchIndex() {
        var index: [SearchFileLineKey: [ProjectSearchMatch]] = [:]
        for match in searchMatches {
            let key = SearchFileLineKey(filePath: match.filePath, lineNumber: match.lineNumber)
            index[key, default: []].append(match)
        }
        self.searchMatchesByFileLine = index
    }

    var activeSelectionGranularity: SelectionGranularity = .character
    var isDraggingSelection: Bool = false

    public internal(set) var excerptLayouts: [ExcerptLayout] = []
    var excerptStartYs: [CGFloat] = []
    var filePathToY: [String: CGFloat] = [:]
    var cachedFileSections: [FileSection] = []

    // Cursor Animation
    var cursorTimer: Timer?
    var isCursorVisible: Bool = true

    // Hover State
    var hoveredGutterLineIndex: Int? = nil
    var hoveredCloseFilePath: String? = nil
    var hoveredPreviewFilePath: String? = nil
    var trackingArea: NSTrackingArea?

    // Scrollbar Auto-Hide Animation
    var scrollbarAlpha: CGFloat = 0.0
    var visibleScrollbarAxis: ScrollAxis?
    var scrollbarFadeTimer: Timer?
    var fadeAnimationTimer: Timer?

    var scrollbarDragAxis: ScrollbarDragAxis?
    var scrollbarDragStartMousePosition: CGFloat = 0
    var scrollbarDragStartOffset: CGFloat = 0


    var cachedCharWidth: CGFloat = 8.0
    var scrollLockAxis: ScrollAxis? = nil
    var lastScrollEventTime: Date = .distantPast
    var lastPublishedQuoteId: String? = nil
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            resetCursorBlink()
            needsDisplay = true
        }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isCursorVisible = false
            needsDisplay = true
        }
        return result
    }

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

    func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawConcurrently = true
        updateFontMetrics()
        startCursorBlink()
        NotificationCenter.default.addObserver(self, selector: #selector(handleFocusFileNotification(_:)), name: .focusFileInEditor, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleGoToNextHunkNotification(_:)), name: .goToNextHunk, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleGoToPreviousHunkNotification(_:)), name: .goToPreviousHunk, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cursorTimer?.invalidate()
        scrollbarFadeTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
        activeMatchPulseTimer?.invalidate()
    }


    func updateFontMetrics() {
        let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        fontAscent = CTFontGetAscent(ctFont)
        fontDescent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        lineHeight = max(18, ceil(fontAscent + fontDescent + leading + 4))

        var glyph: CGGlyph = 0
        var advance: CGSize = .zero
        let chars: [UniChar] = [0x004D] // 'M'
        if CTFontGetGlyphsForCharacters(ctFont, chars, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            cachedCharWidth = advance.width
        } else {
            cachedCharWidth = font.pointSize * 0.6
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
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

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewportMetrics()
        window?.invalidateCursorRects(for: self)
    }

    func updateViewportMetrics() {
        totalDocumentHeight = contentTotalHeight

        if displayMap?.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: 0, height: bounds.height)
            let minColWidth = max(50, min(geom.leftCodeRect.width, geom.rightCodeRect.width))
            let codeNeededWidth = CGFloat(displayMap?.maxLineChars ?? 0) * cachedCharWidth + 30
            let codeOverflow = max(0, codeNeededWidth - minColWidth)
            totalDocumentWidth = bounds.width + codeOverflow
        } else {
            totalDocumentWidth = max(bounds.width, contentNeededWidth)
        }

        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        let maxScrollX = max(0, totalDocumentWidth - bounds.width)
        scrollOffsetY = max(0, min(maxScrollY, scrollOffsetY))
        scrollOffsetX = max(0, min(maxScrollX, scrollOffsetX))

        needsDisplay = true
    }

    public func syncLayoutIfNeeded() {
        guard let dm = displayMap else { return }
        let expectedCount = dm.excerptLocations.count
        let lastUpperBound = excerptLayouts.last?.displayRange.upperBound ?? 0
        if excerptLayouts.count != expectedCount ||
           dm.displayLineCount != lastUpperBound ||
           lastLayoutMode != dm.effectiveLayoutMode ||
           lastRebuildVersion != dm.rebuildVersion {
            invalidateLayout()
        }
    }

    public func excerptIndex(atY y: CGFloat) -> Int {
        guard !excerptStartYs.isEmpty else { return 0 }
        let maxIdx = excerptStartYs.count - 1
        if y <= 0 { return 0 }
        if y >= excerptStartYs[maxIdx] {
            var idx = maxIdx
            while idx > 0 && excerptLayouts[idx].displayRange.isEmpty {
                idx -= 1
            }
            return idx
        }

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
        var result = min(maxIdx, max(0, best))
        while result > 0 && excerptLayouts[result].displayRange.isEmpty {
            result -= 1
        }
        return result
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
        var result = min(maxIdx, max(0, best))
        while result > 0 && excerptLayouts[result].displayRange.isEmpty {
            result -= 1
        }
        return result
    }

    public func lineIndex(atY y: CGFloat) -> Int {
        let totalLines = displayMap?.displayLineCount ?? 0
        guard totalLines > 0, !excerptLayouts.isEmpty else { return 0 }
        if y <= 0 { return 0 }

        let exIdx = excerptIndex(atY: y)
        guard exIdx < excerptLayouts.count else { return totalLines - 1 }
        let ex = excerptLayouts[exIdx]
        guard !ex.displayRange.isEmpty else {
            return min(totalLines - 1, ex.displayRange.lowerBound)
        }

        let relY = max(0, y - ex.startY)
        let offset = ex.lineOffset(
            atRelativeY: relY,
            headerHeight: excerptHeaderHeight,
            foldGapHeight: foldGapHeight,
            lineHeight: lineHeight
        )
        return min(totalLines - 1, ex.displayRange.lowerBound + offset)
    }

    public func yOffset(forDisplayLineIndex lineIdx: Int) -> CGFloat {
        guard !excerptLayouts.isEmpty else { return 0 }
        let exIdx = excerptIndex(forDisplayLineIndex: lineIdx)
        guard exIdx < excerptLayouts.count else { return 0 }
        let ex = excerptLayouts[exIdx]
        let offset = lineIdx - ex.displayRange.lowerBound
        guard offset >= 0 && offset < ex.displayRange.count else { return ex.startY }
        return ex.startY + ex.relativeY(
            for: offset,
            headerHeight: excerptHeaderHeight,
            foldGapHeight: foldGapHeight,
            lineHeight: lineHeight
        )
    }

    public func lineHeight(forDisplayLineIndex lineIdx: Int) -> CGFloat {
        guard !excerptLayouts.isEmpty else { return lineHeight }
        let exIdx = excerptIndex(forDisplayLineIndex: lineIdx)
        guard exIdx < excerptLayouts.count else { return lineHeight }
        let ex = excerptLayouts[exIdx]
        let offset = lineIdx - ex.displayRange.lowerBound
        guard offset >= 0 && offset < ex.displayRange.count else { return lineHeight }
        return ex.lineHeight(
            for: offset,
            headerHeight: excerptHeaderHeight,
            foldGapHeight: foldGapHeight,
            lineHeight: lineHeight
        )
    }

    public func invalidateLayout() {
        SyntaxHighlighter.shared.clearCache()
        lineCache.clear()
        lastLayoutMode = displayMap?.effectiveLayoutMode
        lastRebuildVersion = displayMap?.rebuildVersion ?? 0
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
            let headerH = loc.hasHeader ? excerptHeaderHeight : 0
            let topGapH = (!loc.isCollapsed && loc.hasTopGap) ? foldGapHeight : 0
            let codeH = !loc.isCollapsed ? CGFloat(loc.codeLineCount) * lineHeight : 0
            let bottomGapH = (!loc.isCollapsed && loc.hasBottomGap) ? foldGapHeight : 0
            let exHeight = headerH + topGapH + codeH + bottomGapH

            if loc.hasHeader {
                let header = ExcerptHeaderInfo(
                    excerptIndex: exIdx,
                    filePath: excerpt.filePath,
                    fileStatus: excerpt.fileStatus,
                    additions: displayMap.multiBuffer.buffer(for: excerpt.bufferId)?.totalAdditions ?? 0,
                    deletions: displayMap.multiBuffer.buffer(for: excerpt.bufferId)?.totalDeletions ?? 0,
                    isCollapsed: excerpt.isCollapsed
                )
                if let lastIdx = cachedFileSections.indices.last {
                    cachedFileSections[lastIdx].contentMaxY = startY
                }
                cachedFileSections.append(FileSection(info: header, headerMinY: startY, contentMaxY: startY + headerH))
                if filePathToY[header.filePath] == nil {
                    filePathToY[header.filePath] = startY
                    if let lastSlash = header.filePath.lastIndex(of: "/") {
                        let name = String(header.filePath[header.filePath.index(after: lastSlash)...])
                        if filePathToY[name] == nil {
                            filePathToY[name] = startY
                        }
                    }
                }
            }

            excerptLayouts.append(ExcerptLayout(
                excerptIndex: exIdx,
                filePath: excerpt.filePath,
                displayRange: loc.displayRange,
                codeRange: loc.codeRange,
                startY: startY,
                height: exHeight,
                hasHeader: loc.hasHeader,
                hasTopGap: loc.hasTopGap,
                hasBottomGap: loc.hasBottomGap,
                codeLineCount: loc.codeLineCount,
                isCollapsed: loc.isCollapsed
            ))
            totalHeight += exHeight
        }

        if let lastIdx = cachedFileSections.indices.last {
            cachedFileSections[lastIdx].contentMaxY = totalHeight
        }
        totalHeight += 8 // Clean minimal 8px margin at bottom

        let neededWidth = gutterWidth + CGFloat(displayMap.maxLineChars) * cachedCharWidth + 20
        self.contentTotalHeight = totalHeight
        self.contentNeededWidth = neededWidth

        updateViewportMetrics()
        clampCursorToValidBounds()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// O(1) Fast scoped layout mutation for ONLY the edited excerpt
    func updateLayoutAfterExcerptRebuild(excerptIdx: Int, displayDelta: Int, oldDisplayRange: Range<Int>) {
        if displayDelta != 0 {
            lineCache.invalidate(from: oldDisplayRange.lowerBound)
        } else {
            for lIdx in oldDisplayRange {
                lineCache.invalidate(lineIndex: lIdx)
            }
        }
        guard let dm = displayMap, excerptIdx >= 0 && excerptIdx < excerptLayouts.count else {
            invalidateLayout()
            return
        }

        let neededWidth = gutterWidth + CGFloat(dm.maxLineChars) * cachedCharWidth + 20
        if neededWidth > contentNeededWidth {
            self.contentNeededWidth = neededWidth
            updateViewportMetrics()
        }

        let loc = dm.excerptLocations[excerptIdx]
        let excerpt = dm.multiBuffer.excerpts[excerptIdx]
        let oldHeight = excerptLayouts[excerptIdx].height
        let startY = excerptLayouts[excerptIdx].startY

        let headerH = loc.hasHeader ? excerptHeaderHeight : 0
        let topGapH = (!loc.isCollapsed && loc.hasTopGap) ? foldGapHeight : 0
        let codeH = !loc.isCollapsed ? CGFloat(loc.codeLineCount) * lineHeight : 0
        let bottomGapH = (!loc.isCollapsed && loc.hasBottomGap) ? foldGapHeight : 0
        let newHeight = headerH + topGapH + codeH + bottomGapH
        let heightDelta = newHeight - oldHeight

        // 1. Update ONLY this excerpt layout
        excerptLayouts[excerptIdx] = ExcerptLayout(
            excerptIndex: excerptIdx,
            filePath: excerpt.filePath,
            displayRange: loc.displayRange,
            codeRange: loc.codeRange,
            startY: startY,
            height: newHeight,
            hasHeader: loc.hasHeader,
            hasTopGap: loc.hasTopGap,
            hasBottomGap: loc.hasBottomGap,
            codeLineCount: loc.codeLineCount,
            isCollapsed: loc.isCollapsed
        )

        // 2. If height or line count changed, shift subsequent excerpt start positions
        if heightDelta != 0 || displayDelta != 0 {
            for j in (excerptIdx + 1)..<excerptLayouts.count {
                excerptLayouts[j].startY += heightDelta
                excerptLayouts[j].displayRange = dm.excerptLocations[j].displayRange
                excerptLayouts[j].codeRange = dm.excerptLocations[j].codeRange
                excerptStartYs[j] += heightDelta
            }

            if let fileSecIdx = cachedFileSections.firstIndex(where: { $0.info.filePath == excerpt.filePath }) {
                cachedFileSections[fileSecIdx].contentMaxY += heightDelta
                for j in (fileSecIdx + 1)..<cachedFileSections.count {
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
        guard let dm = displayMap, dm.codeLineCount > 0 else {
            if cursorPoint != .zero {
                cursorPoint = .zero
            }
            selectionAnchor = nil
            return
        }
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
        let maxCol = activeLineLength(at: row)
        let col = max(0, min(cursorPoint.column, maxCol))
        let clamped = MultiBufferPoint(row: row, column: col)

        var newAnchor: MultiBufferPoint? = nil
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
            let anchorMaxCol = activeLineLength(at: anchorRow)
            let anchorCol = max(0, min(anchor.column, anchorMaxCol))
            let candidateAnchor = MultiBufferPoint(row: anchorRow, column: anchorCol)
            if candidateAnchor != clamped {
                newAnchor = candidateAnchor
            }
        }

        self.selectionAnchor = newAnchor
        if clamped != cursorPoint {
            cursorPoint = clamped
        }
    }

    func ensureCursorVisible() {
        guard let cursorY = yOffset(for: cursorPoint.row) else { return }
        let margin: CGFloat = 30
        if cursorY < scrollOffsetY + margin {
            scrollOffsetY = max(0, cursorY - margin)
        } else if cursorY + lineHeight > scrollOffsetY + bounds.height - margin {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            scrollOffsetY = min(maxScrollY, cursorY + lineHeight - bounds.height + margin)
        }
    }

    // MARK: - Cursor Blinking

    func startCursorBlink() {
        guard isEditable else { return }
        cursorTimer?.invalidate()
        isCursorVisible = true
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isKeyWindow == true else { return }
            self.isCursorVisible.toggle()
            self.needsDisplay = true
        }
    }

    func resetCursorBlink() {
        isCursorVisible = true
        startCursorBlink()
    }

    func notifyCursorChange() {
        guard let dm = displayMap else { return }
        let loc = dm.excerptLocation(for: cursorPoint)
        delegate?.editorDidChangeCursor(location: loc, point: cursorPoint)
    }

    func notifyContentChange() {
        delegate?.editorDidChangeContent()
        onContentEdited?()
    }
}
