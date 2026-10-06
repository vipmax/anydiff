import Foundation
import AppKit
import CoreText
import Combine
import AnyDiffCore

/// Precise document coordinate within a terminal multibuffer document.
public struct TerminalDocumentPoint: Equatable, Comparable, Sendable {
    public var blockIndex: Int
    public var lineIndex: Int
    public var columnIndex: Int

    public init(blockIndex: Int, lineIndex: Int, columnIndex: Int) {
        self.blockIndex = blockIndex
        self.lineIndex = lineIndex
        self.columnIndex = columnIndex
    }

    public static func < (lhs: TerminalDocumentPoint, rhs: TerminalDocumentPoint) -> Bool {
        if lhs.blockIndex != rhs.blockIndex {
            return lhs.blockIndex < rhs.blockIndex
        }
        if lhs.lineIndex != rhs.lineIndex {
            return lhs.lineIndex < rhs.lineIndex
        }
        return lhs.columnIndex < rhs.columnIndex
    }
}

/// Geometric layout info for an individual command block in the virtualized terminal canvas.
public struct TerminalBlockLayout: Sendable {
    public let blockIndex: Int
    public let blockId: UUID
    public let startY: CGFloat
    public let headerHeight: CGFloat
    public let contentHeight: CGFloat
    public let totalHeight: CGFloat
    public let isCollapsed: Bool
    public let lineCount: Int

    @inlinable public var headerMinY: CGFloat { startY }
    @inlinable public var headerMaxY: CGFloat { startY + headerHeight }
    @inlinable public var contentMinY: CGFloat { startY + headerHeight }
    @inlinable public var contentMaxY: CGFloat { startY + totalHeight }
}

/// High-performance, virtualized CoreText view rendering command blocks as unified documents with headers.
public final class BlockTerminalNSView: NSView, NSUserInterfaceValidations {
    public var session: BlockTerminalSession {
        didSet {
            setupSubscriptions()
            lineCache.removeAll(keepingCapacity: true)
            rebuildLayout()
            needsDisplay = true
        }
    }

    public var theme: Theme {
        didSet {
            lineCache.removeAll(keepingCapacity: true)
            needsDisplay = true
        }
    }

    public var fontSize: CGFloat {
        didSet {
            updateFontMetrics()
            lineCache.removeAll(keepingCapacity: true)
            rebuildLayout()
        }
    }

    public var onSwitchToInteractive: (() -> Void)?

    // MARK: - Font & Metric Properties
    private var regularFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .semibold)
    private var italicFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var headerFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .semibold)
    private var badgeFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .bold)

    public private(set) var lineHeight: CGFloat = 17.0
    public let headerHeight: CGFloat = 28.0
    private var fontAscent: CGFloat = 10.0
    private var fontDescent: CGFloat = 3.0

    // Geometry margins
    private let codeLeftMargin: CGFloat = 16.0
    private let headerChevronX: CGFloat = 16.0
    private let headerCommandX: CGFloat = 30.0

    // MARK: - Virtualized Layout State
    public private(set) var blockLayouts: [TerminalBlockLayout] = []
    public private(set) var totalDocumentHeight: CGFloat = 0
    public private(set) var totalDocumentWidth: CGFloat = 0
    private var maxLineWidth: CGFloat = 0
    public private(set) var charWidth: CGFloat = 7.2
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

    private var userScrolledAwayFromBottom: Bool = false
    private var lastScrollEventTime = Date.distantPast

    // Cache of pre-built CTLines: [Key: CTLine]
    // Key is (blockIndex << 32) | lineId
    private var lineCache: [UInt64: CTLine] = [:]

    // MARK: - Selection State
    public var selectionAnchor: TerminalDocumentPoint? = nil
    public var cursorPoint: TerminalDocumentPoint? = nil
    private var isDraggingSelection: Bool = false
    private var selectionGranularity: SelectionGranularity = .character

    private enum SelectionGranularity {
        case character
        case word(anchorWordStart: Int, anchorWordEnd: Int, blockIndex: Int, lineIndex: Int)
        case line(blockIndex: Int, lineIndex: Int)
    }

    public var hasSelection: Bool {
        guard let anchor = selectionAnchor, let cursor = cursorPoint else { return false }
        return anchor != cursor
    }

    public var normalizedSelection: (start: TerminalDocumentPoint, end: TerminalDocumentPoint)? {
        guard let anchor = selectionAnchor, let cursor = cursorPoint, anchor != cursor else { return nil }
        return anchor < cursor ? (anchor, cursor) : (cursor, anchor)
    }

    // MARK: - Scrollbar & Gesture Locking State
    private var scrollLockAxis: ScrollAxis? = nil
    private var visibleScrollbarAxis: ScrollAxis? = nil
    private var scrollbarAlpha: CGFloat = 0.0
    private var scrollbarHideTimer: Timer? = nil
    private var fadeAnimationTimer: Timer? = nil
    private var scrollbarDragKind: ScrollAxis? = nil
    private var scrollbarDragStartPos: CGFloat = 0
    private var scrollbarDragStartScroll: CGFloat = 0

    // MARK: - Hover State
    private var hoveredHeaderBlockIndex: Int? = nil
    private var hoveredCopyBlockIndex: Int? = nil
    private var hoveredRerunBlockIndex: Int? = nil

    private var cancellables = Set<AnyCancellable>()
    private var trackingAreaRef: NSTrackingArea?

    // MARK: - Lifecycle
    public init(
        session: BlockTerminalSession,
        theme: Theme,
        fontSize: CGFloat = 12,
        onSwitchToInteractive: (() -> Void)? = nil
    ) {
        self.session = session
        self.theme = theme
        self.fontSize = fontSize
        self.onSwitchToInteractive = onSwitchToInteractive
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
        updateFontMetrics()
        setupSubscriptions()
        rebuildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isFlipped: Bool {
        true
    }

    public override var acceptsFirstResponder: Bool {
        true
    }

    // MARK: - Subscriptions & Layout Updates
    private func setupSubscriptions() {
        cancellables.removeAll()

        // When blocks or output lines change
        session.multiBuffer.$version
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.rebuildLayout()
            }
            .store(in: &cancellables)

        session.$isProcessRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self = self else { return }
                if isRunning {
                    self.userScrolledAwayFromBottom = false
                    self.startSpinnerAnimation()
                } else {
                    self.stopSpinnerAnimation()
                }
                self.needsDisplay = true
            }
            .store(in: &cancellables)

        if session.isProcessRunning {
            startSpinnerAnimation()
        }
    }

    // MARK: - Spinner Animation
    private var spinnerTimer: Timer? = nil

    private func startSpinnerAnimation() {
        guard spinnerTimer == nil else { return }
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.session.isProcessRunning {
                self.needsDisplay = true
            } else {
                self.stopSpinnerAnimation()
            }
        }
    }

    private func stopSpinnerAnimation() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    deinit {
        spinnerTimer?.invalidate()
        scrollbarHideTimer?.invalidate()
    }

    private func updateFontMetrics() {
        regularFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        headerFont = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        badgeFont = .monospacedSystemFont(ofSize: max(10, fontSize - 2), weight: .bold)

        let ctFont = regularFont as CTFont
        fontAscent = CTFontGetAscent(ctFont)
        fontDescent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        lineHeight = max(15.0, ceil(fontAscent + fontDescent + leading + 2.0))

        let sample: NSString = "M"
        let attrs: [NSAttributedString.Key: Any] = [.font: regularFont]
        charWidth = max(5.0, sample.size(withAttributes: attrs).width)

        let italicDesc = regularFont.fontDescriptor.withSymbolicTraits(.italic)
        italicFont = NSFont(descriptor: italicDesc, size: fontSize) ?? regularFont
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = (newSize != frame.size)
        super.setFrameSize(newSize)
        if sizeChanged {
            totalDocumentWidth = max(newSize.width, maxLineWidth)
            needsDisplay = true
        }
        clampScrollOffset()
        updateTrackingAreas()
    }

    public func rebuildLayout() {
        let blocks = session.multiBuffer.blocks
        var layouts: [TerminalBlockLayout] = []
        layouts.reserveCapacity(blocks.count)

        let blockSpacing: CGFloat = 8.0
        var currentY: CGFloat = 0
        var maxCols = 0

        for (index, block) in blocks.enumerated() {
            let lineCount = block.lines.count
            if !block.isCollapsed {
                for line in block.lines {
                    if line.rawText.count > maxCols {
                        maxCols = line.rawText.count
                    }
                }
            }
            let linesHeight: CGFloat = block.isCollapsed ? 0 : CGFloat(lineCount) * lineHeight
            let paddingBottom: CGFloat = (!block.isCollapsed && lineCount > 0) ? 6.0 : 0.0
            let contentH: CGFloat = linesHeight + paddingBottom
            let gap: CGFloat = (index < blocks.count - 1) ? blockSpacing : 0.0
            let totalH = headerHeight + contentH + gap

            let layout = TerminalBlockLayout(
                blockIndex: index,
                blockId: block.id,
                startY: currentY,
                headerHeight: headerHeight,
                contentHeight: contentH,
                totalHeight: totalH,
                isCollapsed: block.isCollapsed,
                lineCount: lineCount
            )
            layouts.append(layout)
            currentY += totalH
        }

        self.blockLayouts = layouts
        self.totalDocumentHeight = currentY + 30.0 // Bottom padding
        self.maxLineWidth = CGFloat(maxCols) * charWidth + codeLeftMargin + 48.0
        self.totalDocumentWidth = max(bounds.width, self.maxLineWidth)

        if !userScrolledAwayFromBottom && session.isProcessRunning {
            scrollToBottom()
        } else {
            clampScrollOffset()
        }

        needsDisplay = true
    }

    public func scrollToBottom() {
        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        scrollOffsetY = maxScrollY
        needsDisplay = true
    }

    private func clampScrollOffset() {
        let maxScrollY = max(0, totalDocumentHeight - bounds.height)
        if scrollOffsetY > maxScrollY {
            scrollOffsetY = maxScrollY
        }
        if scrollOffsetY < 0 {
            scrollOffsetY = 0
        }

        let maxScrollX = max(0, totalDocumentWidth - bounds.width)
        if scrollOffsetX > maxScrollX {
            scrollOffsetX = maxScrollX
        }
        if scrollOffsetX < 0 {
            scrollOffsetX = 0
        }
    }

    // MARK: - Binary Search for Visible Blocks
    private func findVisibleBlockIndices(minY: CGFloat, maxY: CGFloat) -> Range<Int>? {
        guard !blockLayouts.isEmpty else { return nil }

        // Find first block whose contentMaxY > minY
        var low = 0
        var high = blockLayouts.count - 1
        var firstIdx = blockLayouts.count

        while low <= high {
            let mid = (low + high) / 2
            if blockLayouts[mid].contentMaxY > minY {
                firstIdx = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        guard firstIdx < blockLayouts.count else { return nil }

        // Find last block whose startY < maxY
        low = firstIdx
        high = blockLayouts.count - 1
        var lastIdx = firstIdx

        while low <= high {
            let mid = (low + high) / 2
            if blockLayouts[mid].startY < maxY {
                lastIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return firstIdx..<(lastIdx + 1)
    }

    // MARK: - Sticky Header Calculation
    private func currentStickyHeader() -> (layout: TerminalBlockLayout, frame: CGRect)? {
        guard scrollOffsetY > 0, !blockLayouts.isEmpty else { return nil }

        var low = 0
        var high = blockLayouts.count - 1
        var candidateIdx: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if blockLayouts[mid].startY <= scrollOffsetY {
                candidateIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let idx = candidateIdx else { return nil }
        let layout = blockLayouts[idx]
        if scrollOffsetY > layout.startY && scrollOffsetY < layout.contentMaxY {
            guard layout.contentHeight > 0 else { return nil }

            let nextHeaderMinY: CGFloat? = (idx + 1 < blockLayouts.count) ? blockLayouts[idx + 1].startY : nil
            var stickyScreenY: CGFloat = 0
            if let nextMinY = nextHeaderMinY {
                let nextScreenY = nextMinY - scrollOffsetY
                if nextScreenY < headerHeight {
                    stickyScreenY = nextScreenY - headerHeight
                }
            }
            let stickyFrame = CGRect(x: 0, y: stickyScreenY, width: bounds.width, height: headerHeight)
            return (layout, stickyFrame)
        }
        return nil
    }

    // MARK: - Virtualized Drawing Engine
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.clip(to: bounds)
        defer { context.restoreGState() }

        // 1. Background Fill
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)

        let blocks = session.multiBuffer.blocks
        guard !blocks.isEmpty else {
            drawEmptyState(context: context)
            return
        }

        let visibleMinY = scrollOffsetY
        let visibleMaxY = scrollOffsetY + bounds.height

        guard let blockRange = findVisibleBlockIndices(minY: visibleMinY, maxY: visibleMaxY) else {
            drawScrollbar(context: context)
            return
        }

        let stickyInfo = currentStickyHeader()
        let stickyBlockIndex = stickyInfo?.layout.blockIndex

        let selection = normalizedSelection

        // Pass 1: Draw Code Lines (behind headers)
        for blockIdx in blockRange {
            let layout = blockLayouts[blockIdx]
            if layout.isCollapsed || layout.lineCount == 0 { continue }

            let block = blocks[blockIdx]
            let contentStartY = layout.contentMinY

            let rawFirstLine = Int((visibleMinY - contentStartY) / lineHeight)
            let rawLastLine = Int((visibleMaxY - contentStartY) / lineHeight) + 1

            let firstLine = max(0, min(layout.lineCount - 1, rawFirstLine))
            let lastLine = max(firstLine, min(layout.lineCount - 1, rawLastLine))

            guard firstLine <= lastLine else { continue }

            for lineIdx in firstLine...lastLine {
                let lineY = contentStartY + 2.0 + CGFloat(lineIdx) * lineHeight
                let screenY = lineY - scrollOffsetY
                let line = block.lines[lineIdx]
                let ctLine = getOrCreateCTLine(blockIndex: blockIdx, line: line)

                // Draw text selection highlight if line is within selection range
                if let sel = selection,
                   isLineInSelection(blockIdx: blockIdx, lineIdx: lineIdx, sel: sel) {
                    drawSelectionHighlight(
                        blockIdx: blockIdx,
                        lineIdx: lineIdx,
                        line: line,
                        ctLine: ctLine,
                        screenY: screenY,
                        sel: sel,
                        context: context
                    )
                }

                // Draw CoreText Line
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: codeLeftMargin - scrollOffsetX, y: screenY + fontAscent + 2.0)
                context.scaleBy(x: 1.0, y: -1.0)
                CTLineDraw(ctLine, context)
                context.restoreGState()
            }
        }

        // Pass 2: Draw Normal Excerpt Headers
        for blockIdx in blockRange {
            let layout = blockLayouts[blockIdx]
            if blockIdx == stickyBlockIndex {
                // Will be drawn as sticky header on top
                continue
            }

            let screenY = layout.startY - scrollOffsetY
            let headerRect = CGRect(x: 0, y: screenY, width: bounds.width, height: layout.headerHeight)
            drawHeader(
                blockIndex: blockIdx,
                block: blocks[blockIdx],
                in: headerRect,
                isSticky: false,
                context: context
            )
        }

        // Pass 3: Draw Sticky Header (pinned to top)
        if let (stickyLayout, stickyFrame) = stickyInfo {
            let block = blocks[stickyLayout.blockIndex]
            drawHeader(
                blockIndex: stickyLayout.blockIndex,
                block: block,
                in: stickyFrame,
                isSticky: true,
                context: context
            )
        }

        // Pass 4: Draw Overlay Scrollbar
        drawScrollbar(context: context)
    }

    // MARK: - Header Drawing
    private func drawHeader(
        blockIndex: Int,
        block: TerminalBlock,
        in rect: CGRect,
        isSticky: Bool,
        context: CGContext
    ) {
        context.saveGState()

        // 1. Clean flat background spanning full width (opaque to cover scrolling lines)
        let fullWidth = bounds.width
        let headerRect = CGRect(x: 0, y: rect.minY, width: fullWidth, height: rect.height)
        context.setFillColor(theme.excerptHeaderBackground.cgColor)
        context.fill(headerRect)

        // 2. Border top separating command blocks
        let borderTopRect = CGRect(x: 0, y: rect.minY, width: fullWidth, height: 1.0)
        context.setFillColor(theme.excerptHeaderBorder.cgColor)
        context.fill(borderTopRect)

        // 2. Strong, fast fade out for title, chevron, badges, and buttons as soon as header starts being pushed
        let contentAlpha: CGFloat
        if isSticky && rect.minY < 0 {
            // Fades out completely within the first ~45% of being pushed
            let rawProgress = max(0, min(1, (rect.minY + rect.height * 0.45) / (rect.height * 0.45)))
            contentAlpha = pow(rawProgress, 2.0)
        } else {
            contentAlpha = 1.0
        }

        if contentAlpha <= 0.001 {
            context.restoreGState()
            return
        }

        context.saveGState()
        context.setAlpha(contentAlpha)

        let cy = round(rect.midY)
        let headerBaselineY = rect.minY + round(rect.height / 2.0 + (fontAscent - fontDescent) / 2.0) - 1.0

        // 3. Smooth vector chevron
        let cx: CGFloat = headerChevronX
        context.saveGState()
        context.setStrokeColor(theme.gutterForeground.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if block.isCollapsed {
            // chevron.right (>)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 2.5, y: cy - 4.0))
            context.addLine(to: CGPoint(x: cx + 2.5, y: cy))
            context.addLine(to: CGPoint(x: cx - 2.5, y: cy + 4.0))
            context.strokePath()
        } else {
            // chevron.down (v)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 4.0, y: cy - 2.5))
            context.addLine(to: CGPoint(x: cx, y: cy + 2.5))
            context.addLine(to: CGPoint(x: cx + 4.0, y: cy - 2.5))
            context.strokePath()
        }
        context.restoreGState()

        // 3. Folder Name & Command Text (directly after chevron)
        var currentCmdX = headerCommandX
        if let (folderLine, folderWidth) = getOrCreateFolderCTLine(blockIndex: blockIndex, folder: block.folderDisplayName) {
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: currentCmdX, y: headerBaselineY)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(folderLine, context)
            context.restoreGState()

            currentCmdX += folderWidth + 8.0
        }

        let cmdLine = getOrCreateHeaderCTLine(blockIndex: blockIndex, command: block.command)

        // Draw selection highlight on command text if selected
        if let sel = normalizedSelection {
            drawHeaderSelectionHighlight(
                blockIndex: blockIndex,
                command: block.command,
                ctLine: cmdLine,
                commandStartX: currentCmdX,
                headerRect: rect,
                sel: sel,
                context: context
            )
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: currentCmdX, y: headerBaselineY)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(cmdLine, context)
        context.restoreGState()

        // 4. Right Elements: Status Badge / Progress Spinner, Duration, and Action Buttons
        var rightX = rect.width - 16.0

        // Copy button
        let copyRect = CGRect(x: rightX - 20, y: round(cy - 9), width: 18, height: 18)
        let isCopyHovered = (hoveredCopyBlockIndex == blockIndex)
        drawCopyButton(in: copyRect, isHovered: isCopyHovered, context: context)
        rightX -= 26.0

        // Duration string
        let durationText = block.durationString
        if !durationText.isEmpty {
            let durString = NSAttributedString(string: durationText, attributes: [
                .font: badgeFont,
                .foregroundColor: theme.gutterForeground
            ])
            let durLine = CTLineCreateWithAttributedString(durString)
            let durWidth = CGFloat(CTLineGetTypographicBounds(durLine, nil, nil, nil))
            rightX -= durWidth

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rightX, y: headerBaselineY)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(durLine, context)
            context.restoreGState()

            rightX -= 12.0
        }

        // Status indicator: animated circular spinner if running, pill badge if failure/cancelled
        if block.status == .running {
            let spinnerSize: CGFloat = 13.0
            let spinnerRect = CGRect(x: rightX - spinnerSize, y: round(cy - spinnerSize / 2.0), width: spinnerSize, height: spinnerSize)
            drawSpinner(in: spinnerRect, context: context)
            rightX -= (spinnerSize + 8.0)
        } else if block.status != .success {
            let statusString: NSAttributedString
            let statusBgColor: NSColor
            switch block.status {
            case .failure:
                let ec = block.exitCode ?? 1
                statusString = NSAttributedString(string: "✕ \(ec)", attributes: [
                    .font: badgeFont,
                    .foregroundColor: theme.diffDeletedGutter
                ])
                statusBgColor = theme.diffDeletedGutter.withAlphaComponent(0.15)
            case .cancelled:
                statusString = NSAttributedString(string: "⊘ CANCELLED", attributes: [
                    .font: badgeFont,
                    .foregroundColor: theme.gutterForeground
                ])
                statusBgColor = theme.gutterForeground.withAlphaComponent(0.15)
            default:
                statusString = NSAttributedString()
                statusBgColor = .clear
            }

            let stLine = CTLineCreateWithAttributedString(statusString)
            let stWidth = CGFloat(CTLineGetTypographicBounds(stLine, nil, nil, nil))
            let badgePillWidth = stWidth + 12.0
            let badgePillHeight: CGFloat = 18.0
            let badgeRect = CGRect(x: rightX - badgePillWidth, y: round(cy - badgePillHeight / 2.0), width: badgePillWidth, height: badgePillHeight)

            // Pill background
            let pillPath = CGPath(roundedRect: badgeRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            context.saveGState()
            context.setFillColor(statusBgColor.cgColor)
            context.addPath(pillPath)
            context.fillPath()
            context.restoreGState()

            let badgeAscent = CTFontGetAscent(badgeFont as CTFont)
            let badgeDescent = CTFontGetDescent(badgeFont as CTFont)
            let badgeBaselineY = badgeRect.minY + round(badgePillHeight / 2.0 + (badgeAscent - badgeDescent) / 2.0) - 1.0

            // Text inside pill
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: badgeRect.minX + 6.0, y: badgeBaselineY)
            context.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(stLine, context)
            context.restoreGState()
        }

        context.restoreGState() // Restore contentAlpha state
        context.restoreGState() // Restore outer header state
    }

    private func drawSpinner(in rect: CGRect, context: CGContext) {
        context.saveGState()
        let cx = rect.midX
        let cy = rect.midY
        let tickCount = 8
        let angleStep = (2.0 * .pi) / CGFloat(tickCount)
        let innerRadius: CGFloat = 2.8
        let outerRadius: CGFloat = 5.8

        let now = Date().timeIntervalSinceReferenceDate
        let activeTick = Int(now * 10.0) % tickCount

        context.setLineWidth(1.4)
        context.setLineCap(.round)

        for i in 0..<tickCount {
            let angle = CGFloat(i) * angleStep
            let cosA = cos(angle)
            let sinA = sin(angle)

            let p1 = CGPoint(x: cx + innerRadius * cosA, y: cy + innerRadius * sinA)
            let p2 = CGPoint(x: cx + outerRadius * cosA, y: cy + outerRadius * sinA)

            let distance = (i - activeTick + tickCount) % tickCount
            let alpha = max(0.18, 1.0 - CGFloat(distance) * 0.11)

            context.setStrokeColor(theme.accentColor.withAlphaComponent(alpha).cgColor)
            context.beginPath()
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawCopyButton(in rect: CGRect, isHovered: Bool, context: CGContext) {
        if isHovered {
            let bgPath = CGPath(roundedRect: rect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            context.saveGState()
            context.setFillColor(theme.gutterForeground.withAlphaComponent(0.18).cgColor)
            context.addPath(bgPath)
            context.fillPath()
            context.restoreGState()
        }

        // Draw copy icon (two overlapping squares)
        context.saveGState()
        context.setStrokeColor((isHovered ? theme.foreground : theme.gutterForeground).cgColor)
        context.setLineWidth(1.2)
        let m = rect.midX
        let my = rect.midY

        // Back square
        context.stroke(CGRect(x: m - 4, y: my - 6, width: 8, height: 8))
        // Front square
        context.stroke(CGRect(x: m - 6, y: my - 4, width: 8, height: 8))
        context.restoreGState()
    }

    // MARK: - Selection Rendering & Hit Testing
    private func isLineInSelection(blockIdx: Int, lineIdx: Int, sel: (start: TerminalDocumentPoint, end: TerminalDocumentPoint)) -> Bool {
        let lineStart = TerminalDocumentPoint(blockIndex: blockIdx, lineIndex: lineIdx, columnIndex: 0)
        let lineEnd = TerminalDocumentPoint(blockIndex: blockIdx, lineIndex: lineIdx, columnIndex: Int.max)
        return lineEnd >= sel.start && lineStart <= sel.end
    }

    private func drawHeaderSelectionHighlight(
        blockIndex: Int,
        command: String,
        ctLine: CTLine,
        commandStartX: CGFloat,
        headerRect: CGRect,
        sel: (start: TerminalDocumentPoint, end: TerminalDocumentPoint),
        context: CGContext
    ) {
        guard isLineInSelection(blockIdx: blockIndex, lineIdx: -1, sel: sel) else { return }

        let isStart = (sel.start.blockIndex == blockIndex && sel.start.lineIndex == -1)
        let isEnd = (sel.end.blockIndex == blockIndex && sel.end.lineIndex == -1)

        let charCount = command.count
        guard charCount > 0 else { return }

        let startCol = isStart ? max(0, min(charCount, sel.start.columnIndex)) : 0
        let endCol = isEnd ? max(0, min(charCount, sel.end.columnIndex)) : charCount

        guard startCol < endCol else { return }

        let startX = ctLine.xOffset(forCharacterIndex: startCol, in: command)
        let endX = ctLine.xOffset(forCharacterIndex: endCol, in: command)

        let selRect = CGRect(
            x: commandStartX + startX,
            y: headerRect.minY + 4.0,
            width: max(3.0, endX - startX),
            height: headerRect.height - 8.0
        )

        let selColor = theme.selectionBackground.withAlphaComponent(max(0.35, theme.selectionBackground.alphaComponent))
        context.saveGState()
        let path = CGPath(roundedRect: selRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
        context.setFillColor(selColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private func drawSelectionHighlight(
        blockIdx: Int,
        lineIdx: Int,
        line: TerminalBlockLine,
        ctLine: CTLine,
        screenY: CGFloat,
        sel: (start: TerminalDocumentPoint, end: TerminalDocumentPoint),
        context: CGContext
    ) {
        let isStartLine = (sel.start.blockIndex == blockIdx && sel.start.lineIndex == lineIdx)
        let isEndLine = (sel.end.blockIndex == blockIdx && sel.end.lineIndex == lineIdx)

        let text = line.rawText
        let charCount = text.count
        guard charCount > 0 else { return }

        let startCol = isStartLine ? max(0, min(charCount, sel.start.columnIndex)) : 0
        let endCol = isEndLine ? max(0, min(charCount, sel.end.columnIndex)) : charCount

        guard startCol < endCol else { return }

        let startOffset = ctLine.xOffset(forCharacterIndex: startCol, in: text)
        let endOffset = ctLine.xOffset(forCharacterIndex: endCol, in: text)

        let selRect = CGRect(
            x: codeLeftMargin + startOffset - scrollOffsetX,
            y: screenY,
            width: max(2.0, endOffset - startOffset),
            height: lineHeight
        )

        let selColor = theme.selectionBackground.withAlphaComponent(max(0.35, theme.selectionBackground.alphaComponent))
        context.saveGState()
        context.setFillColor(selColor.cgColor)
        context.fill(selRect)
        context.restoreGState()
    }

    // MARK: - CTLine Creation & Caching
    private func getOrCreateCTLine(blockIndex: Int, line: TerminalBlockLine) -> CTLine {
        let key = (UInt64(blockIndex) << 32) | UInt64(UInt32(line.id & 0x7FFFFFFF))
        if let cached = lineCache[key] {
            return cached
        }

        let attrString = buildAttributedString(for: line)
        let ctLine = CTLineCreateWithAttributedString(attrString)
        lineCache[key] = ctLine
        return ctLine
    }

    private func getOrCreateFolderCTLine(blockIndex: Int, folder: String) -> (CTLine, CGFloat)? {
        guard !folder.isEmpty else { return nil }
        let key = (UInt64(blockIndex) << 32) | 0xFFFFFFFE
        if let cached = lineCache[key] {
            let width = CGFloat(CTLineGetTypographicBounds(cached, nil, nil, nil))
            return (cached, width)
        }

        let attrString = NSAttributedString(string: folder, attributes: [
            .font: headerFont,
            .foregroundColor: theme.gutterForeground
        ])
        let line = CTLineCreateWithAttributedString(attrString)
        lineCache[key] = line
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (line, width)
    }

    private func commandStartX(for blockIndex: Int, block: TerminalBlock) -> CGFloat {
        if let (_, width) = getOrCreateFolderCTLine(blockIndex: blockIndex, folder: block.folderDisplayName) {
            return headerCommandX + width + 8.0
        }
        return headerCommandX
    }

    private func getOrCreateHeaderCTLine(blockIndex: Int, command: String) -> CTLine {
        let key = (UInt64(blockIndex) << 32) | 0xFFFFFFFF
        if let cached = lineCache[key] {
            return cached
        }

        let attrString = NSAttributedString(string: command, attributes: [
            .font: headerFont,
            .foregroundColor: theme.foreground
        ])
        let line = CTLineCreateWithAttributedString(attrString)
        lineCache[key] = line
        return line
    }

    private func buildAttributedString(for line: TerminalBlockLine) -> NSAttributedString {
        guard !line.spans.isEmpty else {
            return NSAttributedString(string: line.rawText, attributes: [
                .font: regularFont,
                .foregroundColor: theme.foreground
            ])
        }

        let result = NSMutableAttributedString()
        for span in line.spans {
            guard !span.text.isEmpty else { continue }

            var attrs: [NSAttributedString.Key: Any] = [:]

            // Font weight & style
            if span.bold && span.italic {
                attrs[.font] = boldFont
            } else if span.bold {
                attrs[.font] = boldFont
            } else if span.italic {
                attrs[.font] = italicFont
            } else {
                attrs[.font] = regularFont
            }

            // Foreground Color
            if span.fg == .default {
                attrs[.foregroundColor] = theme.foreground
            } else {
                let (r, g, b) = span.fg.rgb(
                    defaultForeground: (Double(theme.foreground.redComponent), Double(theme.foreground.greenComponent), Double(theme.foreground.blueComponent))
                )
                attrs[.foregroundColor] = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
            }

            // Background Color
            if span.bg != .default {
                let (r, g, b) = span.bg.rgb()
                attrs[.backgroundColor] = NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 0.8)
            }

            // Underline
            if span.underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: span.text, attributes: attrs))
        }

        return result
    }

    // MARK: - Overlay Scrollbar Drawing
    private func drawScrollbar(context: CGContext) {
        guard scrollbarAlpha > 0.001 else { return }

        let thumbColor = (theme.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.35 * scrollbarAlpha)
        let visibleH = bounds.height
        let visibleW = bounds.width

        let showVertical = (visibleScrollbarAxis == .vertical || visibleScrollbarAxis == nil || scrollbarDragKind == .vertical)
        let showHorizontal = (visibleScrollbarAxis == .horizontal || visibleScrollbarAxis == nil || scrollbarDragKind == .horizontal)

        // 1. Vertical Scrollbar
        if showVertical && totalDocumentHeight > visibleH {
            let scrollbarWidth: CGFloat = 6.0
            let rightMargin: CGFloat = 2.0
            let minThumbHeight: CGFloat = 24.0
            let trackHeight = visibleH - (totalDocumentWidth > visibleW ? 10.0 : 0.0)
            let thumbHeight = max(minThumbHeight, (visibleH / totalDocumentHeight) * trackHeight)
            let maxScrollY = totalDocumentHeight - visibleH
            let scrollFraction = max(0, min(1, scrollOffsetY / maxScrollY))
            let thumbY = scrollFraction * (trackHeight - thumbHeight)

            let thumbRect = CGRect(
                x: bounds.width - scrollbarWidth - rightMargin,
                y: thumbY,
                width: scrollbarWidth,
                height: thumbHeight
            )

            context.saveGState()
            context.setFillColor(thumbColor.cgColor)
            let path = CGPath(roundedRect: thumbRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        // 2. Horizontal Scrollbar
        if showHorizontal && totalDocumentWidth > visibleW {
            let scrollbarHeight: CGFloat = 6.0
            let bottomMargin: CGFloat = 2.0
            let minThumbWidth: CGFloat = 30.0
            let trackWidth = visibleW - (totalDocumentHeight > visibleH ? 10.0 : 0.0)
            let thumbWidth = max(minThumbWidth, (visibleW / totalDocumentWidth) * trackWidth)
            let maxScrollX = totalDocumentWidth - visibleW
            let scrollFraction = max(0, min(1, scrollOffsetX / maxScrollX))
            let thumbX = scrollFraction * (trackWidth - thumbWidth)

            let thumbRect = CGRect(
                x: thumbX,
                y: bounds.height - scrollbarHeight - bottomMargin,
                width: thumbWidth,
                height: scrollbarHeight
            )

            context.saveGState()
            context.setFillColor(thumbColor.cgColor)
            let path = CGPath(roundedRect: thumbRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private func showScrollbarsWithAutohide(for axis: ScrollAxis) {
        scrollbarHideTimer?.invalidate()
        fadeAnimationTimer?.invalidate()
        visibleScrollbarAxis = axis
        scrollbarAlpha = 1.0
        scrollbarHideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.startScrollbarFadeOut()
        }
        needsDisplay = true
    }

    private func startScrollbarFadeOut() {
        guard scrollbarDragKind == nil else { return }
        fadeAnimationTimer?.invalidate()
        fadeAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.scrollbarAlpha -= 0.12
            if self.scrollbarAlpha <= 0 {
                self.scrollbarAlpha = 0
                self.visibleScrollbarAxis = nil
                timer.invalidate()
            }
            self.needsDisplay = true
        }
    }

    // MARK: - Empty State
    private func drawEmptyState(context: CGContext) {
        let midX = bounds.midX
        let centerY = bounds.midY - 24.0

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 4.0

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: theme.foreground,
            .paragraphStyle: paragraphStyle
        ]
        let titleString = NSAttributedString(string: "Terminal MultiBuffer", attributes: titleAttrs)
        let titleSize = titleString.size()

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: theme.gutterForeground,
            .paragraphStyle: paragraphStyle
        ]
        let subString = NSAttributedString(
            string: "Commands run here become virtualized, collapsible code sections.\nContinuous text selection, 120 FPS scrolling, and full command history.",
            attributes: subAttrs
        )
        let subSize = subString.size()

        let spacing: CGFloat = 8.0
        let totalH = titleSize.height + spacing + subSize.height
        let startY = centerY - totalH / 2.0

        let titleRect = CGRect(
            x: midX - titleSize.width / 2.0,
            y: startY,
            width: titleSize.width,
            height: titleSize.height
        )
        let subWidth = max(subSize.width, 480.0)
        let subRect = CGRect(
            x: midX - subWidth / 2.0,
            y: startY + titleSize.height + spacing,
            width: subWidth,
            height: subSize.height + 6.0
        )

        titleString.draw(in: titleRect)
        subString.draw(in: subRect)
    }

    // MARK: - Mouse Events & Hit Testing
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screenPoint = convert(event.locationInWindow, from: nil)

        // 1. Scrollbar hit-testing
        let visibleH = bounds.height
        let visibleW = bounds.width

        // Vertical scrollbar
        if totalDocumentHeight > visibleH && screenPoint.x >= bounds.width - 12.0 {
            scrollbarDragKind = .vertical
            scrollbarDragStartPos = screenPoint.y
            scrollbarDragStartScroll = scrollOffsetY
            showScrollbarsWithAutohide(for: .vertical)
            return
        }

        // Horizontal scrollbar
        if totalDocumentWidth > visibleW && screenPoint.y >= bounds.height - 12.0 {
            scrollbarDragKind = .horizontal
            scrollbarDragStartPos = screenPoint.x
            scrollbarDragStartScroll = scrollOffsetX
            showScrollbarsWithAutohide(for: .horizontal)
            return
        }

        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX

        // 2. Sticky Header hit-testing
        if let (stickyLayout, stickyFrame) = currentStickyHeader(), stickyFrame.minY >= -headerHeight * 0.45, stickyFrame.contains(screenPoint) {
            handleHeaderClick(blockIndex: stickyLayout.blockIndex, clickX: screenPoint.x, screenPoint: screenPoint, event: event)
            return
        }

        // 3. Normal Header hit-testing
        for layout in blockLayouts {
            if docY >= layout.headerMinY && docY <= layout.headerMaxY {
                handleHeaderClick(blockIndex: layout.blockIndex, clickX: screenPoint.x, screenPoint: screenPoint, event: event)
                return
            }
        }

        // 4. Code Area hit-testing -> Text Selection
        if let point = documentPoint(at: CGPoint(x: docX, y: docY), clampForDrag: false) {
            let isShift = event.modifierFlags.contains(.shift)

            if event.clickCount == 2 {
                // Word selection
                let block = session.multiBuffer.blocks[point.blockIndex]
                let text = (point.lineIndex == -1) ? block.command : ((point.lineIndex < block.lines.count) ? block.lines[point.lineIndex].rawText : "")
                let (wStart, wEnd) = wordRange(in: text, at: point.columnIndex)
                selectionAnchor = TerminalDocumentPoint(blockIndex: point.blockIndex, lineIndex: point.lineIndex, columnIndex: wStart)
                cursorPoint = TerminalDocumentPoint(blockIndex: point.blockIndex, lineIndex: point.lineIndex, columnIndex: wEnd)
                selectionGranularity = .word(anchorWordStart: wStart, anchorWordEnd: wEnd, blockIndex: point.blockIndex, lineIndex: point.lineIndex)
                isDraggingSelection = true
                needsDisplay = true
                return
            } else if event.clickCount >= 3 {
                // Line selection
                let block = session.multiBuffer.blocks[point.blockIndex]
                let lineLen = (point.lineIndex == -1) ? block.command.count : ((point.lineIndex < block.lines.count) ? block.lines[point.lineIndex].rawText.count : 0)
                selectionAnchor = TerminalDocumentPoint(blockIndex: point.blockIndex, lineIndex: point.lineIndex, columnIndex: 0)
                cursorPoint = TerminalDocumentPoint(blockIndex: point.blockIndex, lineIndex: point.lineIndex, columnIndex: lineLen)
                selectionGranularity = .line(blockIndex: point.blockIndex, lineIndex: point.lineIndex)
                isDraggingSelection = true
                needsDisplay = true
                return
            }

            // Single click character selection
            selectionGranularity = .character
            if isShift {
                if selectionAnchor == nil {
                    selectionAnchor = cursorPoint ?? point
                }
            } else {
                selectionAnchor = point
            }
            cursorPoint = point
            isDraggingSelection = true
            needsDisplay = true
        } else {
            // Click outside
            selectionAnchor = nil
            cursorPoint = nil
            needsDisplay = true
        }
    }

    private func handleHeaderClick(blockIndex: Int, clickX: CGFloat, screenPoint: CGPoint, event: NSEvent) {
        guard blockIndex >= 0 && blockIndex < session.multiBuffer.blocks.count else { return }
        let block = session.multiBuffer.blocks[blockIndex]

        // 1. Copy button hit: bounds.width - 36 to bounds.width - 16
        let copyBtnX = bounds.width - 36.0
        if screenPoint.x >= copyBtnX && screenPoint.x <= bounds.width - 16.0 {
            copyBlockOutput(block: block)
            return
        }

        // 2. Chevron & prompt click (clickX < cmdStartX) -> toggle collapse if on chevron, or select
        let cmdStartX = commandStartX(for: blockIndex, block: block)
        if clickX < headerCommandX {
            session.multiBuffer.toggleCollapse(id: block.id)
            rebuildLayout()
            window?.invalidateCursorRects(for: self)
            return
        }

        // 3. Command text click (clickX >= cmdStartX) -> text selection within command!
        let cmdLine = getOrCreateHeaderCTLine(blockIndex: blockIndex, command: block.command)
        let relX = max(0, clickX - cmdStartX)
        let col = cmdLine.characterIndex(at: relX, in: block.command)
        let point = TerminalDocumentPoint(blockIndex: blockIndex, lineIndex: -1, columnIndex: col)

        if event.clickCount == 2 {
            // Word selection in command
            let (wStart, wEnd) = wordRange(in: block.command, at: col)
            selectionAnchor = TerminalDocumentPoint(blockIndex: blockIndex, lineIndex: -1, columnIndex: wStart)
            cursorPoint = TerminalDocumentPoint(blockIndex: blockIndex, lineIndex: -1, columnIndex: wEnd)
            selectionGranularity = .word(anchorWordStart: wStart, anchorWordEnd: wEnd, blockIndex: blockIndex, lineIndex: -1)
            isDraggingSelection = true
            needsDisplay = true
            return
        } else if event.clickCount >= 3 {
            // Full command line selection
            selectionAnchor = TerminalDocumentPoint(blockIndex: blockIndex, lineIndex: -1, columnIndex: 0)
            cursorPoint = TerminalDocumentPoint(blockIndex: blockIndex, lineIndex: -1, columnIndex: block.command.count)
            selectionGranularity = .line(blockIndex: blockIndex, lineIndex: -1)
            isDraggingSelection = true
            needsDisplay = true
            return
        }

        // Single click
        selectionGranularity = .character
        if event.modifierFlags.contains(.shift) {
            if selectionAnchor == nil {
                selectionAnchor = cursorPoint ?? point
            }
        } else {
            selectionAnchor = point
        }
        cursorPoint = point
        isDraggingSelection = true
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let screenPoint = convert(event.locationInWindow, from: nil)

        // Scrollbar drag
        if let dragKind = scrollbarDragKind {
            switch dragKind {
            case .vertical:
                let deltaY = screenPoint.y - scrollbarDragStartPos
                let visibleH = bounds.height
                let maxScrollY = max(0, totalDocumentHeight - visibleH)
                let scrollChange = (deltaY / visibleH) * totalDocumentHeight
                scrollOffsetY = max(0, min(maxScrollY, scrollbarDragStartScroll + scrollChange))
                showScrollbarsWithAutohide(for: .vertical)
            case .horizontal:
                let deltaX = screenPoint.x - scrollbarDragStartPos
                let visibleW = bounds.width
                let maxScrollX = max(0, totalDocumentWidth - visibleW)
                let scrollChange = (deltaX / visibleW) * totalDocumentWidth
                scrollOffsetX = max(0, min(maxScrollX, scrollbarDragStartScroll + scrollChange))
                showScrollbarsWithAutohide(for: .horizontal)
            }
            return
        }

        guard isDraggingSelection else { return }

        // Autoscroll when dragging near vertical edges
        if screenPoint.y < 20 && scrollOffsetY > 0 {
            scrollOffsetY = max(0, scrollOffsetY - 12)
            showScrollbarsWithAutohide(for: .vertical)
        } else if screenPoint.y > bounds.height - 20 {
            let maxScrollY = max(0, totalDocumentHeight - bounds.height)
            if scrollOffsetY < maxScrollY {
                scrollOffsetY = min(maxScrollY, scrollOffsetY + 12)
                showScrollbarsWithAutohide(for: .vertical)
            }
        }

        // Autoscroll when dragging near horizontal edges
        if screenPoint.x < 20 && scrollOffsetX > 0 {
            scrollOffsetX = max(0, scrollOffsetX - 12)
            showScrollbarsWithAutohide(for: .horizontal)
        } else if screenPoint.x > bounds.width - 20 {
            let maxScrollX = max(0, totalDocumentWidth - bounds.width)
            if scrollOffsetX < maxScrollX {
                scrollOffsetX = min(maxScrollX, scrollOffsetX + 12)
                showScrollbarsWithAutohide(for: .horizontal)
            }
        }

        let docY = screenPoint.y + scrollOffsetY
        let docX = screenPoint.x + scrollOffsetX

        if let targetPoint = documentPoint(at: CGPoint(x: docX, y: docY), clampForDrag: true) {
            switch selectionGranularity {
            case .character:
                cursorPoint = targetPoint
            case .word(let initStart, let initEnd, let initBlock, let initLine):
                let targetText: String
                let blocks = session.multiBuffer.blocks
                if targetPoint.blockIndex < blocks.count {
                    let b = blocks[targetPoint.blockIndex]
                    if targetPoint.lineIndex == -1 {
                        targetText = b.command
                    } else if targetPoint.lineIndex < b.lines.count {
                        targetText = b.lines[targetPoint.lineIndex].rawText
                    } else {
                        targetText = ""
                    }
                } else {
                    targetText = ""
                }

                let (curStart, curEnd) = wordRange(in: targetText, at: targetPoint.columnIndex)
                if targetPoint > TerminalDocumentPoint(blockIndex: initBlock, lineIndex: initLine, columnIndex: initStart) {
                    selectionAnchor = TerminalDocumentPoint(blockIndex: initBlock, lineIndex: initLine, columnIndex: initStart)
                    cursorPoint = TerminalDocumentPoint(blockIndex: targetPoint.blockIndex, lineIndex: targetPoint.lineIndex, columnIndex: curEnd)
                } else {
                    selectionAnchor = TerminalDocumentPoint(blockIndex: initBlock, lineIndex: initLine, columnIndex: initEnd)
                    cursorPoint = TerminalDocumentPoint(blockIndex: targetPoint.blockIndex, lineIndex: targetPoint.lineIndex, columnIndex: curStart)
                }
            case .line(let initBlock, let initLine):
                let targetText: String
                let blocks = session.multiBuffer.blocks
                if targetPoint.blockIndex < blocks.count {
                    let b = blocks[targetPoint.blockIndex]
                    if targetPoint.lineIndex == -1 {
                        targetText = b.command
                    } else if targetPoint.lineIndex < b.lines.count {
                        targetText = b.lines[targetPoint.lineIndex].rawText
                    } else {
                        targetText = ""
                    }
                } else {
                    targetText = ""
                }

                if targetPoint.blockIndex > initBlock || (targetPoint.blockIndex == initBlock && targetPoint.lineIndex >= initLine) {
                    selectionAnchor = TerminalDocumentPoint(blockIndex: initBlock, lineIndex: initLine, columnIndex: 0)
                    cursorPoint = TerminalDocumentPoint(blockIndex: targetPoint.blockIndex, lineIndex: targetPoint.lineIndex, columnIndex: targetText.count)
                } else {
                    let initText: String
                    if initBlock < blocks.count {
                        let ib = blocks[initBlock]
                        initText = (initLine == -1) ? ib.command : ((initLine < ib.lines.count) ? ib.lines[initLine].rawText : "")
                    } else {
                        initText = ""
                    }
                    selectionAnchor = TerminalDocumentPoint(blockIndex: initBlock, lineIndex: initLine, columnIndex: initText.count)
                    cursorPoint = TerminalDocumentPoint(blockIndex: targetPoint.blockIndex, lineIndex: targetPoint.lineIndex, columnIndex: 0)
                }
            }
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if let dragKind = scrollbarDragKind {
            scrollbarDragKind = nil
            showScrollbarsWithAutohide(for: dragKind)
        }
        isDraggingSelection = false
        selectionGranularity = .character
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let screenPoint = convert(event.locationInWindow, from: nil)

        // Check copy button hover
        let copyBtnX = bounds.width - 36.0
        var newCopyBlock: Int? = nil

        for layout in blockLayouts {
            let isHeaderY: Bool
            if let (stickyLayout, stickyFrame) = currentStickyHeader(), stickyLayout.blockIndex == layout.blockIndex {
                isHeaderY = (stickyFrame.minY >= -layout.headerHeight * 0.45) && stickyFrame.contains(screenPoint)
            } else {
                let screenHeaderY = layout.startY - scrollOffsetY
                isHeaderY = (screenPoint.y >= screenHeaderY && screenPoint.y <= screenHeaderY + layout.headerHeight)
            }

            if isHeaderY && screenPoint.x >= copyBtnX && screenPoint.x <= bounds.width - 16.0 {
                newCopyBlock = layout.blockIndex
                break
            }
        }

        if newCopyBlock != hoveredCopyBlockIndex {
            hoveredCopyBlockIndex = newCopyBlock
            needsDisplay = true
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()

        // 1. Text selection I-Beam cursor across the document area
        addCursorRect(bounds, cursor: .iBeam)

        // 2. Pointing hand cursor over chevrons and copy buttons
        for layout in blockLayouts {
            let screenHeaderY = layout.startY - scrollOffsetY
            if screenHeaderY + layout.headerHeight < 0 || screenHeaderY > bounds.height { continue }

            // Chevron and prompt area
            let chevronRect = CGRect(x: 0, y: screenHeaderY, width: headerCommandX, height: layout.headerHeight)
            addCursorRect(chevronRect, cursor: .pointingHand)

            // Copy button
            let copyBtnRect = CGRect(x: bounds.width - 38.0, y: screenHeaderY + 4, width: 22, height: 20)
            addCursorRect(copyBtnRect, cursor: .pointingHand)
        }

        // 3. Arrow cursor over scrollbar tracks
        if totalDocumentHeight > bounds.height {
            let scrollbarRect = CGRect(x: bounds.width - 12.0, y: 0, width: 12.0, height: bounds.height)
            addCursorRect(scrollbarRect, cursor: .arrow)
        }
        if totalDocumentWidth > bounds.width {
            let hScrollbarRect = CGRect(x: 0, y: bounds.height - 12.0, width: bounds.width, height: 12.0)
            addCursorRect(hScrollbarRect, cursor: .arrow)
        }
    }

    public override func updateTrackingAreas() {
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    // MARK: - Precise Scroll Wheel Engine
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

        // Keep one axis locked for the complete gesture
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

        var changed = false

        let targetScrollY = max(0, min(maxScrollY, scrollOffsetY - dy))
        let targetScrollX = max(0, min(maxScrollX, scrollOffsetX - dx))

        if abs(targetScrollY - scrollOffsetY) > 0.001 {
            scrollOffsetY = targetScrollY
            userScrolledAwayFromBottom = (scrollOffsetY < maxScrollY - 24.0)
            changed = true
        }

        if abs(targetScrollX - scrollOffsetX) > 0.001 {
            scrollOffsetX = targetScrollX
            changed = true
        }

        if changed {
            showScrollbarsWithAutohide(for: scrollbarAxis)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }

        if event.phase == .ended || event.phase == .cancelled {
            scrollLockAxis = nil
        }
    }


    // MARK: - Hit Testing Helpers
    public func documentPoint(at docPoint: CGPoint, clampForDrag: Bool = false) -> TerminalDocumentPoint? {
        let blocks = session.multiBuffer.blocks
        guard !blocks.isEmpty, !blockLayouts.isEmpty else { return nil }

        // Top clamp for drag
        if clampForDrag && docPoint.y <= 0 {
            return TerminalDocumentPoint(blockIndex: 0, lineIndex: -1, columnIndex: 0)
        }

        // Bottom clamp for drag
        if clampForDrag && docPoint.y >= totalDocumentHeight {
            let lastIdx = blocks.count - 1
            let lastBlock = blocks[lastIdx]
            if !lastBlock.isCollapsed && !lastBlock.lines.isEmpty {
                let lastLineIdx = lastBlock.lines.count - 1
                return TerminalDocumentPoint(blockIndex: lastIdx, lineIndex: lastLineIdx, columnIndex: lastBlock.lines[lastLineIdx].rawText.count)
            } else {
                return TerminalDocumentPoint(blockIndex: lastIdx, lineIndex: -1, columnIndex: lastBlock.command.count)
            }
        }

        for (idx, layout) in blockLayouts.enumerated() {
            let bIdx = layout.blockIndex
            guard bIdx < blocks.count else { continue }
            let block = blocks[bIdx]

            // 1. Header hit
            if docPoint.y >= layout.headerMinY && docPoint.y < layout.headerMaxY {
                let cmdLine = getOrCreateHeaderCTLine(blockIndex: bIdx, command: block.command)
                let cmdStartX = commandStartX(for: bIdx, block: block)
                let relX = max(0, (docPoint.x - scrollOffsetX) - cmdStartX)
                let col = cmdLine.characterIndex(at: relX, in: block.command)
                return TerminalDocumentPoint(blockIndex: bIdx, lineIndex: -1, columnIndex: col)
            }

            // 2. Content hit
            if docPoint.y >= layout.contentMinY && docPoint.y <= layout.contentMaxY {
                if layout.isCollapsed || block.lines.isEmpty {
                    return TerminalDocumentPoint(blockIndex: bIdx, lineIndex: -1, columnIndex: block.command.count)
                }

                let rawLineIdx = Int((docPoint.y - (layout.contentMinY + 2.0)) / lineHeight)
                let lineIdx = max(0, min(block.lines.count - 1, rawLineIdx))
                let line = block.lines[lineIdx]
                let ctLine = getOrCreateCTLine(blockIndex: bIdx, line: line)
                let relX = max(0, docPoint.x - codeLeftMargin)
                let col = ctLine.characterIndex(at: relX, in: line.rawText)
                return TerminalDocumentPoint(blockIndex: bIdx, lineIndex: lineIdx, columnIndex: col)
            }

            // 3. Gap hit during drag
            if clampForDrag && docPoint.y > layout.contentMaxY {
                let nextHeaderY = (idx + 1 < blockLayouts.count) ? blockLayouts[idx + 1].headerMinY : totalDocumentHeight
                if docPoint.y < nextHeaderY {
                    if !layout.isCollapsed && !block.lines.isEmpty {
                        let lastLineIdx = block.lines.count - 1
                        return TerminalDocumentPoint(blockIndex: bIdx, lineIndex: lastLineIdx, columnIndex: block.lines[lastLineIdx].rawText.count)
                    } else {
                        return TerminalDocumentPoint(blockIndex: bIdx, lineIndex: -1, columnIndex: block.command.count)
                    }
                }
            }
        }

        if clampForDrag {
            let lastIdx = blocks.count - 1
            let lastBlock = blocks[lastIdx]
            return TerminalDocumentPoint(blockIndex: lastIdx, lineIndex: -1, columnIndex: lastBlock.command.count)
        }

        return nil
    }

    private func wordRange(in text: String, at charIndex: Int) -> (start: Int, end: Int) {
        guard !text.isEmpty else { return (0, 0) }
        let clamped = max(0, min(text.count - 1, charIndex))
        let chars = Array(text)

        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "."
        }

        var start = clamped
        while start > 0 && isWordChar(chars[start - 1]) {
            start -= 1
        }

        var end = clamped
        while end < chars.count && isWordChar(chars[end]) {
            end += 1
        }

        return (start, max(start, end))
    }

    // MARK: - Actions & Keyboard
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd + C
        if flags == .command && event.charactersIgnoringModifiers == "c" {
            copy(nil)
            return true
        }

        // Cmd + A
        if flags == .command && event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    @objc public func copy(_ sender: Any?) {
        if let sel = normalizedSelection {
            let text = extractText(in: sel)
            if !text.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                return
            }
        }

        // If no selection, copy the active or latest block output
        if let hoveredIdx = hoveredCopyBlockIndex ?? hoveredHeaderBlockIndex,
           hoveredIdx < session.multiBuffer.blocks.count {
            copyBlockOutput(block: session.multiBuffer.blocks[hoveredIdx])
            return
        }

        if let lastBlock = session.multiBuffer.blocks.last {
            copyBlockOutput(block: lastBlock)
        }
    }

    @objc public override func selectAll(_ sender: Any?) {
        let blocks = session.multiBuffer.blocks
        guard !blocks.isEmpty else { return }

        let firstPoint = TerminalDocumentPoint(blockIndex: 0, lineIndex: 0, columnIndex: 0)
        let lastBlockIdx = blocks.count - 1
        let lastBlock = blocks[lastBlockIdx]
        let lastLineIdx = max(0, lastBlock.lines.count - 1)
        let lastLineLen = lastBlock.lines.isEmpty ? 0 : lastBlock.lines[lastLineIdx].rawText.count

        selectionAnchor = firstPoint
        cursorPoint = TerminalDocumentPoint(blockIndex: lastBlockIdx, lineIndex: lastLineIdx, columnIndex: lastLineLen)
        needsDisplay = true
    }

    public func extractText(in sel: (start: TerminalDocumentPoint, end: TerminalDocumentPoint)) -> String {
        let blocks = session.multiBuffer.blocks
        var resultLines: [String] = []

        for bIdx in sel.start.blockIndex...sel.end.blockIndex {
            guard bIdx >= 0 && bIdx < blocks.count else { continue }
            let block = blocks[bIdx]

            let startLine = (bIdx == sel.start.blockIndex) ? sel.start.lineIndex : -1
            let endLine = (bIdx == sel.end.blockIndex) ? min(block.lines.count - 1, sel.end.lineIndex) : block.lines.count - 1

            // 1. Check command header line (line -1)
            if startLine <= -1 && endLine >= -1 {
                let cmd = block.command
                let isStart = (bIdx == sel.start.blockIndex && sel.start.lineIndex == -1)
                let isEnd = (bIdx == sel.end.blockIndex && sel.end.lineIndex == -1)
                let startCol = isStart ? max(0, min(cmd.count, sel.start.columnIndex)) : 0
                let endCol = isEnd ? max(0, min(cmd.count, sel.end.columnIndex)) : cmd.count
                if startCol < endCol && endCol <= cmd.count {
                    let sIdx = cmd.index(cmd.startIndex, offsetBy: startCol)
                    let eIdx = cmd.index(cmd.startIndex, offsetBy: endCol)
                    resultLines.append(String(cmd[sIdx..<eIdx]))
                }
            }

            // 2. Check output lines (0..<block.lines.count)
            guard !block.isCollapsed && !block.lines.isEmpty else { continue }
            let actualStartLine = max(0, startLine)
            guard actualStartLine <= endLine else { continue }

            for lIdx in actualStartLine...endLine {
                guard lIdx >= 0 && lIdx < block.lines.count else { continue }
                let line = block.lines[lIdx]
                let isFirst = (bIdx == sel.start.blockIndex && lIdx == sel.start.lineIndex)
                let isLast = (bIdx == sel.end.blockIndex && lIdx == sel.end.lineIndex)

                let startCol = isFirst ? max(0, min(line.rawText.count, sel.start.columnIndex)) : 0
                let endCol = isLast ? max(0, min(line.rawText.count, sel.end.columnIndex)) : line.rawText.count

                if startCol <= endCol && endCol <= line.rawText.count {
                    let startIndex = line.rawText.index(line.rawText.startIndex, offsetBy: startCol)
                    let endIndex = line.rawText.index(line.rawText.startIndex, offsetBy: endCol)
                    resultLines.append(String(line.rawText[startIndex..<endIndex]))
                }
            }
        }

        return resultLines.joined(separator: "\n")
    }

    public func copyBlockOutput(block: TerminalBlock) {
        let lines = block.lines.map(\.rawText).joined(separator: "\n")
        let full = lines.isEmpty ? block.command : "\(block.command)\n\(lines)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(full, forType: .string)
    }

    // MARK: - Context Menu
    public override func menu(for event: NSEvent) -> NSMenu? {
        let screenPoint = convert(event.locationInWindow, from: nil)
        let docY = screenPoint.y + scrollOffsetY

        var clickedBlockIndex: Int? = nil
        for layout in blockLayouts {
            if docY >= layout.startY && docY <= layout.startY + layout.totalHeight {
                clickedBlockIndex = layout.blockIndex
                break
            }
        }

        let menu = NSMenu(title: "Terminal Context Menu")

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        copyItem.isEnabled = hasSelection || !session.multiBuffer.blocks.isEmpty
        menu.addItem(copyItem)

        if let bIdx = clickedBlockIndex, bIdx < session.multiBuffer.blocks.count {
            let block = session.multiBuffer.blocks[bIdx]

            let copyCmdItem = NSMenuItem(title: "Copy Command", action: #selector(contextCopyCommand(_:)), keyEquivalent: "")
            copyCmdItem.target = self
            copyCmdItem.representedObject = block.command
            menu.addItem(copyCmdItem)

            let copyOutItem = NSMenuItem(title: "Copy Output", action: #selector(contextCopyOutput(_:)), keyEquivalent: "")
            copyOutItem.target = self
            copyOutItem.representedObject = block
            copyOutItem.isEnabled = !block.lines.isEmpty
            menu.addItem(copyOutItem)
        }

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = self
        selectAllItem.isEnabled = !session.multiBuffer.blocks.isEmpty
        menu.addItem(selectAllItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear", action: #selector(contextClearTerminal(_:)), keyEquivalent: "k")
        clearItem.keyEquivalentModifierMask = .command
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    @objc private func contextCopyCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(cmd, forType: .string)
    }

    @objc private func contextCopyOutput(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? TerminalBlock else { return }
        let text = block.lines.map(\.rawText).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func contextClearTerminal(_ sender: NSMenuItem) {
        session.multiBuffer.clear()
        rebuildLayout()
    }

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return hasSelection || !session.multiBuffer.blocks.isEmpty
        }
        if item.action == #selector(selectAll(_:)) {
            return !session.multiBuffer.blocks.isEmpty
        }
        return true
    }
}
