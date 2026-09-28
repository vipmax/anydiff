import Foundation

/// Service managing isolated agent account profiles stored in `~/.anydiff/profiles/<profileId>`.
public enum AgentProfileService {
    /// Base directory where AnyDiff stores isolated agent profiles.
    public static var baseProfilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anydiff", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }

    /// Known profile environment templates for standard AI agent providers.
    public static let knownProfileTemplates: [String: [String: String]] = [
        "antigravity-acp": [
            "GEMINI_HOME": "~/.anydiff/profiles/${id}",
            "AGY_ACP_FORCE_FILE_STORAGE": "1"
        ],
        "antigravity": [
            "GEMINI_HOME": "~/.anydiff/profiles/${id}",
            "AGY_ACP_FORCE_FILE_STORAGE": "1"
        ],
        "agy": [
            "GEMINI_HOME": "~/.anydiff/profiles/${id}",
            "AGY_ACP_FORCE_FILE_STORAGE": "1"
        ],
        "gemini": [
            "GEMINI_HOME": "~/.anydiff/profiles/${id}",
            "AGY_ACP_FORCE_FILE_STORAGE": "1"
        ],
        "claude": [
            "CLAUDE_CONFIG_DIR": "~/.anydiff/profiles/${id}"
        ],
        "claude-code-acp": [
            "CLAUDE_CONFIG_DIR": "~/.anydiff/profiles/${id}"
        ],
        "codex": [
            "CODEX_HOME": "~/.anydiff/profiles/${id}"
        ],
        "codex-acp": [
            "CODEX_HOME": "~/.anydiff/profiles/${id}"
        ]
    ]

    /// Fallback template for custom or unknown agents.
    public static let genericProfileTemplate: [String: String] = [
        "ANYDIFF_PROFILE_DIR": "~/.anydiff/profiles/${id}"
    ]

    /// Sanitizes a profile name into an ID-safe URL/file slug (e.g. "Work Account" -> "work-account").
    public static func sanitizeSlug(_ name: String) -> String {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var lastWasHyphen = false

        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(Character(scalar))
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "profile" : trimmed
    }

    /// Determines the base/root agent ID without profile-specific slug suffixes.
    public static func rootAgentId(for agentId: String, profile: String? = nil) -> String {
        if let profile = profile, !profile.isEmpty {
            let slug = sanitizeSlug(profile)
            if agentId.hasSuffix("-" + slug) {
                let prefixLen = agentId.count - (slug.count + 1)
                return String(agentId.prefix(prefixLen))
            }
        }

        // If the ID is a standard UUID (e.g. custom agent without profile), preserve it intact
        if UUID(uuidString: agentId) != nil {
            return agentId
        }

        let sortedKeys = knownProfileTemplates.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            if agentId == key || agentId.hasPrefix(key + "-") {
                return key
            }
        }

        if let lastHyphen = agentId.lastIndex(of: "-") {
            let prefix = String(agentId[..<lastHyphen])
            if !prefix.isEmpty {
                return prefix
            }
        }

        return agentId
    }

    /// Returns the environment variable mapping for a specified agent and profile ID.
    public static func profileEnvironment(
        for agentId: String,
        profileId: String,
        customTemplate: [String: String]? = nil
    ) -> [String: String] {
        let rootId = rootAgentId(for: agentId)
        let template = customTemplate
            ?? knownProfileTemplates[agentId]
            ?? knownProfileTemplates[rootId]
            ?? genericProfileTemplate

        var result: [String: String] = [:]
        for (key, val) in template {
            result[key] = val.replacingOccurrences(of: "${id}", with: profileId)
        }
        return result
    }

    /// Resolves `~` and `~/` in paths and automatically ensures directories exist for `_HOME`, `_DIR`,
    /// or paths located inside `~/.anydiff/profiles`.
    public static func resolveEnvironment(
        _ env: [String: String]?,
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let env = env, !env.isEmpty else { return [:] }

        let homePath = fileManager.homeDirectoryForCurrentUser.path
        var resolved: [String: String] = [:]

        for (key, val) in env {
            let expanded: String
            if val == "~" {
                expanded = homePath
            } else if val.hasPrefix("~/") {
                expanded = (homePath as NSString).appendingPathComponent(String(val.dropFirst(2)))
            } else {
                expanded = val
            }

            // Ensure profile/home directory exists on disk
            if key.hasSuffix("_HOME") || key.hasSuffix("_DIR") || expanded.contains("/.anydiff/profiles/") {
                if !fileManager.fileExists(atPath: expanded) {
                    try? fileManager.createDirectory(
                        atPath: expanded,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                }
            }

            resolved[key] = expanded
        }

        return resolved
    }

    /// Parses a composite display string like "Antigravity (Work)" into baseName and optional profileName.
    public static func parseDisplayName(_ fullName: String) -> (baseName: String, profileName: String?) {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")") else {
            return (baseName: trimmed, profileName: nil)
        }

        guard let openParen = trimmed.lastIndex(of: "(") else {
            return (baseName: trimmed, profileName: nil)
        }

        let base = String(trimmed[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = String(trimmed[trimmed.index(after: openParen)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !profile.isEmpty else {
            return (baseName: trimmed, profileName: nil)
        }

        return (baseName: base.isEmpty ? trimmed : base, profileName: profile)
    }
}
