import AppKit

/// Helper for native macOS tactile and haptic feedback on Force Touch trackpads.
public enum HapticFeedback {
    public enum Pattern {
        /// Standard tactile feedback (e.g. action completed, button pressed, item dropped).
        case generic
        /// Weak tactile feedback (e.g. snapping, alignment, light keypress, prompt sent).
        case alignment
        /// Stronger/step-change tactile feedback (e.g. mode change, warning, revert, permission prompt).
        case levelChange
    }

    /// User preference key to toggle haptic feedback on or off.
    public static let hapticsEnabledKey = "anydiff.haptics.enabled"

    /// Whether haptic feedback is globally enabled (defaults to true).
    public static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: hapticsEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hapticsEnabledKey)
        }
    }

    /// Performs haptic feedback with the given pattern.
    /// Safely ignores if haptics are disabled or if trackpad does not support Force Touch.
    public static func perform(_ pattern: Pattern = .generic, performanceTime: NSHapticFeedbackManager.PerformanceTime = .default) {
        guard isEnabled else { return }

        let nspattern: NSHapticFeedbackManager.FeedbackPattern
        switch pattern {
        case .generic:
            nspattern = .generic
        case .alignment:
            nspattern = .alignment
        case .levelChange:
            nspattern = .levelChange
        }

        NSHapticFeedbackManager.defaultPerformer.perform(nspattern, performanceTime: performanceTime)
    }
}
