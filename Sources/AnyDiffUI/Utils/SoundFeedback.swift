import AppKit

/// Helper for native macOS sound notifications and audio feedback.
public enum SoundFeedback {
    public enum SoundType: Equatable {
        /// Subtle pleasant completion chime (Tink)
        case completion
        /// Alert / error sound (Basso)
        case error
        /// Attention / prompt sound (Pop)
        case attention
        /// Custom macOS system sound by name
        case custom(String)
    }

    /// User preference key to toggle sound effects globally on or off.
    public static let soundEnabledKey = "anydiff.sound.enabled"

    /// Whether sound effects are globally enabled (defaults to true).
    public static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundEnabledKey)
        }
    }

    /// Plays a macOS sound effect if sound is enabled.
    public static func play(_ type: SoundType = .completion) {
        guard isEnabled else { return }

        let soundName: String
        switch type {
        case .completion:
            soundName = "Tink"
        case .error:
            soundName = "Basso"
        case .attention:
            soundName = "Pop"
        case .custom(let name):
            soundName = name
        }

        if let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.play()
        }
    }
}
