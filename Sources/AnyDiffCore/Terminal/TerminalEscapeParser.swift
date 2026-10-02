import Foundation

/// Fast streaming ANSI/VT100 escape sequence parser.
public final class TerminalEscapeParser: @unchecked Sendable {
    private enum State {
        case ground
        case escape
        case csi
        case osc
        case charset
    }

    private unowned let screen: TerminalScreen
    private var state: State = .ground

    // CSI State
    private var csiParams: [Int] = []
    private var currentParam: Int = 0
    private var hasCurrentParam: Bool = false
    private var isPrivateMode: Bool = false

    // OSC State
    private var oscBuffer: String = ""

    // UTF-8 decoding
    private var utf8Buffer = [UInt8]()

    // Callbacks
    public var onTitleChanged: ((String) -> Void)?
    public var onResponseRequired: ((Data) -> Void)?
    public var onBell: (() -> Void)?

    public init(screen: TerminalScreen) {
        self.screen = screen
    }

    /// Feeds raw incoming bytes from the pseudo-terminal process into the parser.
    public func feed(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buffer.count
            var i = 0
            while i < count {
                let byte = baseAddress[i]
                processByte(byte)
                i += 1
            }
        }
    }

    private func processByte(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1B { // ESC
                state = .escape
            } else if byte == 0x0D { // \r
                screen.carriageReturn()
            } else if byte == 0x0A || byte == 0x0B || byte == 0x0C { // \n, VT, FF
                screen.lineFeed()
            } else if byte == 0x08 { // \b
                screen.backspace()
            } else if byte == 0x09 { // \t
                screen.tab()
            } else if byte == 0x07 { // BEL
                onBell?()
            } else if byte >= 0x20 || byte >= 0x80 {
                // Printable character or UTF-8 multibyte sequence
                appendUtf8Byte(byte)
            }

        case .escape:
            switch byte {
            case 0x5B: // '[' -> CSI
                state = .csi
                resetCsi()
            case 0x5D: // ']' -> OSC
                state = .osc
                oscBuffer = ""
            case 0x28, 0x29: // '(', ')' -> Charset specification
                state = .charset
            case 0x37: // '7' -> Save cursor
                screen.saveCursor()
                state = .ground
            case 0x38: // '8' -> Restore cursor
                screen.restoreCursor()
                state = .ground
            case 0x4D: // 'M' -> Reverse Index (line feed up)
                screen.reverseIndex()
                state = .ground
            case 0x63: // 'c' -> Reset
                screen.eraseInDisplay(mode: 2)
                screen.setCursorPosition(col: 0, row: 0)
                state = .ground
            default:
                state = .ground
            }

        case .csi:
            if byte >= 0x30 && byte <= 0x39 { // '0'...'9'
                currentParam = currentParam * 10 + Int(byte - 0x30)
                hasCurrentParam = true
            } else if byte == 0x3B || byte == 0x3A { // ';' or ':'
                csiParams.append(hasCurrentParam ? currentParam : 0)
                currentParam = 0
                hasCurrentParam = false
            } else if byte == 0x3F { // '?'
                isPrivateMode = true
            } else if byte >= 0x40 && byte <= 0x7E { // Final byte of CSI sequence
                if hasCurrentParam {
                    csiParams.append(currentParam)
                }
                executeCsi(command: byte)
                state = .ground
            }

        case .osc:
            if byte == 0x07 { // BEL terminates OSC
                finishOsc()
                state = .ground
            } else if byte == 0x1B { // ESC \ might terminate OSC
                state = .ground
            } else {
                let scalar = UnicodeScalar(byte)
                oscBuffer.append(Character(scalar))
            }

        case .charset:
            // Single character to select charset, ignore and return to ground
            state = .ground
        }
    }

    private func appendUtf8Byte(_ byte: UInt8) {
        utf8Buffer.append(byte)
        if let str = String(bytes: utf8Buffer, encoding: .utf8) {
            for char in str {
                screen.putCharacter(char)
            }
            utf8Buffer.removeAll(keepingCapacity: true)
        } else if utf8Buffer.count >= 4 {
            // Invalid UTF-8 sequence, discard first byte to recover
            utf8Buffer.removeFirst()
        }
    }

    private func resetCsi() {
        csiParams.removeAll(keepingCapacity: true)
        currentParam = 0
        hasCurrentParam = false
        isPrivateMode = false
    }

    private func executeCsi(command: UInt8) {
        let p1 = csiParams.indices.contains(0) ? csiParams[0] : 0
        let p2 = csiParams.indices.contains(1) ? csiParams[1] : 0

        switch command {
        case 0x6D: // 'm' -> SGR (Select Graphic Rendition)
            executeSgr()

        case 0x41: // 'A' -> Cursor Up (CUU)
            screen.moveCursor(deltaX: 0, deltaY: -max(1, p1))

        case 0x42: // 'B' -> Cursor Down (CUD)
            screen.moveCursor(deltaX: 0, deltaY: max(1, p1))

        case 0x43: // 'C' -> Cursor Forward (CUF)
            screen.moveCursor(deltaX: max(1, p1), deltaY: 0)

        case 0x44: // 'D' -> Cursor Back (CUB)
            screen.moveCursor(deltaX: -max(1, p1), deltaY: 0)

        case 0x45: // 'E' -> Cursor Next Line (CNL)
            screen.setCursorPosition(col: 0, row: screen.cursorY + max(1, p1))

        case 0x46: // 'F' -> Cursor Prev Line (CPL)
            screen.setCursorPosition(col: 0, row: screen.cursorY - max(1, p1))

        case 0x47, 0x60: // 'G', '`' -> Cursor Horizontal Absolute (CHA)
            screen.setCursorPosition(col: max(1, p1) - 1, row: screen.cursorY)

        case 0x64: // 'd' -> Line Position Absolute / Vertical Position Absolute (VPA)
            screen.setCursorPosition(col: screen.cursorX, row: max(1, p1) - 1)

        case 0x48, 0x66: // 'H', 'f' -> Cursor Position (CUP)
            let row = (p1 > 0 ? p1 - 1 : 0)
            let col = (p2 > 0 ? p2 - 1 : 0)
            screen.setCursorPosition(col: col, row: row)

        case 0x4A: // 'J' -> Erase in Display (ED)
            screen.eraseInDisplay(mode: p1)

        case 0x4B: // 'K' -> Erase in Line (EL)
            screen.eraseInLine(mode: p1)

        case 0x4C: // 'L' -> Insert Lines
            screen.insertLines(count: max(1, p1))

        case 0x4D: // 'M' -> Delete Lines
            screen.deleteLines(count: max(1, p1))

        case 0x50: // 'P' -> Delete Characters
            screen.deleteCharacters(count: max(1, p1))

        case 0x58: // 'X' -> Erase Characters (ECH)
            screen.eraseCharacters(count: max(1, p1))

        case 0x40: // '@' -> Insert Characters
            screen.insertCharacters(count: max(1, p1))

        case 0x53: // 'S' -> Scroll Up
            screen.scrollUp(lines: max(1, p1))

        case 0x54: // 'T' -> Scroll Down
            screen.scrollDown(lines: max(1, p1))

        case 0x72: // 'r' -> Set Scroll Region (DECSTBM)
            if csiParams.isEmpty {
                screen.resetScrollRegion()
            } else {
                let top = max(0, p1 - 1)
                let bottom = (p2 > 0 ? p2 - 1 : screen.rows - 1)
                screen.setScrollRegion(top: top, bottom: bottom)
            }

        case 0x73: // 's' -> Save Cursor
            screen.saveCursor()

        case 0x75: // 'u' -> Restore Cursor
            screen.restoreCursor()

        case 0x68: // 'h' -> Set Mode
            if isPrivateMode {
                for param in csiParams {
                    switch param {
                    case 25:
                        screen.isCursorVisible = true
                    case 47, 1047, 1049:
                        screen.switchAlternateScreen(enable: true)
                    case 1:
                        screen.applicationCursorKeys = true
                    case 2004:
                        screen.bracketedPasteMode = true
                    case 9:
                        screen.mouseTrackingMode = .x10
                    case 1000:
                        screen.mouseTrackingMode = .normal
                    case 1002:
                        screen.mouseTrackingMode = .buttonEvent
                    case 1003:
                        screen.mouseTrackingMode = .anyEvent
                    case 1006:
                        screen.mouseFormat = .sgr
                    case 1007:
                        screen.alternateScrollMode = true
                    default:
                        break
                    }
                }
            }

        case 0x6C: // 'l' -> Reset Mode
            if isPrivateMode {
                for param in csiParams {
                    switch param {
                    case 25:
                        screen.isCursorVisible = false
                    case 47, 1047, 1049:
                        screen.switchAlternateScreen(enable: false)
                    case 1:
                        screen.applicationCursorKeys = false
                    case 2004:
                        screen.bracketedPasteMode = false
                    case 9, 1000, 1002, 1003:
                        screen.mouseTrackingMode = .none
                    case 1006:
                        screen.mouseFormat = .x10
                    case 1007:
                        screen.alternateScrollMode = false
                    default:
                        break
                    }
                }
            }

        case 0x6E: // 'n' -> Device Status Report (DSR)
            if p1 == 6 {
                // Report cursor position: ESC [ row ; col R
                let response = "\u{1B}[\(screen.cursorY + 1);\(screen.cursorX + 1)R"
                if let data = response.data(using: .utf8) {
                    onResponseRequired?(data)
                }
            } else if p1 == 5 {
                // Report device status OK: ESC [ 0 n
                let response = "\u{1B}[0n"
                if let data = response.data(using: .utf8) {
                    onResponseRequired?(data)
                }
            }

        default:
            break
        }
    }

    private func executeSgr() {
        if csiParams.isEmpty {
            screen.currentFg = .default
            screen.currentBg = .default
            screen.currentAttributes = []
            return
        }

        var i = 0
        while i < csiParams.count {
            let code = csiParams[i]
            switch code {
            case 0:
                screen.currentFg = .default
                screen.currentBg = .default
                screen.currentAttributes = []
            case 1:
                screen.currentAttributes.insert(.bold)
            case 2:
                screen.currentAttributes.insert(.dim)
            case 3:
                screen.currentAttributes.insert(.italic)
            case 4:
                screen.currentAttributes.insert(.underline)
            case 7:
                screen.currentAttributes.insert(.reverse)
            case 8:
                screen.currentAttributes.insert(.hidden)
            case 9:
                screen.currentAttributes.insert(.strikethrough)
            case 22:
                screen.currentAttributes.remove([.bold, .dim])
            case 23:
                screen.currentAttributes.remove(.italic)
            case 24:
                screen.currentAttributes.remove(.underline)
            case 27:
                screen.currentAttributes.remove(.reverse)
            case 28:
                screen.currentAttributes.remove(.hidden)
            case 29:
                screen.currentAttributes.remove(.strikethrough)
            case 30...37:
                screen.currentFg = .standard(UInt8(code - 30))
            case 39:
                screen.currentFg = .default
            case 40...47:
                screen.currentBg = .standard(UInt8(code - 40))
            case 49:
                screen.currentBg = .default
            case 90...97:
                screen.currentFg = .standard(UInt8(code - 90 + 8))
            case 100...107:
                screen.currentBg = .standard(UInt8(code - 100 + 8))
            case 38: // Extended Foreground
                if i + 2 < csiParams.count && csiParams[i + 1] == 5 {
                    screen.currentFg = .palette256(UInt8(csiParams[i + 2] & 0xFF))
                    i += 2
                } else if i + 4 < csiParams.count && csiParams[i + 1] == 2 {
                    screen.currentFg = .trueColor(
                        red: UInt8(csiParams[i + 2] & 0xFF),
                        green: UInt8(csiParams[i + 3] & 0xFF),
                        blue: UInt8(csiParams[i + 4] & 0xFF)
                    )
                    i += 4
                }
            case 48: // Extended Background
                if i + 2 < csiParams.count && csiParams[i + 1] == 5 {
                    screen.currentBg = .palette256(UInt8(csiParams[i + 2] & 0xFF))
                    i += 2
                } else if i + 4 < csiParams.count && csiParams[i + 1] == 2 {
                    screen.currentBg = .trueColor(
                        red: UInt8(csiParams[i + 2] & 0xFF),
                        green: UInt8(csiParams[i + 3] & 0xFF),
                        blue: UInt8(csiParams[i + 4] & 0xFF)
                    )
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    private func finishOsc() {
        // Format: "0;Title" or "2;Title"
        if oscBuffer.hasPrefix("0;") || oscBuffer.hasPrefix("2;") {
            let title = String(oscBuffer.dropFirst(2))
            onTitleChanged?(title)
        }
    }
}
