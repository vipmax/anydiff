import Foundation

/// Represents an ANSI/VT100 terminal color.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case standard(UInt8) // 0-7: standard, 8-15: bright
    case palette256(UInt8) // 0-255
    case trueColor(red: UInt8, green: UInt8, blue: UInt8)

    /// Returns standard RGB (0.0 ... 1.0) values for this color, using theme default colors as fallbacks.
    public func rgb(
        defaultForeground: (red: Double, green: Double, blue: Double) = (0.9, 0.9, 0.9),
        defaultBackground: (red: Double, green: Double, blue: Double) = (0.1, 0.1, 0.1)
    ) -> (red: Double, green: Double, blue: Double) {
        switch self {
        case .default:
            return defaultForeground
        case .standard(let code):
            return Self.standardAnsiTable[Int(code & 15)]
        case .palette256(let index):
            if index < 16 {
                return Self.standardAnsiTable[Int(index)]
            } else if index < 232 {
                // 6x6x6 color cube
                let idx = Int(index - 16)
                let r = (idx / 36) % 6
                let g = (idx / 6) % 6
                let b = idx % 6
                let conv: [Double] = [0.0, 0.372, 0.529, 0.690, 0.843, 1.0]
                return (conv[r], conv[g], conv[b])
            } else {
                // Grayscale 232-255
                let gray = Double(index - 232) / 23.0 * 0.92 + 0.04
                return (gray, gray, gray)
            }
        case .trueColor(let r, let g, let b):
            return (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0)
        }
    }

    private static let standardAnsiTable: [(Double, Double, Double)] = [
        // Standard (0-7)
        (0.00, 0.00, 0.00), // Black
        (0.80, 0.20, 0.20), // Red
        (0.20, 0.80, 0.20), // Green
        (0.80, 0.80, 0.20), // Yellow
        (0.25, 0.50, 0.90), // Blue
        (0.80, 0.30, 0.80), // Magenta
        (0.20, 0.80, 0.80), // Cyan
        (0.75, 0.75, 0.75), // White / Light gray
        // Bright (8-15)
        (0.40, 0.40, 0.40), // Bright Black / Dark gray
        (1.00, 0.35, 0.35), // Bright Red
        (0.35, 1.00, 0.35), // Bright Green
        (1.00, 1.00, 0.35), // Bright Yellow
        (0.45, 0.65, 1.00), // Bright Blue
        (1.00, 0.45, 1.00), // Bright Magenta
        (0.35, 1.00, 1.00), // Bright Cyan
        (1.00, 1.00, 1.00)  // Bright White
    ]
}

/// Text styling attributes for a terminal cell.
public struct TerminalCellAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let bold          = TerminalCellAttributes(rawValue: 1 << 0)
    public static let dim           = TerminalCellAttributes(rawValue: 1 << 1)
    public static let italic        = TerminalCellAttributes(rawValue: 1 << 2)
    public static let underline     = TerminalCellAttributes(rawValue: 1 << 3)
    public static let reverse       = TerminalCellAttributes(rawValue: 1 << 4)
    public static let hidden        = TerminalCellAttributes(rawValue: 1 << 5)
    public static let strikethrough = TerminalCellAttributes(rawValue: 1 << 6)
}
