import AppKit
import AnyDiffCore

/// Native AppKit terminal view rendering cells, cursor, scrollback, mouse reporting, trackpad gestures, selection, and key events.
public final class TerminalNSView: NSView {
    public unowned let session: TerminalSession
    public var theme: Theme {
        didSet {
            needsDisplay = true
        }
    }
    public var fontSize: CGFloat = 12 {
        didSet {
            updateFontMetrics()
            updateGridDimensions()
            needsDisplay = true
        }
    }

    private var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var italicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldItalicFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private var charWidth: CGFloat = 7.2
    private var lineHeight: CGFloat = 16.0
    private var fontAscender: CGFloat = 12.0
    private let padding: CGFloat = 6.0

    // Scrollback navigation
    private var scrollOffset: Int = 0 // 0 = at bottom (active screen), >0 = scrolled up into scrollback
    private var accumulatedScrollDelta: CGFloat = 0

    // Text Selection
    private var selectionStart: (col: Int, lineIndex: Int)? = nil
    private var selectionEnd: (col: Int, lineIndex: Int)? = nil

    // Selection Auto-Scroll
    private var selectionAutoScrollTimer: Timer?
    private var autoScrollDelta: Int = 0
    private var lastSelectionDragPoint: NSPoint?

    // Tracking Area for mouse motion
    private var terminalTrackingArea: NSTrackingArea?

    public init(session: TerminalSession, theme: Theme) {
        self.session = session
        self.theme = theme
        super.init(frame: .zero)
        self.wantsLayer = true
        updateFontMetrics()

        session.onScreenUpdated = { [weak self] in
            guard let self = self else { return }
            self.needsDisplay = true
        }
    }

    deinit {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopSelectionAutoScrollTimer()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isFlipped: Bool {
        true
    }

    override public var acceptsFirstResponder: Bool {
        true
    }

    override public func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override public func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    private func updateFontMetrics() {
        let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.font = baseFont
        self.boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        self.italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        self.boldItalicFont = NSFontManager.shared.convert(self.boldFont, toHaveTrait: .italicFontMask)

        let ctFont = CTFontCreateWithName(baseFont.fontName as CFString, fontSize, nil)
        var glyph: CGGlyph = 0
        var advance: CGSize = .zero
        let chars: [UniChar] = [0x004D] // 'M'
        if CTFontGetGlyphsForCharacters(ctFont, chars, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
            self.charWidth = max(5.0, advance.width)
        } else {
            let sample = "M" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: self.font]
            self.charWidth = max(5.0, sample.size(withAttributes: attrs).width)
        }
        self.fontAscender = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.lineHeight = max(10.0, ceil(fontAscender + descent + leading + 2.0))
    }

    public func updateGridDimensions() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let availableWidth = max(charWidth, bounds.width - padding * 2)
        let availableHeight = max(lineHeight, bounds.height - padding * 2)
        let cols = max(10, Int(availableWidth / charWidth))
        let rows = max(4, Int(availableHeight / lineHeight))
        if cols != session.screen.cols || rows != session.screen.rows {
            session.resize(cols: cols, rows: rows)
            needsDisplay = true
        }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridDimensions()
        needsDisplay = true
    }

    override public func layout() {
        super.layout()
        updateGridDimensions()
        needsDisplay = true
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateGridDimensions()
            needsDisplay = true
        }
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateGridDimensions()
        needsDisplay = true
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = terminalTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.terminalTrackingArea = area
    }

    override public func cursorUpdate(with event: NSEvent) {
        if shouldReportMouse(for: event) {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    // MARK: - Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        let bgColor = theme.background
        bgColor.setFill()
        dirtyRect.fill()

        let screen = session.screen
        let visibleRows = screen.rows
        let totalScrollback = screen.scrollback.count

        // Clamp scrollOffset
        scrollOffset = max(0, min(totalScrollback, scrollOffset))

        // Precompute default colors
        let defaultFg = theme.foreground
        let selectionBg = NSColor.selectedTextBackgroundColor

        // Calculate line range: index 0 to totalScrollback + visibleRows - 1
        let bottomLineIndex = totalScrollback + visibleRows - 1 - scrollOffset
        let topLineIndex = bottomLineIndex - visibleRows + 1

        for row in 0..<visibleRows {
            let lineIdx = topLineIndex + row
            guard lineIdx >= 0 else { continue }

            let line: TerminalLine
            if lineIdx < totalScrollback {
                line = screen.scrollback[lineIdx]
            } else {
                let screenRow = lineIdx - totalScrollback
                if screenRow < screen.lines.count {
                    line = screen.lines[screenRow]
                } else {
                    continue
                }
            }

            let y = padding + CGFloat(row) * lineHeight

            // Draw line cells in runs
            var col = 0
            while col < line.cells.count && col < screen.cols {
                let cell = line.cells[col]

                // Determine run length with identical colors and attributes
                let isSelected = isCellSelected(col: col, lineIndex: lineIdx)
                var runEnd = col + 1
                while runEnd < line.cells.count && runEnd < screen.cols {
                    let next = line.cells[runEnd]
                    let nextSelected = isCellSelected(col: runEnd, lineIndex: lineIdx)
                    if next.fg == cell.fg && next.bg == cell.bg && next.attributes == cell.attributes && nextSelected == isSelected {
                        runEnd += 1
                    } else {
                        break
                    }
                }

                let runWidth = CGFloat(runEnd - col) * charWidth
                let cellRect = CGRect(x: padding + CGFloat(col) * charWidth, y: y, width: runWidth, height: lineHeight)

                let isReverse = cell.attributes.contains(.reverse)
                var cellFgColor: NSColor = (cell.fg != .default)
                    ? NSColor(calibratedRed: cell.fg.rgb().red, green: cell.fg.rgb().green, blue: cell.fg.rgb().blue, alpha: 1.0)
                    : defaultFg
                var cellBgColor: NSColor? = (cell.bg != .default)
                    ? NSColor(calibratedRed: cell.bg.rgb().red, green: cell.bg.rgb().green, blue: cell.bg.rgb().blue, alpha: 1.0)
                    : nil

                if isReverse {
                    let prevFg = cellFgColor
                    cellFgColor = cellBgColor ?? bgColor
                    cellBgColor = prevFg
                }

                if isSelected {
                    cellBgColor = selectionBg
                    cellFgColor = defaultFg
                }

                // Background
                if let bg = cellBgColor {
                    bg.setFill()
                    context.fill(cellRect)
                }

                // Foreground Text
                var runString = ""
                runString.reserveCapacity(runEnd - col)
                for c in col..<runEnd {
                    runString.append(line.cells[c].character)
                }

                if !runString.trimmingCharacters(in: .whitespaces).isEmpty {
                    let fgColor = cellFgColor

                    let isBold = cell.attributes.contains(.bold)
                    let isItalic = cell.attributes.contains(.italic)
                    let textFont: NSFont
                    if isBold && isItalic {
                        textFont = boldItalicFont
                    } else if isBold {
                        textFont = boldFont
                    } else if isItalic {
                        textFont = italicFont
                    } else {
                        textFont = font
                    }

                    var textAttrs: [NSAttributedString.Key: Any] = [
                        .font: textFont,
                        .foregroundColor: fgColor
                    ]
                    if cell.attributes.contains(.underline) {
                        textAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }

                    // Draw cells: if character is box drawing, draw vector; otherwise accumulate string
                    var currentTextChunk = ""
                    var textChunkStartCol = col

                    for c in col..<runEnd {
                        let char = line.cells[c].character
                        if TerminalBoxDrawingRenderer.isBoxDrawingCharacter(char) {
                            if !currentTextChunk.isEmpty {
                                let textPoint = CGPoint(x: padding + CGFloat(textChunkStartCol) * charWidth, y: y + (lineHeight - fontAscender) / 2.0)
                                (currentTextChunk as NSString).draw(at: textPoint, withAttributes: textAttrs)
                                currentTextChunk = ""
                            }
                            let singleCellRect = CGRect(x: padding + CGFloat(c) * charWidth, y: y, width: charWidth, height: lineHeight)
                            TerminalBoxDrawingRenderer.draw(character: char, in: singleCellRect, context: context, color: fgColor)
                            textChunkStartCol = c + 1
                        } else {
                            if currentTextChunk.isEmpty {
                                textChunkStartCol = c
                            }
                            currentTextChunk.append(char)
                        }
                    }

                    if !currentTextChunk.isEmpty {
                        let textPoint = CGPoint(x: padding + CGFloat(textChunkStartCol) * charWidth, y: y + (lineHeight - fontAscender) / 2.0)
                        (currentTextChunk as NSString).draw(at: textPoint, withAttributes: textAttrs)
                    }
                }

                col = runEnd
            }
        }

        // Draw Cursor (only if at the bottom of the scrollback buffer)
        if screen.isCursorVisible && scrollOffset == 0 {
            let cursorRow = screen.cursorY
            let cursorCol = screen.cursorX
            let cursorX = padding + CGFloat(cursorCol) * charWidth
            let cursorY = padding + CGFloat(cursorRow) * lineHeight
            let cursorRect = CGRect(x: cursorX, y: cursorY, width: charWidth, height: lineHeight)

            let isFocused = (window?.firstResponder == self)
            let cursorColor = theme.accentColor

            if isFocused {
                cursorColor.setFill()
                context.fill(cursorRect)

                // Draw inverted character under cursor
                if cursorRow < screen.lines.count && cursorCol < screen.lines[cursorRow].cells.count {
                    let char = screen.lines[cursorRow].cells[cursorCol].character
                    if char != " " {
                        let textAttrs: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: bgColor
                        ]
                        (String(char) as NSString).draw(
                            at: CGPoint(x: cursorX, y: cursorY + (lineHeight - fontAscender) / 2.0),
                            withAttributes: textAttrs
                        )
                    }
                }
            } else {
                cursorColor.setStroke()
                context.stroke(cursorRect.insetBy(dx: 0.5, dy: 0.5), width: 1.0)
            }
        }
    }

    // MARK: - Scrolling & Trackpad Gestures

    override public func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        guard abs(deltaY) > 0.001 else { return }

        // Reset accumulation when a new gesture begins or when reversing scroll direction
        if event.phase == .began || (accumulatedScrollDelta > 0 && deltaY < 0) || (accumulatedScrollDelta < 0 && deltaY > 0) {
            accumulatedScrollDelta = 0
        }

        let isOptionPressed = event.modifierFlags.contains(.option)

        // 1. Mouse reporting is active (e.g. in htop, vim, tmux)
        if shouldReportMouse(for: event) {
            accumulatedScrollDelta += deltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
            if abs(accumulatedScrollDelta) >= threshold {
                let pt = convert(event.locationInWindow, from: nil)
                let (col, row) = terminalCellCoordinate(at: pt)
                let button: TerminalMouseButton = accumulatedScrollDelta > 0 ? .wheelUp : .wheelDown
                let mods = terminalModifiers(from: event.modifierFlags)
                let steps = min(8, max(1, Int(abs(accumulatedScrollDelta) / threshold)))

                var combinedData = Data()
                for _ in 0..<steps {
                    if let data = TerminalMouseEncoder.encode(
                        button: button,
                        type: .press,
                        modifiers: mods,
                        col: col,
                        row: row,
                        format: session.screen.mouseFormat
                    ) {
                        combinedData.append(data)
                    }
                }
                if !combinedData.isEmpty {
                    session.sendData(combinedData)
                }
                accumulatedScrollDelta -= CGFloat(steps) * threshold * (accumulatedScrollDelta > 0 ? 1.0 : -1.0)
            }
            return
        }

        // 2. Alternate screen buffer active (e.g. less, man, git diff)
        if session.screen.isAlternateBufferActive && session.screen.alternateScrollMode && !isOptionPressed {
            accumulatedScrollDelta += deltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12.0 : 1.0
            if abs(accumulatedScrollDelta) >= threshold {
                let steps = min(8, max(1, Int(abs(accumulatedScrollDelta) / threshold)))
                let appCursor = session.screen.applicationCursorKeys
                let code = accumulatedScrollDelta > 0
                    ? (appCursor ? "\u{1B}OA" : "\u{1B}[A") // Up
                    : (appCursor ? "\u{1B}OB" : "\u{1B}[B") // Down

                session.sendInput(String(repeating: code, count: steps))
                accumulatedScrollDelta -= CGFloat(steps) * threshold * (accumulatedScrollDelta > 0 ? 1.0 : -1.0)
            }
            return
        }

        // 3. Normal screen: scrollback history navigation
        accumulatedScrollDelta += deltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 8.0 : 1.0
        if abs(accumulatedScrollDelta) >= threshold {
            let lines = Int(accumulatedScrollDelta / threshold)
            if lines != 0 {
                let maxScroll = session.screen.scrollback.count
                let targetOffset = scrollOffset + lines
                if targetOffset <= 0 {
                    scrollOffset = 0
                    accumulatedScrollDelta = 0
                } else if targetOffset >= maxScroll {
                    scrollOffset = maxScroll
                    accumulatedScrollDelta = 0
                } else {
                    scrollOffset = targetOffset
                    accumulatedScrollDelta -= CGFloat(lines) * threshold
                }
                if selectionStart != nil, let pt = lastSelectionDragPoint {
                    selectionEnd = cellCoordinate(at: pt)
                }
                needsDisplay = true
            }
        }
    }

    // Standard ANSI / PC-101 base layout mapping (matching SwiftTerm's kittyBaseLayoutKeyMap)
    private static let baseLayoutKeyMap: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 49: " ", 50: "`"
    ]

    private func baseLayoutKey(for keyCode: UInt16) -> Character? {
        Self.baseLayoutKeyMap[keyCode]
    }

    /// Takes the unmodified character string and produces the C0 control code (matching SwiftTerm).
    private func applyControlToEventCharacters(_ ch: String) -> [UInt8] {
        guard let first = ch.first, let ascii = first.asciiValue else { return [] }
        switch first {
        case "a"..."z":
            return [ascii - 0x60] // 'a' (0x61) -> 0x01
        case "A"..."Z":
            return [ascii - 0x40] // 'A' (0x41) -> 0x01
        case "\\":
            return [0x1C]
        case "_":
            return [0x1F]
        case "]":
            return [0x1D]
        case "[":
            return [0x1B]
        case "^", "6":
            return [0x1E]
        case " ":
            return [0x00]
        case "?":
            return [0x7F]
        default:
            return []
        }
    }

    // MARK: - Key Events

    override public func keyDown(with event: NSEvent) {
        // Any keystroke jumps scroll back to the active bottom screen
        if scrollOffset != 0 {
            scrollOffset = 0
            needsDisplay = true
        }

        let flags = event.modifierFlags

        // Handle Cmd shortcuts:
        // 1. Give Main Menu first priority (standard AppKit pattern, matching SwiftTerm)
        // 2. Fall back to standard responder actions using base layout key if menu is unhandled or absent
        if flags.contains(.command) {
            if NSApp?.mainMenu?.performKeyEquivalent(with: event) == true {
                return
            }
            let char = event.charactersIgnoringModifiers?.lowercased().first
            let key = (char != nil && char!.isASCII) ? char! : (baseLayoutKey(for: event.keyCode) ?? " ")
            switch key {
            case "c":
                copy(nil)
                return
            case "v":
                paste(nil)
                return
            case "a":
                selectAll(nil)
                return
            case "k":
                session.clear()
                return
            default:
                break
            }
            // Let other Cmd shortcuts bubble up to the app
            super.keyDown(with: event)
            return
        }

        // Handle Special Keys
        let appCursor = session.screen.applicationCursorKeys
        switch event.keyCode {
        case 36: // Return / Enter
            session.sendInput("\r")
            return
        case 51: // Backspace / Delete
            session.sendInput("\u{7F}")
            return
        case 117: // Forward Delete
            session.sendInput("\u{1B}[3~")
            return
        case 48: // Tab
            session.sendInput("\t")
            return
        case 53: // Escape
            session.sendInput("\u{1B}")
            return
        case 126: // Up Arrow
            session.sendInput(appCursor ? "\u{1B}OA" : "\u{1B}[A")
            return
        case 125: // Down Arrow
            session.sendInput(appCursor ? "\u{1B}OB" : "\u{1B}[B")
            return
        case 124: // Right Arrow
            if flags.contains(.option) {
                // Meta + f (jump word forward)
                session.sendInput("\u{1B}f")
            } else {
                session.sendInput(appCursor ? "\u{1B}OC" : "\u{1B}[C")
            }
            return
        case 123: // Left Arrow
            if flags.contains(.option) {
                // Meta + b (jump word backward)
                session.sendInput("\u{1B}b")
            } else {
                session.sendInput(appCursor ? "\u{1B}OD" : "\u{1B}[D")
            }
            return
        case 115: // Home
            session.sendInput("\u{1B}[H")
            return
        case 119: // End
            session.sendInput("\u{1B}[F")
            return
        case 116: // Page Up
            session.sendInput("\u{1B}[5~")
            return
        case 121: // Page Down
            session.sendInput("\u{1B}[6~")
            return
        default:
            break
        }

        // Handle Option (Alt) as Meta key for letter combinations (e.g. Opt+b, Opt+f, Opt+d)
        if flags.contains(.option) && !flags.contains(.control) && !flags.contains(.command) {
            let rawChar = event.charactersIgnoringModifiers?.first
            let metaChar: Character?
            if let rawChar = rawChar, rawChar.isASCII {
                metaChar = rawChar
            } else {
                metaChar = baseLayoutKey(for: event.keyCode)
            }
            if let char = metaChar {
                session.sendInput("\u{1B}\(char)")
                return
            }
        }

        // Handle Ctrl combinations (matching SwiftTerm's applyControlToEventCharacters + baseLayout fallback)
        if flags.contains(.control) {
            let rawChars = event.charactersIgnoringModifiers ?? ""
            var controlBytes = applyControlToEventCharacters(rawChars)

            // Non-Latin layouts (e.g. Russian, Greek, Hebrew) map an ASCII physical key
            // to a Unicode character with no Control translation. In that case, use the key's
            // standard PC-101 / ANSI base layout position, exactly as done in SwiftTerm.
            if controlBytes.isEmpty,
               let scalar = rawChars.unicodeScalars.first,
               scalar.value > 0x7F,
               let baseKey = baseLayoutKey(for: event.keyCode) {
                controlBytes = applyControlToEventCharacters(String(baseKey))
            }

            if !controlBytes.isEmpty {
                session.sendData(Data(controlBytes))
                return
            }
        }

        // Regular character input
        if let chars = event.characters, !chars.isEmpty {
            session.sendInput(chars)
        }
    }

    // MARK: - Mouse & Touchpad Interaction

    private func shouldReportMouse(for event: NSEvent) -> Bool {
        session.screen.mouseTrackingMode != .none && !event.modifierFlags.contains(.option)
    }

    private func terminalModifiers(from flags: NSEvent.ModifierFlags) -> TerminalMouseModifiers {
        var mods: TerminalMouseModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
    }

    private func terminalCellCoordinate(at point: NSPoint) -> (col: Int, row: Int) {
        let col = max(1, min(session.screen.cols, Int((point.x - padding) / charWidth) + 1))
        let rowFromTop = Int((point.y - padding) / lineHeight) + 1
        let row = max(1, min(session.screen.rows, rowFromTop))
        return (col, row)
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stopSelectionAutoScrollTimer()
        autoScrollDelta = 0
        lastSelectionDragPoint = nil
        let pt = convert(event.locationInWindow, from: nil)

        if shouldReportMouse(for: event) {
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .left, type: .press, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }

        // Text Selection
        let pos = cellCoordinate(at: pt)
        if event.clickCount == 2 {
            selectWord(at: pos)
        } else if event.clickCount == 3 {
            selectLine(at: pos)
        } else {
            selectionStart = pos
            selectionEnd = pos
        }
        needsDisplay = true
    }

    override public func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if shouldReportMouse(for: event) {
            if session.screen.mouseTrackingMode == .buttonEvent || session.screen.mouseTrackingMode == .anyEvent {
                let (col, row) = terminalCellCoordinate(at: pt)
                let mods = terminalModifiers(from: event.modifierFlags)
                if let data = TerminalMouseEncoder.encode(button: .left, type: .drag, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                    session.sendData(data)
                }
            }
            return
        }

        lastSelectionDragPoint = pt

        if selectionStart != nil {
            let visibleRows = session.screen.rows
            let screenRow = Int(floor((pt.y - padding) / lineHeight))

            if screenRow < 0 {
                let delta = -screenRow
                autoScrollDelta = -calcScrollingVelocity(delta: delta)
            } else if screenRow >= visibleRows {
                let delta = screenRow - visibleRows + 1
                autoScrollDelta = calcScrollingVelocity(delta: delta)
            } else {
                autoScrollDelta = 0
            }

            if autoScrollDelta != 0 {
                startSelectionAutoScrollTimer()
            } else {
                stopSelectionAutoScrollTimer()
            }
        }

        selectionEnd = cellCoordinate(at: pt)
        needsDisplay = true
    }

    override public func mouseUp(with event: NSEvent) {
        stopSelectionAutoScrollTimer()
        autoScrollDelta = 0
        lastSelectionDragPoint = nil

        let pt = convert(event.locationInWindow, from: nil)

        if shouldReportMouse(for: event) {
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .left, type: .release, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }

        if event.clickCount == 1, let s = selectionStart, let e = selectionEnd, s.col == e.col && s.lineIndex == e.lineIndex {
            selectionStart = nil
            selectionEnd = nil
            needsDisplay = true
        }
    }

    override public func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse(for: event) {
            let pt = convert(event.locationInWindow, from: nil)
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .right, type: .press, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }
        super.rightMouseDown(with: event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        if shouldReportMouse(for: event) {
            let pt = convert(event.locationInWindow, from: nil)
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .right, type: .release, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }
        super.rightMouseUp(with: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if shouldReportMouse(for: event) {
            let pt = convert(event.locationInWindow, from: nil)
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .middle, type: .press, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }
        super.otherMouseDown(with: event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        if shouldReportMouse(for: event) {
            let pt = convert(event.locationInWindow, from: nil)
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .middle, type: .release, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
            return
        }
        super.otherMouseUp(with: event)
    }

    override public func mouseMoved(with event: NSEvent) {
        if session.screen.mouseTrackingMode == .anyEvent && !event.modifierFlags.contains(.option) {
            let pt = convert(event.locationInWindow, from: nil)
            let (col, row) = terminalCellCoordinate(at: pt)
            let mods = terminalModifiers(from: event.modifierFlags)
            if let data = TerminalMouseEncoder.encode(button: .release, type: .move, modifiers: mods, col: col, row: row, format: session.screen.mouseFormat) {
                session.sendData(data)
            }
        }
        super.mouseMoved(with: event)
    }

    // MARK: - Word / Line Selection

    private func selectWord(at pos: (col: Int, lineIndex: Int)) {
        let line = getLine(at: pos.lineIndex)
        guard pos.col < line.cells.count else { return }

        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "-" || c == "."
        }

        var startCol = pos.col
        while startCol > 0 && isWordChar(line.cells[startCol - 1].character) {
            startCol -= 1
        }
        var endCol = pos.col
        while endCol + 1 < line.cells.count && isWordChar(line.cells[endCol + 1].character) {
            endCol += 1
        }

        selectionStart = (col: startCol, lineIndex: pos.lineIndex)
        selectionEnd = (col: endCol, lineIndex: pos.lineIndex)
    }

    private func selectLine(at pos: (col: Int, lineIndex: Int)) {
        let line = getLine(at: pos.lineIndex)
        selectionStart = (col: 0, lineIndex: pos.lineIndex)
        selectionEnd = (col: max(0, line.cells.count - 1), lineIndex: pos.lineIndex)
    }

    private func getLine(at lineIndex: Int) -> TerminalLine {
        let screen = session.screen
        let totalScrollback = screen.scrollback.count
        if lineIndex < totalScrollback {
            return screen.scrollback[lineIndex]
        } else {
            let r = lineIndex - totalScrollback
            if r < screen.lines.count {
                return screen.lines[r]
            }
        }
        return TerminalLine(width: screen.cols)
    }

    // MARK: - Context Menu

    override public func menu(for event: NSEvent) -> NSMenu? {
        if shouldReportMouse(for: event) {
            return nil
        }

        let contextMenu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copyAction(_:)), keyEquivalent: "")
        copyItem.target = self
        contextMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(pasteAction(_:)), keyEquivalent: "")
        pasteItem.target = self
        contextMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "")
        selectAllItem.target = self
        contextMenu.addItem(selectAllItem)

        contextMenu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Buffer", action: #selector(clearAction(_:)), keyEquivalent: "")
        clearItem.target = self
        contextMenu.addItem(clearItem)

        let restartItem = NSMenuItem(title: "Restart Shell", action: #selector(restartAction(_:)), keyEquivalent: "")
        restartItem.target = self
        contextMenu.addItem(restartItem)

        return contextMenu
    }

    // MARK: - Standard Responder Actions
    @objc public func copy(_ sender: Any?) {
        copySelectionOrScreen()
    }

    @objc public func paste(_ sender: Any?) {
        pasteFromClipboard()
    }

    @objc override public func selectAll(_ sender: Any?) {
        selectAllAction(sender)
    }

    @objc private func copyAction(_ sender: Any?) {
        copySelectionOrScreen()
    }

    @objc private func pasteAction(_ sender: Any?) {
        pasteFromClipboard()
    }

    @objc private func selectAllAction(_ sender: Any?) {
        let screen = session.screen
        let total = screen.scrollback.count + screen.lines.count
        guard total > 0 else { return }
        selectionStart = (col: 0, lineIndex: 0)
        selectionEnd = (col: screen.cols - 1, lineIndex: total - 1)
        needsDisplay = true
    }

    @objc private func clearAction(_ sender: Any?) {
        session.clear()
    }

    @objc private func restartAction(_ sender: Any?) {
        session.restart()
    }

    // MARK: - Clipboard & Selection

    private func isCellSelected(col: Int, lineIndex: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        let isForward = start.lineIndex < end.lineIndex || (start.lineIndex == end.lineIndex && start.col <= end.col)
        let (first, last) = isForward ? (start, end) : (end, start)

        if lineIndex < first.lineIndex || lineIndex > last.lineIndex {
            return false
        }
        if first.lineIndex == last.lineIndex {
            return col >= first.col && col <= last.col
        }
        if lineIndex == first.lineIndex {
            return col >= first.col
        }
        if lineIndex == last.lineIndex {
            return col <= last.col
        }
        return true
    }

    private func copySelectionOrScreen() {
        if let start = selectionStart, let end = selectionEnd {
            let isForward = start.lineIndex < end.lineIndex || (start.lineIndex == end.lineIndex && start.col <= end.col)
            let (first, last) = isForward ? (start, end) : (end, start)
            let screen = session.screen
            let totalScrollback = screen.scrollback.count
            var copied = ""

            for lineIdx in first.lineIndex...last.lineIndex {
                let line: TerminalLine
                if lineIdx < totalScrollback {
                    line = screen.scrollback[lineIdx]
                } else {
                    let r = lineIdx - totalScrollback
                    if r < screen.lines.count {
                        line = screen.lines[r]
                    } else {
                        continue
                    }
                }
                let left = (lineIdx == first.lineIndex) ? first.col : 0
                let right = (lineIdx == last.lineIndex) ? min(last.col, line.cells.count - 1) : line.cells.count - 1
                if left <= right && left < line.cells.count {
                    var lineStr = ""
                    for c in left...right {
                        lineStr.append(line.cells[c].character)
                    }
                    // Trim trailing spaces if copying whole line or to end of line
                    if lineIdx < last.lineIndex {
                        while lineStr.hasSuffix(" ") {
                            lineStr.removeLast()
                        }
                    }
                    copied.append(lineStr)
                }
                if lineIdx < last.lineIndex {
                    copied.append("\n")
                }
            }

            let pboard = NSPasteboard.general
            pboard.clearContents()
            pboard.setString(copied, forType: .string)
        } else {
            // Copy visible text
            let text = session.screen.fullText(includeScrollback: false)
            let pboard = NSPasteboard.general
            pboard.clearContents()
            pboard.setString(text, forType: .string)
        }
    }

    private func pasteFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string), !string.isEmpty else { return }
        if session.screen.bracketedPasteMode {
            session.sendInput("\u{1B}[200~" + string + "\u{1B}[201~")
        } else {
            session.sendInput(string)
        }
    }

    private func cellCoordinate(at point: NSPoint) -> (col: Int, lineIndex: Int) {
        let screen = session.screen
        let totalScrollback = screen.scrollback.count
        let visibleRows = screen.rows
        let bottomLineIndex = totalScrollback + visibleRows - 1 - scrollOffset
        let topLineIndex = bottomLineIndex - visibleRows + 1

        let col = max(0, min(screen.cols - 1, Int((point.x - padding) / charWidth)))
        let rowFromTop = Int(floor((point.y - padding) / lineHeight))
        let safeRow = max(0, min(visibleRows - 1, rowFromTop))
        let totalLines = totalScrollback + screen.lines.count
        let lineIndex = max(0, min(max(0, totalLines - 1), topLineIndex + safeRow))
        return (col, lineIndex)
    }

    // MARK: - Selection Auto-Scroll (SwiftTerm style)

    private func startSelectionAutoScrollTimer() {
        guard selectionAutoScrollTimer == nil else { return }
        // RunLoop .common mode is required so the timer continues firing during
        // event tracking when the mouse is dragged and held outside the view bounds.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.scrollingTimerElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionAutoScrollTimer = timer
    }

    private func stopSelectionAutoScrollTimer() {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }

    /// Velocity curve used by drag-selection auto-scroll (matching SwiftTerm).
    private func calcScrollingVelocity(delta: Int) -> Int {
        if delta > 9 { return max(session.screen.rows, 20) }
        if delta > 5 { return 10 }
        if delta > 1 { return 3 }
        return 1
    }

    private func scrollingTimerElapsed() {
        guard selectionStart != nil, autoScrollDelta != 0 else {
            stopSelectionAutoScrollTimer()
            return
        }

        let maxScroll = session.screen.scrollback.count
        if autoScrollDelta < 0 {
            // Scrolling UP into scrollback history
            let linesToScroll = -autoScrollDelta
            scrollOffset = min(maxScroll, scrollOffset + linesToScroll)
        } else {
            // Scrolling DOWN towards active screen
            let linesToScroll = autoScrollDelta
            scrollOffset = max(0, scrollOffset - linesToScroll)
        }

        if let pt = lastSelectionDragPoint {
            selectionEnd = cellCoordinate(at: pt)
        }
        needsDisplay = true
    }
}
