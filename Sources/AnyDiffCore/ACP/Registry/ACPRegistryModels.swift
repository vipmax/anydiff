import Foundation

// MARK: - Registry Index & Agent Entry

public struct ACPRegistryIndex: Codable, Sendable {
    public let version: String
    public let agents: [ACPRegistryAgentEntry]

    public init(version: String, agents: [ACPRegistryAgentEntry]) {
        self.version = version
        self.agents = agents
    }
}

public struct ACPRegistryAgentEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let repository: String?
    public let website: String?
    public let authors: [String]?
    public let license: String?
    public let licenseUrl: String?
    public let icon: String?
    public let distribution: ACPRegistryDistribution

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, repository, website
        case authors, license
        case licenseUrl = "license_url"
        case icon, distribution
    }

    public init(
        id: String,
        name: String,
        version: String,
        description: String,
        repository: String? = nil,
        website: String? = nil,
        authors: [String]? = nil,
        license: String? = nil,
        licenseUrl: String? = nil,
        icon: String? = nil,
        distribution: ACPRegistryDistribution
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.repository = repository
        self.website = website
        self.authors = authors
        self.license = license
        self.licenseUrl = licenseUrl
        self.icon = icon
        self.distribution = distribution
    }

    /// Returns the current host macOS platform key, e.g. "darwin-aarch64" or "darwin-x86_64".
    public static var currentPlatformKey: String {
        #if arch(arm64)
        return "darwin-aarch64"
        #elseif arch(x86_64)
        return "darwin-x86_64"
        #else
        return "darwin-unknown"
        #endif
    }

    /// Whether this agent can run on the current platform (either via npx or via native binary).
    public var isSupportedOnCurrentPlatform: Bool {
        if distribution.npx != nil {
            return true
        }
        if let binary = distribution.binary, binary[Self.currentPlatformKey] != nil {
            return true
        }
        return false
    }

    /// Returns the binary target configuration for the current platform if available.
    public var currentPlatformBinaryTarget: ACPRegistryBinaryTarget? {
        distribution.binary?[Self.currentPlatformKey]
    }

    /// Converts this registry entry into an AnyDiff `AgentPreset`.
    /// - Parameter binaryInstalledPath: If the agent has a pre-downloaded native binary, pass its absolute path here.
    public func toAgentPreset(binaryInstalledPath: String? = nil) -> AgentPreset {
        let (command, args): (String, String)

        if let binaryPath = binaryInstalledPath, !binaryPath.isEmpty {
            command = binaryPath.contains(" ") && !binaryPath.hasPrefix("\"") ? "\"\(binaryPath)\"" : binaryPath
            let targetArgs = currentPlatformBinaryTarget?.args ?? []
            args = targetArgs.joined(separator: " ")
        } else if let npx = distribution.npx {
            command = "npx"
            var combinedArgs = ["-y", npx.package]
            if let extraArgs = npx.args {
                combinedArgs.append(contentsOf: extraArgs)
            }
            args = combinedArgs.joined(separator: " ")
        } else if let target = currentPlatformBinaryTarget {
            // Default binary command path under AnyDiff Application Support
            let defaultBinaryPath = ACPRegistryBinaryDownloader.expectedExecutablePath(
                agentId: id,
                version: version,
                cmd: target.cmd
            )
            command = defaultBinaryPath.contains(" ") && !defaultBinaryPath.hasPrefix("\"") ? "\"\(defaultBinaryPath)\"" : defaultBinaryPath
            let targetArgs = target.args ?? []
            args = targetArgs.joined(separator: " ")
        } else {
            command = id
            args = ""
        }

        let provider = authors?.first ?? "ACP Registry"
        let icon = selectIconName()
        let color = selectColorName()

        return AgentPreset(
            id: id,
            name: name,
            command: command,
            arguments: args,
            iconName: icon,
            colorName: color,
            providerName: provider,
            summary: description,
            isMock: false,
            isCustom: true
        )
    }

    private func selectIconName() -> String {
        let lower = id.lowercased()
        if lower.contains("claude") { return "claude" }
        if lower.contains("codex") || lower.contains("openai") { return "openai" }
        if lower.contains("antigravity") || lower.contains("gemini") { return "googlegemini" }
        if lower.contains("amp") { return "bolt.fill" }
        if lower.contains("goose") { return "bird" }
        if lower.contains("auggie") || lower.contains("augment") { return "sparkles" }
        if lower.contains("cline") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("codebuddy") { return "person.2.fill" }
        if lower.contains("copilot") { return "cpu" }
        if lower.contains("cursor") { return "cursorarrow.rays" }
        return "terminal"
    }

    private func selectColorName() -> String {
        let lower = id.lowercased()
        if lower.contains("claude") { return "orange" }
        if lower.contains("codex") || lower.contains("openai") { return "white" }
        if lower.contains("antigravity") || lower.contains("gemini") { return "blue" }
        if lower.contains("goose") { return "teal" }
        if lower.contains("amp") { return "purple" }
        if lower.contains("cline") { return "cyan" }
        if lower.contains("codebuddy") { return "teal" }
        if lower.contains("auggie") || lower.contains("augment") { return "purple" }
        if lower.contains("copilot") { return "blue" }
        if lower.contains("cursor") { return "cyan" }
        return "blue"
    }
}

// MARK: - Distribution Models

public struct ACPRegistryDistribution: Codable, Sendable, Equatable {
    public let npx: ACPRegistryNpxDistribution?
    public let binary: [String: ACPRegistryBinaryTarget]?

    public init(
        npx: ACPRegistryNpxDistribution? = nil,
        binary: [String: ACPRegistryBinaryTarget]? = nil
    ) {
        self.npx = npx
        self.binary = binary
    }
}

public struct ACPRegistryNpxDistribution: Codable, Sendable, Equatable {
    public let package: String
    public let args: [String]?
    public let env: [String: String]?

    public init(package: String, args: [String]? = nil, env: [String: String]? = nil) {
        self.package = package
        self.args = args
        self.env = env
    }
}

public struct ACPRegistryBinaryTarget: Codable, Sendable, Equatable {
    public let archive: String
    public let cmd: String
    public let args: [String]?
    public let sha256: String?
    public let env: [String: String]?

    public init(
        archive: String,
        cmd: String,
        args: [String]? = nil,
        sha256: String? = nil,
        env: [String: String]? = nil
    ) {
        self.archive = archive
        self.cmd = cmd
        self.args = args
        self.sha256 = sha256
        self.env = env
    }
}
