import SwiftUI
import AnyDiffCore

extension AgentPreset {
    var color: Color {
        switch colorName {
        case "white": return Color(nsColor: .labelColor)
        case "black": return .black
        case "gray": return .gray
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "teal": return .teal
        case "cyan": return .cyan
        case "pink": return .pink
        case "red": return .red
        default: return .accentColor
        }
    }
}
