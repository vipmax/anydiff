import Foundation

/// Active mouse tracking mode enabled by the running interactive program.
public enum TerminalMouseTrackingMode: Hashable, Sendable {
    case none
    case x10           // 9
    case normal        // 1000
    case buttonEvent   // 1002
    case anyEvent      // 1003
}

/// Encoding format for reporting mouse coordinates and events.
public enum TerminalMouseFormat: Hashable, Sendable {
    case x10           // Default legacy 3-byte encoding
    case sgr           // Extended SGR 1006 encoding: ESC [ < button ; col ; row (M or m)
}

/// A single character cell on the terminal screen.
public struct TerminalCell: Hashable, Sendable {
    public var character: Character
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var attributes: TerminalCellAttributes

    public init(
        character: Character = " ",
        fg: TerminalColor = .default,
        bg: TerminalColor = .default,
        attributes: TerminalCellAttributes = []
    ) {
        self.character = character
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }

    public static let empty = TerminalCell()
}

/// A single horizontal row of cells on the terminal screen.
public struct TerminalLine: Hashable, Sendable {
    public var cells: [TerminalCell]

    public init(cells: [TerminalCell]) {
        self.cells = cells
    }

    public init(width: Int) {
        self.cells = Array(repeating: .empty, count: max(1, width))
    }

    public mutating func resize(to newWidth: Int) {
        if cells.count < newWidth {
            cells.append(contentsOf: repeatElement(.empty, count: newWidth - cells.count))
        } else if cells.count > newWidth {
            cells.removeLast(cells.count - newWidth)
        }
    }

    /// Returns plain text representation of this line, trimming trailing empty spaces.
    public func plainText() -> String {
        var end = cells.count
        while end > 0 && cells[end - 1].character == " " && cells[end - 1].bg == .default {
            end -= 1
        }
        if end == 0 { return "" }
        var result = ""
        result.reserveCapacity(end)
        for i in 0..<end {
            result.append(cells[i].character)
        }
        return result
    }
}

/// Manages the terminal's 2D grid of character cells, scrollback history, cursor, and alternate screen buffer.
public final class TerminalScreen: @unchecked Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int

    public private(set) var lines: [TerminalLine]
    public private(set) var scrollback: [TerminalLine] = []
    public var scrollbackLimit: Int = 5000

    public private(set) var cursorX: Int = 0
    public private(set) var cursorY: Int = 0
    public var isCursorVisible: Bool = true

    public var currentFg: TerminalColor = .default
    public var currentBg: TerminalColor = .default
    public var currentAttributes: TerminalCellAttributes = []

    public private(set) var scrollTop: Int = 0
    public private(set) var scrollBottom: Int = 23

    public private(set) var isAlternateBufferActive: Bool = false
    private var primaryLines: [TerminalLine] = []
    private var primaryCursor: (x: Int, y: Int) = (0, 0)
    private var savedCursor: (x: Int, y: Int) = (0, 0)

    public var applicationCursorKeys: Bool = false
    public var bracketedPasteMode: Bool = false

    public var mouseTrackingMode: TerminalMouseTrackingMode = .none
    public var mouseFormat: TerminalMouseFormat = .x10
    public var alternateScrollMode: Bool = true

    public init(cols: Int = 80, rows: Int = 24) {
        let safeCols = max(1, cols)
        let safeRows = max(1, rows)
        self.cols = safeCols
        self.rows = safeRows
        self.scrollBottom = safeRows - 1
        self.lines = (0..<safeRows).map { _ in TerminalLine(width: safeCols) }
    }

    // MARK: - Dimensions & Resizing

    public func resize(cols newCols: Int, rows newRows: Int) {
        let targetCols = max(1, newCols)
        let targetRows = max(1, newRows)
        guard targetCols != cols || targetRows != rows else { return }

        // Resize existing rows
        for i in 0..<lines.count {
            lines[i].resize(to: targetCols)
        }

        if targetRows > lines.count {
            let needed = targetRows - lines.count
            // If we have lines in scrollback, pull them back into the visible screen
            var pulled = 0
            if !isAlternateBufferActive && !scrollback.isEmpty {
                let toPull = min(needed, scrollback.count)
                let startIdx = scrollback.count - toPull
                for i in startIdx..<scrollback.count {
                    var line = scrollback[i]
                    line.resize(to: targetCols)
                    lines.insert(line, at: pulled)
                    pulled += 1
                }
                scrollback.removeLast(toPull)
                cursorY += pulled
                savedCursor.y += pulled
            }
            // Expand remaining needed rows downwards
            let remaining = needed - pulled
            for _ in 0..<remaining {
                lines.append(TerminalLine(width: targetCols))
            }
        } else if targetRows < lines.count {
            // Shrink rows (push excess top lines to scrollback if not in alt buffer)
            let excess = lines.count - targetRows
            if !isAlternateBufferActive {
                for i in 0..<excess {
                    scrollback.append(lines[i])
                }
                trimScrollback()
            }
            lines.removeFirst(excess)
            cursorY = max(0, cursorY - excess)
            savedCursor.y = max(0, savedCursor.y - excess)
        }

        self.cols = targetCols
        self.rows = targetRows
        self.scrollTop = 0
        self.scrollBottom = targetRows - 1
        self.cursorX = min(cursorX, targetCols - 1)
        self.cursorY = min(cursorY, targetRows - 1)
    }

    /// Returns the plain text of the currently visible screen (optionally trimming empty trailing lines).
    public func visibleScreenText(trimEmptyTrailingLines: Bool = true) -> String {
        var texts = lines.map { $0.plainText() }
        if trimEmptyTrailingLines {
            while let last = texts.last, last.isEmpty {
                texts.removeLast()
            }
        }
        return texts.joined(separator: "\n")
    }

    // MARK: - Character Output

    public func putCharacter(_ char: Character) {
        if cursorX >= cols {
            cursorX = 0
            cursorY += 1
            if cursorY > scrollBottom {
                scrollUp(lines: 1)
                cursorY = scrollBottom
            }
        }

        clampCursor()
        let cell = TerminalCell(
            character: char,
            fg: currentFg,
            bg: currentBg,
            attributes: currentAttributes
        )
        lines[cursorY].cells[cursorX] = cell
        cursorX += 1
    }

    public func carriageReturn() {
        cursorX = 0
    }

    public func lineFeed() {
        if cursorY == scrollBottom {
            scrollUp(lines: 1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    public func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(lines: 1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    public func backspace() {
        cursorX = max(0, cursorX - 1)
    }

    public func tab() {
        let tabStop = (cursorX + 8) & ~7
        cursorX = min(cols - 1, tabStop)
    }

    // MARK: - Cursor Operations

    public func setCursorPosition(col: Int, row: Int) {
        cursorX = max(0, min(cols - 1, col))
        cursorY = max(0, min(rows - 1, row))
    }

    public func moveCursor(deltaX: Int, deltaY: Int) {
        cursorX = max(0, min(cols - 1, cursorX + deltaX))
        cursorY = max(0, min(rows - 1, cursorY + deltaY))
    }

    public func saveCursor() {
        savedCursor = (cursorX, cursorY)
    }

    public func restoreCursor() {
        setCursorPosition(col: savedCursor.x, row: savedCursor.y)
    }

    private func clampCursor() {
        cursorX = max(0, min(cols - 1, cursorX))
        cursorY = max(0, min(rows - 1, cursorY))
    }

    // MARK: - Erasing

    public func eraseInLine(mode: Int) {
        clampCursor()
        switch mode {
        case 0: // From cursor to end of line
            for x in cursorX..<cols {
                lines[cursorY].cells[x] = .empty
            }
        case 1: // From start of line to cursor
            for x in 0...cursorX {
                lines[cursorY].cells[x] = .empty
            }
        case 2: // Entire line
            for x in 0..<cols {
                lines[cursorY].cells[x] = .empty
            }
        default:
            break
        }
    }

    public func eraseInDisplay(mode: Int) {
        clampCursor()
        switch mode {
        case 0: // From cursor to end of display
            eraseInLine(mode: 0)
            if cursorY + 1 < rows {
                for y in (cursorY + 1)..<rows {
                    lines[y] = TerminalLine(width: cols)
                }
            }
        case 1: // From top to cursor
            if cursorY > 0 {
                for y in 0..<cursorY {
                    lines[y] = TerminalLine(width: cols)
                }
            }
            eraseInLine(mode: 1)
        case 2: // Entire display
            for y in 0..<rows {
                lines[y] = TerminalLine(width: cols)
            }
        case 3: // Clear display and scrollback
            for y in 0..<rows {
                lines[y] = TerminalLine(width: cols)
            }
            scrollback.removeAll(keepingCapacity: false)
        default:
            break
        }
    }

    // MARK: - Scrolling

    public func setScrollRegion(top: Int, bottom: Int) {
        let safeTop = max(0, min(rows - 1, top))
        let safeBottom = max(safeTop, min(rows - 1, bottom))
        self.scrollTop = safeTop
        self.scrollBottom = safeBottom
        setCursorPosition(col: 0, row: 0)
    }

    public func resetScrollRegion() {
        self.scrollTop = 0
        self.scrollBottom = rows - 1
        setCursorPosition(col: 0, row: 0)
    }

    public func scrollUp(lines count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            if scrollTop == 0 && scrollBottom == rows - 1 {
                if !isAlternateBufferActive {
                    scrollback.append(lines[0])
                    trimScrollback()
                }
                lines.removeFirst()
                lines.append(TerminalLine(width: cols))
            } else {
                lines.remove(at: scrollTop)
                lines.insert(TerminalLine(width: cols), at: scrollBottom)
            }
        }
    }

    public func scrollDown(lines count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            lines.remove(at: scrollBottom)
            lines.insert(TerminalLine(width: cols), at: scrollTop)
        }
    }

    public func insertLines(count: Int) {
        clampCursor()
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        for _ in 0..<count {
            lines.remove(at: scrollBottom)
            lines.insert(TerminalLine(width: cols), at: cursorY)
        }
    }

    public func deleteLines(count: Int) {
        clampCursor()
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        for _ in 0..<count {
            lines.remove(at: cursorY)
            lines.insert(TerminalLine(width: cols), at: scrollBottom)
        }
    }

    public func insertCharacters(count: Int) {
        clampCursor()
        let count = min(count, cols - cursorX)
        for _ in 0..<count {
            lines[cursorY].cells.removeLast()
            lines[cursorY].cells.insert(.empty, at: cursorX)
        }
    }

    public func deleteCharacters(count: Int) {
        clampCursor()
        let count = min(count, cols - cursorX)
        for _ in 0..<count {
            lines[cursorY].cells.remove(at: cursorX)
            lines[cursorY].cells.append(.empty)
        }
    }

    public func eraseCharacters(count: Int) {
        clampCursor()
        let count = min(count, cols - cursorX)
        for i in 0..<count {
            lines[cursorY].cells[cursorX + i] = .empty
        }
    }

    // MARK: - Alternate Buffer

    public func switchAlternateScreen(enable: Bool) {
        if enable && !isAlternateBufferActive {
            primaryLines = lines
            primaryCursor = (cursorX, cursorY)
            lines = (0..<rows).map { _ in TerminalLine(width: cols) }
            cursorX = 0
            cursorY = 0
            isAlternateBufferActive = true
            resetScrollRegion()
        } else if !enable && isAlternateBufferActive {
            lines = primaryLines
            cursorX = primaryCursor.x
            cursorY = primaryCursor.y
            primaryLines = []
            isAlternateBufferActive = false
            resetScrollRegion()
        }
    }

    // MARK: - Text Export & Helpers

    public func fullText(includeScrollback: Bool = true) -> String {
        var result = ""
        if includeScrollback {
            for line in scrollback {
                result.append(line.plainText())
                result.append("\n")
            }
        }
        for (idx, line) in lines.enumerated() {
            result.append(line.plainText())
            if idx < lines.count - 1 {
                result.append("\n")
            }
        }
        return result
    }

    private func trimScrollback() {
        if scrollback.count > scrollbackLimit {
            let overflow = scrollback.count - scrollbackLimit
            scrollback.removeFirst(overflow)
        }
    }
}
