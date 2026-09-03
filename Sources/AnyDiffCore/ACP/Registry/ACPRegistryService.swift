import Foundation

public actor ACPRegistryService {
    public static let shared = ACPRegistryService()

    public static let defaultRegistryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    public static let refreshThrottleInterval: TimeInterval = 3600 // 1 hour

    private let session: URLSession
    private let registryURL: URL
    private let fileManager = FileManager.default

    private var inMemoryAgents: [ACPRegistryAgentEntry] = []
    private var lastFetchTime: Date?

    public static var defaultCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("AnyDiff", isDirectory: true).appendingPathComponent("acp-registry", isDirectory: true)
    }

    public static var defaultCachedManifestURL: URL {
        defaultCacheDirectory.appendingPathComponent("registry.json")
    }

    public static var defaultIconsDirectory: URL {
        defaultCacheDirectory.appendingPathComponent("icons", isDirectory: true)
    }

    public nonisolated var cacheDirectory: URL {
        Self.defaultCacheDirectory
    }

    public nonisolated var cachedManifestURL: URL {
        Self.defaultCachedManifestURL
    }

    public nonisolated var iconsDirectory: URL {
        Self.defaultIconsDirectory
    }

    public init(
        registryURL: URL = defaultRegistryURL,
        session: URLSession = .shared
    ) {
        self.registryURL = registryURL
        self.session = session
        self.inMemoryAgents = Self.loadCachedManifestFromDisk(cachedURL: Self.defaultCachedManifestURL)
    }

    /// Returns currently cached agents.
    public func cachedAgents() -> [ACPRegistryAgentEntry] {
        return inMemoryAgents
    }

    /// Fetches agents from the remote ACP CDN registry.
    /// If throttled and cache is present, returns cached agents immediately unless `forceRefresh` is true.
    public func fetchAgents(forceRefresh: Bool = false) async throws -> [ACPRegistryAgentEntry] {
        let shouldThrottle = !forceRefresh && lastFetchTime != nil && Date().timeIntervalSince(lastFetchTime!) < Self.refreshThrottleInterval && !inMemoryAgents.isEmpty
        if shouldThrottle {
            return inMemoryAgents
        }

        do {
            var request = URLRequest(url: registryURL)
            request.timeoutInterval = 20
            request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "ACPRegistryService", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) fetching ACP registry"])
            }

            let decoder = JSONDecoder()
            let index = try decoder.decode(ACPRegistryIndex.self, from: data)

            self.inMemoryAgents = index.agents
            self.lastFetchTime = Date()

            // Save to disk cache
            saveManifestToDisk(data: data)

            return index.agents
        } catch {
            // Offline fallback: If network fails, return cached agents if available
            if !inMemoryAgents.isEmpty {
                return inMemoryAgents
            }
            throw error
        }
    }

    /// Checks if the agent's prebuilt binary is already downloaded and executable.
    public nonisolated func isBinaryInstalled(for entry: ACPRegistryAgentEntry) -> Bool {
        guard let target = entry.currentPlatformBinaryTarget else { return false }
        return ACPRegistryBinaryDownloader.isInstalled(agentId: entry.id, version: entry.version, cmd: target.cmd)
    }

    /// Returns the absolute path to the binary if installed.
    public nonisolated func installedBinaryPath(for entry: ACPRegistryAgentEntry) -> String? {
        guard let target = entry.currentPlatformBinaryTarget else { return nil }
        let path = ACPRegistryBinaryDownloader.expectedExecutablePath(agentId: entry.id, version: entry.version, cmd: target.cmd)
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Downloads and installs the native prebuilt binary for the agent.
    public func downloadAndInstallBinary(
        for entry: ACPRegistryAgentEntry,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard let target = entry.currentPlatformBinaryTarget else {
            throw ACPRegistryDownloadError.executableNotFound("No binary target configured for current platform")
        }
        return try await ACPRegistryBinaryDownloader.downloadAndInstall(
            agentId: entry.id,
            version: entry.version,
            target: target,
            progressHandler: progressHandler
        )
    }

    // MARK: - Local Cache Helpers

    private static func loadCachedManifestFromDisk(cachedURL: URL) -> [ACPRegistryAgentEntry] {
        guard FileManager.default.fileExists(atPath: cachedURL.path) else { return [] }
        guard let data = try? Data(contentsOf: cachedURL) else { return [] }
        if let index = try? JSONDecoder().decode(ACPRegistryIndex.self, from: data) {
            return index.agents
        }
        return []
    }

    private func saveManifestToDisk(data: Data) {
        let cacheDir = self.cacheDirectory
        let manifestURL = self.cachedManifestURL
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
