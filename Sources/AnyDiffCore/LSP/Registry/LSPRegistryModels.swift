import Foundation

// MARK: - Host Platform & Architecture Detection

public enum LSPArchitecture: String, Sendable, CaseIterable, Codable {
    case arm64
    case x86_64
    case unknown

    public static var current: LSPArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    public var displayName: String {
        switch self {
        case .arm64: return "Apple Silicon (ARM64)"
        case .x86_64: return "Intel (x86_64)"
        case .unknown: return "Unknown Arch"
        }
    }
}

public enum LSPOperatingSystem: String, Sendable, CaseIterable, Codable {
    case darwin
    case linux
    case windows
    case unknown

    public static var current: LSPOperatingSystem {
        #if os(macOS)
        return .darwin
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .unknown
        #endif
    }

    public var displayName: String {
        switch self {
        case .darwin: return "macOS"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "Unknown OS"
        }
    }
}

public struct LSPHostPlatform: Sendable {
    public let os: LSPOperatingSystem
    public let arch: LSPArchitecture

    public static let current = LSPHostPlatform(
        os: .current,
        arch: .current
    )

    public init(os: LSPOperatingSystem = .current, arch: LSPArchitecture = .current) {
        self.os = os
        self.arch = arch
    }
}

// MARK: - macOS Download Specifications

public enum LSPServerDownloadType: String, Codable, Sendable {
    case githubRelease
    case npm
    case go
    case systemOnly
}

public struct LSPDownloadAsset: Codable, Sendable, Equatable {
    public let file: String
    public let archiveType: String // "gz", "tar.gz", "tar.xz", "zip", "binary"
    public let relativeBin: String?
    public let url: String?

    public init(file: String, archiveType: String, relativeBin: String? = nil, url: String? = nil) {
        self.file = file
        self.archiveType = archiveType
        self.relativeBin = relativeBin
        self.url = url
    }
}

public struct LSPServerDownloadSpec: Codable, Sendable, Equatable {
    public let type: LSPServerDownloadType

    // GitHub Release fields
    public let owner: String?
    public let repo: String?
    public let tag: String?
    public let arm64: LSPDownloadAsset?
    public let x86_64: LSPDownloadAsset?
    public let asset: LSPDownloadAsset?

    // npm / go fields
    public let package: String?
    public let version: String?
    public let bin: String?

    // System instructions
    public let instructions: String?

    public init(
        type: LSPServerDownloadType,
        owner: String? = nil,
        repo: String? = nil,
        tag: String? = nil,
        arm64: LSPDownloadAsset? = nil,
        x86_64: LSPDownloadAsset? = nil,
        asset: LSPDownloadAsset? = nil,
        package: String? = nil,
        version: String? = nil,
        bin: String? = nil,
        instructions: String? = nil
    ) {
        self.type = type
        self.owner = owner
        self.repo = repo
        self.tag = tag
        self.arm64 = arm64
        self.x86_64 = x86_64
        self.asset = asset
        self.package = package
        self.version = version
        self.bin = bin
        self.instructions = instructions
    }

    public func matchingAsset(for arch: LSPArchitecture = .current) -> LSPDownloadAsset? {
        if let asset = asset {
            return asset
        }
        switch arch {
        case .arm64:
            // Prefer native arm64, fallback to x86_64 (runs under Rosetta 2 on Apple Silicon)
            return arm64 ?? x86_64
        case .x86_64:
            return x86_64 ?? arm64
        case .unknown:
            return arm64 ?? x86_64
        }
    }

    public var systemRequirementLabel: String {
        guard let instructions = instructions, !instructions.isEmpty else {
            return "Requires Xcode"
        }
        if let colonIndex = instructions.firstIndex(of: ":") {
            let prefix = instructions[..<colonIndex].trimmingCharacters(in: .whitespaces)
            if prefix.lowercased().hasPrefix("install via ") {
                let tool = prefix.dropFirst("install via ".count)
                return "Requires \(tool)"
            }
            return prefix
        }
        return instructions
    }
}

// MARK: - LSP Server Definition

public struct LSPServerDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public var languages: [String] { [language] }
    public let summary: String?
    public let binary: String
    public let fileExtensions: [String]
    public let arguments: [String]?
    public let download: LSPServerDownloadSpec?

    public var isLSP: Bool { true }

    enum CodingKeys: String, CodingKey {
        case id, name, language, languages, summary, binary, fileExtensions, arguments, download
    }

    public init(
        id: String,
        name: String,
        language: String,
        fileExtensions: [String] = [],
        summary: String? = nil,
        binary: String,
        arguments: [String]? = nil,
        download: LSPServerDownloadSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.fileExtensions = fileExtensions
        self.summary = summary
        self.binary = binary
        self.arguments = arguments
        self.download = download
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        if let lang = try container.decodeIfPresent(String.self, forKey: .language) {
            self.language = lang
        } else if let langs = try container.decodeIfPresent([String].self, forKey: .languages), let first = langs.first {
            self.language = first
        } else {
            self.language = ""
        }
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.binary = try container.decode(String.self, forKey: .binary)
        self.fileExtensions = try container.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments)
        self.download = try container.decodeIfPresent(LSPServerDownloadSpec.self, forKey: .download)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encode(binary, forKey: .binary)
        try container.encode(fileExtensions, forKey: .fileExtensions)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(download, forKey: .download)
    }

    /// Returns the exact binary name for the server.
    public func binaryName(for languageId: String? = nil) -> String {
        binary
    }

    /// Resolves the specific languageId for a given file extension if supported by this server.
    public func language(forExtension ext: String) -> String? {
        if fileExtensions.contains(where: { $0.caseInsensitiveCompare(ext) == .orderedSame }) {
            return language.lowercased()
        }
        return nil
    }

    /// Returns launch arguments for the server.
    public func launchArguments(for languageId: String? = nil) -> [String] {
        arguments ?? []
    }

    /// Checks if this server has been downloaded and installed into AnyDiff's local bin directory.
    public var isInstalled: Bool {
        LSPRegistryBinaryDownloader.installedExecutablePath(package: self) != nil
    }

    /// Path to installed executable in AnyDiff's local bin directory.
    public func installedExecutablePath(for languageId: String? = nil) -> String? {
        LSPRegistryBinaryDownloader.installedExecutablePath(package: self, languageId: languageId)
    }

    /// Generates launch executable path and arguments for this server if installed in AnyDiff bin directory.
    public func launchCommand(for languageId: String? = nil) -> (command: String, arguments: [String])? {
        guard let execPath = installedExecutablePath(for: languageId) else {
            return nil
        }
        return (execPath, launchArguments(for: languageId))
    }

    /// List of binary candidate names to check in system PATH if not installed locally.
    public func systemBinaryCandidates(for languageId: String? = nil) -> [String] {
        [binary]
    }

    /// Human-readable canonical display name for the server.
    public func canonicalName(for languageId: String? = nil) -> String {
        id
    }
}

/// Backwards compatibility alias for components referencing `LSPRegistryPackage`.
public typealias LSPRegistryPackage = LSPServerDefinition
