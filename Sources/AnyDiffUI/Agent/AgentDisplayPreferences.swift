import Foundation

public enum ToolcallColorMode: String, CaseIterable, Sendable {
    case none
    case icon
    case label
    case badge
    case full

    public var title: String {
        switch self {
        case .none: return "No Colors"
        case .icon: return "Icon Only"
        case .label: return "Label + Icon"
        case .badge: return "Badge Only"
        case .full: return "Full"
        }
    }
}

/// Persisted visual preferences for the agent workspace.
public enum AgentDisplayPreferences {
    public static let disableColorsKey = "anydiff_agent_disable_colors"
    public static let toolcallColorModeKey = "anydiff_agent_toolcall_color_mode"
    public static let didChangeNotification = Notification.Name("anyDiffAgentDisplayPreferencesChanged")

    public static var toolcallColorMode: ToolcallColorMode {
        if let rawValue = UserDefaults.standard.string(forKey: toolcallColorModeKey),
           let mode = ToolcallColorMode(rawValue: rawValue) {
            return mode
        }

        // Preserve the previous boolean preference after upgrading.
        return UserDefaults.standard.bool(forKey: disableColorsKey) ? .none : .full
    }
}
