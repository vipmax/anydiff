import Foundation

/// Launch specification for a language server.
public struct LSPServerLaunchSpec: Sendable, Equatable {
    public let arguments: [String]
    public let preferredBinary: String?

    public init(arguments: [String] = [], preferredBinary: String? = nil) {
        self.arguments = arguments
        self.preferredBinary = preferredBinary
    }
}

/// Catalog query helper that dynamically retrieves server definitions from the curated lsp-servers.json catalog.
public enum LSPServerCatalog {

    /// Returns launch specification for a package name or binary name from the curated catalog.
    public static func launchSpec(for name: String) -> LSPServerLaunchSpec {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let servers = LSPRegistryService.loadDefaultServers()

        // Direct match by id or binary name
        if let direct = servers.first(where: { server in
            server.id.lowercased() == key ||
            server.binary.lowercased() == key
        }) {
            return LSPServerLaunchSpec(arguments: direct.launchArguments(), preferredBinary: direct.binary)
        }

        return LSPServerLaunchSpec(arguments: [])
    }

    /// Returns launch specification for an LSP server definition.
    public static func launchSpec(for package: LSPServerDefinition) -> LSPServerLaunchSpec {
        LSPServerLaunchSpec(arguments: package.launchArguments(), preferredBinary: package.binary)
    }

    /// Determines clean human-readable server name, normalizing away generic runners like `npx`, `node`, `bun`, `sh`.
    public static func canonicalServerName(
        fromExecutablePath execPath: String,
        arguments: [String] = [],
        fallbackLanguageId: String? = nil
    ) -> String {
        let rawBase = (execPath as NSString).lastPathComponent
        let base = rawBase.lowercased()
        let genericRunners: Set<String> = ["npx", "node", "bun", "python", "python3", "sh", "bash", "zsh", "cmd", "env"]

        if !genericRunners.contains(base) && !base.isEmpty {
            return rawBase
        }

        let servers = LSPRegistryService.loadDefaultServers()

        // 1. Try extracting real tool/server from arguments if run via runner like `npx`
        var candidates: [String] = []
        for arg in arguments {
            if arg.hasPrefix("-") || arg.isEmpty { continue }
            let candidate = (arg as NSString).lastPathComponent
            let lower = candidate.lowercased()
            if genericRunners.contains(lower) { continue }
            if candidate.hasPrefix("@") && candidate.contains("/") {
                let parts = candidate.split(separator: "/")
                if let last = parts.last, !last.isEmpty {
                    candidates.append(String(last))
                }
            } else if !candidate.hasPrefix("@") {
                candidates.append(candidate)
            }
        }

        // Prefer candidates matching known servers in catalog
        let knownBinaryNames = Set(servers.map { $0.binary.lowercased() })
        for cand in candidates.reversed() {
            if knownBinaryNames.contains(cand.lowercased()) {
                return cand
            }
        }
        for cand in candidates.reversed() {
            let lower = cand.lowercased()
            if lower.contains("language-server") || lower.hasSuffix("-lsp") || lower.hasSuffix("-langserver") {
                return cand
            }
        }
        if let last = candidates.last {
            return last
        }

        // 2. Map fallback language ID to server name using catalog
        if let lang = fallbackLanguageId?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            if let server = servers.first(where: { $0.language.lowercased() == lang }) {
                return server.canonicalName(for: lang)
            }
        }

        return rawBase.isEmpty ? (fallbackLanguageId ?? "language-server") : rawBase
    }
}
