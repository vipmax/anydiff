import SwiftUI
import AppKit
import AnyDiffCore

extension AgentPreset {
    func nsColor(isDark: Bool) -> NSColor {
        switch colorName.lowercased() {
        case "white":
            return isDark ? .white : NSColor(white: 0.15, alpha: 1.0)
        case "black":
            return isDark ? NSColor(white: 0.85, alpha: 1.0) : .black
        case "gray": return .systemGray
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "teal", "cyan": return .systemTeal
        case "pink": return .systemPink
        case "red": return .systemRed
        default: return .controlAccentColor
        }
    }

    var nsColor: NSColor {
        nsColor(isDark: true)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }
}

