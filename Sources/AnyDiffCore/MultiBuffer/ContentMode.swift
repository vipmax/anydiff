import Foundation

/// Rendering mode for the contents displayed by a MultiBuffer.
public enum ContentMode: String, Codable, Sendable, Equatable {
    case text
    case diff
}
