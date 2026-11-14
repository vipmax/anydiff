import Foundation

public actor LSPRegistryService {
    public static let shared = LSPRegistryService()

    private var inMemoryServers: [LSPServerDefinition] = []

    public static var defaultUserConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("AnyDiff", isDirectory: true)
            .appendingPathComponent("lsp", isDirectory: true)
            .appendingPathComponent("servers.json")
    }

    public init() {
        self.inMemoryServers = Self.loadDefaultServers()
    }

    // MARK: - Server Querying

    public func allServers() -> [LSPServerDefinition] {
        inMemoryServers
    }

    public func cachedPackages() -> [LSPServerDefinition] {
        inMemoryServers
    }

    public func cachedLSPPackages() -> [LSPServerDefinition] {
        inMemoryServers
    }

    public func fetchPackages(forceRefresh: Bool = false) async throws -> [LSPServerDefinition] {
        let loaded = Self.loadDefaultServers()
        self.inMemoryServers = loaded
        return loaded
    }

    public func server(byId id: String) -> LSPServerDefinition? {
        let lower = id.lowercased()
        return inMemoryServers.first { $0.id.lowercased() == lower }
    }

    public func server(forLanguage language: String) -> LSPServerDefinition? {
        let lower = language.lowercased()
        return inMemoryServers.first { server in
            server.language.lowercased() == lower
        }
    }

    public func packages(forLanguage language: String) -> [LSPServerDefinition] {
        let lower = language.lowercased()
        return inMemoryServers.filter { server in
            server.language.lowercased() == lower
        }
    }

    public func allLanguages() -> [String] {
        var result: [String] = []
        for server in inMemoryServers {
            let lower = server.language.lowercased()
            if !result.contains(lower) {
                result.append(lower)
            }
        }
        return result
    }

    // MARK: - Installation & Commands

    public nonisolated func isInstalled(package: LSPServerDefinition) -> Bool {
        LSPRegistryBinaryDownloader.isInstalled(package: package)
    }

    public nonisolated func installedExecutablePath(package: LSPServerDefinition, languageId: String? = nil) -> String? {
        LSPRegistryBinaryDownloader.installedExecutablePath(package: package, languageId: languageId)
    }

    public nonisolated func launchCommand(for package: LSPServerDefinition, languageId: String? = nil) -> (command: String, arguments: [String])? {
        package.launchCommand(for: languageId)
    }

    public func downloadAndInstall(
        package: LSPServerDefinition,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try await LSPRegistryBinaryDownloader.downloadAndInstall(package: package, progressHandler: progressHandler)
    }

    public nonisolated func uninstall(package: LSPServerDefinition) {
        LSPRegistryBinaryDownloader.removePackage(packageId: package.id)
    }

    // MARK: - JSON Loading

    private static let resourceBundleName = "AnyDiff_AnyDiffCore.bundle"

    /// Safely resolves the resource bundle containing `lsp-servers.json` without triggering
    /// SwiftPM's `Bundle.module` `fatalError` when packaged inside a `.app` bundle.
    static func resolveResourceBundle(
        resourceURL: URL? = Bundle.main.resourceURL,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        mainBundle: Bundle = .main,
        allBundles: [Bundle] = Bundle.allBundles
    ) -> Bundle? {
        // 1. Inside App Bundle Resources (Contents/Resources/AnyDiff_AnyDiffCore.bundle)
        if let resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent(resourceBundleName)) {
            return bundle
        }
        // 2. Main bundle root (AnyDiff.app/AnyDiff_AnyDiffCore.bundle)
        if let bundle = Bundle(url: bundleURL.appendingPathComponent(resourceBundleName)) {
            return bundle
        }
        // 3. Executable directory (for CLI or development binary)
        if let execDir = executableURL?.deletingLastPathComponent(),
           let bundle = Bundle(url: execDir.appendingPathComponent(resourceBundleName)) {
            return bundle
        }
        // 4. Adjacent to any loaded bundle (e.g. xctest bundle in SwiftPM test environment)
        for loadedBundle in allBundles {
            let candidate = loadedBundle.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(resourceBundleName)
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        // 5. Directly in main bundle resources (if resources were flattened into Resources/)
        if mainBundle.path(forResource: "lsp-servers", ofType: "json") != nil {
            return mainBundle
        }
        // 6. Try Bundle.module only outside `.app` bundles (SPM development & test environment)
        #if SWIFT_PACKAGE
        if bundleURL.pathExtension != "app" {
            return Bundle.module
        }
        #endif
        return nil
    }

    static func loadBundledServers(
        from bundle: Bundle? = resolveResourceBundle(),
        mainBundle: Bundle = .main
    ) -> [LSPServerDefinition] {
        let candidatePaths = [
            bundle?.path(forResource: "lsp-servers", ofType: "json"),
            mainBundle.path(forResource: "lsp-servers", ofType: "json")
        ].compactMap { $0 }

        for path in candidatePaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let servers = try? JSONDecoder().decode([LSPServerDefinition].self, from: data),
               !servers.isEmpty {
                return servers
            }
        }
        return []
    }

    private static let bundledServers: [LSPServerDefinition] = loadBundledServers()

    public static func loadCachedPackagesFromDisk() -> [LSPServerDefinition] {
        loadDefaultServers()
    }

    public static func loadDefaultServers() -> [LSPServerDefinition] {
        let userURL = defaultUserConfigURL
        if FileManager.default.fileExists(atPath: userURL.path),
           let data = try? Data(contentsOf: userURL),
           let servers = try? JSONDecoder().decode([LSPServerDefinition].self, from: data),
           !servers.isEmpty {
            return servers
        }

        return bundledServers
    }
}