import Foundation

/// Mouse button identifiers used in terminal protocols.
public enum TerminalMouseButton: Int, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case release = 3
    case wheelUp = 64
    case wheelDown = 65
}

/// Modifier keys active during a mouse event in the terminal.
public struct TerminalMouseModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift   = TerminalMouseModifiers(rawValue: 4)
    public static let option  = TerminalMouseModifiers(rawValue: 8)
    public static let control = TerminalMouseModifiers(rawValue: 16)
}

/// Type of mouse interaction.
public enum TerminalMouseEventType: Sendable {
    case press
    case release
    case drag
    case move
}

/// Encodes mouse events into ANSI/VT terminal escape sequences (X10, Normal 1000, SGR 1006).
public enum TerminalMouseEncoder {
    /// Encodes a mouse event into the byte sequence expected by the running interactive terminal application.
    public static func encode(
        button: TerminalMouseButton,
        type: TerminalMouseEventType,
        modifiers: TerminalMouseModifiers = [],
        col: Int, // 1-based
        row: Int, // 1-based
        format: TerminalMouseFormat
    ) -> Data? {
        let safeCol = max(1, col)
        let safeRow = max(1, row)

        var code = button.rawValue
        if type == .drag {
            code += 32
        } else if type == .move {
            code = 35 // motion without button pressed
        }
        code += modifiers.rawValue

        switch format {
        case .sgr:
            // SGR extended format: ESC [ < code ; col ; row (M for press/motion/wheel, m for release)
            let isRelease = (type == .release)
            let terminator = isRelease ? "m" : "M"
            let str = "\u{1B}[<\(code);\(safeCol);\(safeRow)\(terminator)"
            return str.data(using: .utf8)

        case .x10:
            // Legacy format: ESC [ M (code + 32) (col + 32) (row + 32)
            guard safeCol <= 223, safeRow <= 223 else { return nil }
            var bytes: [UInt8] = [0x1B, 0x5B, 0x4D]
            bytes.append(UInt8(min(255, 32 + (type == .release ? 3 : code))))
            bytes.append(UInt8(min(255, 32 + safeCol)))
            bytes.append(UInt8(min(255, 32 + safeRow)))
            return Data(bytes)
        }
    }
}
