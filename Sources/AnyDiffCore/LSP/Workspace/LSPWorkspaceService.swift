import Foundation

public struct LSPServerStatusItem: Identifiable, Sendable {
    public let id: String
    public let languageId: String
    public let serverName: String
    public let executablePath: String
    public let state: LSPClient.State
    public let openDocumentsCount: Int
    public let lastActivityDate: Date?
    public let autoStopDeadline: Date?

    public init(
        id: String,
        languageId: String,
        serverName: String,
        executablePath: String,
        state: LSPClient.State,
        openDocumentsCount: Int,
        lastActivityDate: Date? = nil,
        autoStopDeadline: Date? = nil
    ) {
        self.id = id
        self.languageId = languageId
        self.serverName = serverName
        self.executablePath = executablePath
        self.state = state
        self.openDocumentsCount = openDocumentsCount
        self.lastActivityDate = lastActivityDate
        self.autoStopDeadline = autoStopDeadline
    }
}

public actor LSPWorkspaceService {
    public static let shared = LSPWorkspaceService()
    public static let serversDidChangeNotification = Notification.Name("anyDiffLSPServersDidChange")
    public static let defaultIdleTimeout: TimeInterval = 300 // 5 minutes
    public static let autoStopEnabledUserDefaultsKey = "anyDiffLSPAutoStopEnabled"
    public static let idleTimeoutUserDefaultsKey = "anyDiffLSPIdleTimeoutSeconds"

    private var activeClients: [String: LSPClient] = [:] // key: languageId
    private var openDocumentLanguages: [String: String] = [:] // key: filePath -> languageId
    private var idleTimerTasks: [String: Task<Void, Never>] = [:] // key: languageId
    private var lastActivityDates: [String: Date] = [:] // key: languageId
    public private(set) var idleTimeout: TimeInterval = {
        let saved = UserDefaults.standard.double(forKey: "anyDiffLSPIdleTimeoutSeconds")
        return saved > 0 ? saved : 300
    }()
    public private(set) var isAutoStopEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "anyDiffLSPAutoStopEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "anyDiffLSPAutoStopEnabled")
    }()

    public init() {}

    /// Enables or disables automatic idle shutdown of LSP servers.
    public func setAutoStopEnabled(_ enabled: Bool, persist: Bool = true) {
        isAutoStopEnabled = enabled
        if enabled && idleTimeout <= 0 {
            idleTimeout = Self.defaultIdleTimeout
        }
        if persist {
            UserDefaults.standard.set(enabled, forKey: Self.autoStopEnabledUserDefaultsKey)
        }
        if !enabled {
            for (_, task) in idleTimerTasks {
                task.cancel()
            }
            idleTimerTasks.removeAll()
        } else {
            let now = Date()
            for languageId in activeClients.keys {
                lastActivityDates[languageId] = now
                scheduleIdleTimer(for: languageId)
            }
        }
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
    }

    /// Configures the inactivity timeout (in seconds) after which an unused LSP server is automatically stopped.
    /// Pass `0` or a negative value to disable auto-shutdown.
    public func setIdleTimeout(_ timeout: TimeInterval, persist: Bool = false) {
        idleTimeout = timeout
        if timeout <= 0 {
            isAutoStopEnabled = false
            if persist {
                UserDefaults.standard.set(false, forKey: Self.autoStopEnabledUserDefaultsKey)
            }
            for (_, task) in idleTimerTasks {
                task.cancel()
            }
            idleTimerTasks.removeAll()
        } else {
            isAutoStopEnabled = true
            if persist {
                UserDefaults.standard.set(true, forKey: Self.autoStopEnabledUserDefaultsKey)
                UserDefaults.standard.set(timeout, forKey: Self.idleTimeoutUserDefaultsKey)
            }
            let now = Date()
            for languageId in activeClients.keys {
                lastActivityDates[languageId] = now
                scheduleIdleTimer(for: languageId)
            }
        }
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
    }

    public func lastActivityDate(for languageId: String) -> Date? {
        lastActivityDates[languageId.lowercased()]
    }

    private func recordActivity(for languageId: String) {
        let key = languageId.lowercased()
        lastActivityDates[key] = Date()
        scheduleIdleTimer(for: key)
    }

    private func cancelIdleTimer(for languageId: String) {
        let key = languageId.lowercased()
        idleTimerTasks.removeValue(forKey: key)?.cancel()
        lastActivityDates.removeValue(forKey: key)
    }

    private func scheduleIdleTimer(for languageId: String) {
        let key = languageId.lowercased()
        idleTimerTasks.removeValue(forKey: key)?.cancel()
        guard isAutoStopEnabled, idleTimeout > 0, activeClients[key] != nil else { return }

        let timeout = idleTimeout
        idleTimerTasks[key] = Task { [weak self] in
            let nanos = UInt64(timeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.handleIdleTimeout(for: key)
        }
    }

    private func handleIdleTimeout(for languageId: String) async {
        let key = languageId.lowercased()
        guard !Task.isCancelled, isAutoStopEnabled, activeClients[key] != nil, idleTimeout > 0 else { return }
        if let lastActivity = lastActivityDates[key] {
            let elapsed = Date().timeIntervalSince(lastActivity)
            if elapsed + 0.02 < idleTimeout {
                let remaining = max(0.02, idleTimeout - elapsed)
                idleTimerTasks[key] = Task { [weak self] in
                    let nanos = UInt64(remaining * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled else { return }
                    await self?.handleIdleTimeout(for: key)
                }
                return
            }
        }
        await stopServer(for: key)
    }

    // MARK: - Language Detection

    public nonisolated func detectLanguage(for filePath: String) -> String {
        let baseName = ((filePath as NSString).lastPathComponent).lowercased()
        if baseName == "dockerfile" || baseName.hasPrefix("dockerfile.") || baseName == "containerfile" {
            return "dockerfile"
        }

        let ext = (filePath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }

        // Check if any server in the curated catalog explicitly declares this file extension
        let servers = LSPRegistryService.loadDefaultServers()
        for server in servers {
            if let lang = server.language(forExtension: ext) {
                return lang
            }
        }

        return ext
    }

    /// Returns the LSP protocol `textDocument.languageId` for `didOpen` (e.g. `typescriptreact` for `.tsx` and `javascriptreact` for `.jsx`).
    public nonisolated func documentLanguageId(for filePath: String) -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "tsx":
            return "typescriptreact"
        case "jsx":
            return "javascriptreact"
        default:
            return detectLanguage(for: filePath).lowercased()
        }
    }

    // MARK: - Server Resolution

    /// Resolves executable path, canonical display server name, and arguments for a given language.
    /// Strictly uses local AnyDiff binaries in ~/.anydiff/lsp/bin (no global PATH resolution, except systemOnly toolchains like Xcode sourcekit-lsp).
    public func resolveServer(for languageId: String) async -> (serverName: String, command: String, args: [String])? {
        let registry = LSPRegistryService.shared
        let matchingServers = await registry.packages(forLanguage: languageId)

        // 1. Check installed registry packages in AnyDiff local bin directory (~/.anydiff/lsp/bin)
        for server in matchingServers {
            if let (cmd, args) = registry.launchCommand(for: server, languageId: languageId) {
                if FileManager.default.isExecutableFile(atPath: cmd) {
                    let name = server.canonicalName(for: languageId)
                    return (name, cmd, args)
                }
            }
        }

        // 2. Only for system toolchains (e.g. sourcekit-lsp bundled with macOS/Xcode)
        for server in matchingServers where server.download?.type == .systemOnly {
            let bin = server.binaryName(for: languageId)
            if let path = (server.id == "sourcekit-lsp" ? checkXcodeSourceKitLSP() : nil) ?? which(bin) {
                let name = server.canonicalName(for: languageId)
                let args = server.launchArguments(for: languageId)
                return (name, path, args)
            }
        }

        return nil
    }

    // MARK: - Client Management

    public func getOrStartClient(for languageId: String, rootPath: String) async throws -> LSPClient? {
        let lang = languageId.lowercased()
        if let existing = activeClients[lang] {
            let state = await existing.state
            if state == .ready || state == .initializing {
                recordActivity(for: lang)
                return existing
            }
        }

        guard let resolved = await resolveServer(for: lang) else {
            return nil
        }

        let client = LSPClient(
            executablePath: resolved.command,
            arguments: resolved.args,
            workingDirectory: rootPath,
            serverName: resolved.serverName
        )

        try await client.start(rootPath: rootPath)
        activeClients[lang] = client
        recordActivity(for: lang)
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
        return client
    }

    // MARK: - Server Status & Control

    public func activeServerStatuses() async -> [LSPServerStatusItem] {
        var items: [LSPServerStatusItem] = []
        for (lang, client) in activeClients {
            let state = await client.state
            let exec = client.executablePath
            let name = client.serverName
            let docCount = openDocumentLanguages.values.filter { $0 == lang }.count
            let lastAct = lastActivityDates[lang]
            let deadline: Date? = (isAutoStopEnabled && idleTimeout > 0) ? lastAct?.addingTimeInterval(idleTimeout) : nil
            items.append(LSPServerStatusItem(
                id: lang,
                languageId: lang,
                serverName: name,
                executablePath: exec,
                state: state,
                openDocumentsCount: docCount,
                lastActivityDate: lastAct,
                autoStopDeadline: deadline
            ))
        }
        return items.sorted { $0.languageId < $1.languageId }
    }

    public func stopServer(for languageId: String) async {
        let lang = languageId.lowercased()
        cancelIdleTimer(for: lang)
        if let client = activeClients.removeValue(forKey: lang) {
            await client.stop()
        }
        openDocumentLanguages = openDocumentLanguages.filter { $0.value != lang }
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
    }

    public func restartServer(for languageId: String, rootPath: String) async throws -> LSPClient? {
        await stopServer(for: languageId)
        let client = try await getOrStartClient(for: languageId, rootPath: rootPath)
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
        return client
    }

    public func discoverAvailableServers() async -> [(languageId: String, serverName: String, command: String)] {
        var results: [(languageId: String, serverName: String, command: String)] = []
        var checkedLanguages: Set<String> = []

        // 1. Check all installed registry packages first
        let installedPackages = await LSPRegistryService.shared.cachedPackages().filter {
            LSPRegistryService.shared.isInstalled(package: $0)
        }
        for pkg in installedPackages {
            let langLower = pkg.language.lowercased()
            if !checkedLanguages.contains(langLower) {
                checkedLanguages.insert(langLower)
                if let (cmd, args) = LSPRegistryService.shared.launchCommand(for: pkg, languageId: langLower) {
                    let name = LSPServerCatalog.canonicalServerName(
                        fromExecutablePath: cmd,
                        arguments: args,
                        fallbackLanguageId: langLower
                    )
                    results.append((languageId: langLower, serverName: name.isEmpty ? pkg.name : name, command: cmd))
                }
            }
        }

        // 2. Check all languages declared across curated catalog servers
        let catalogLanguages = await LSPRegistryService.shared.allLanguages()
        for lang in catalogLanguages where !checkedLanguages.contains(lang) {
            checkedLanguages.insert(lang)
            if let resolved = await resolveServer(for: lang) {
                results.append((languageId: lang, serverName: resolved.serverName, command: resolved.command))
            }
        }
        return results
    }

    public func isPackageAvailable(_ package: LSPRegistryPackage) async -> Bool {
        if package.isInstalled { return true }
        if package.download?.type == .systemOnly {
            let bin = package.binaryName(for: package.language)
            let path = (package.id == "sourcekit-lsp" ? checkXcodeSourceKitLSP() : nil) ?? which(bin)
            return path != nil
        }
        return false
    }

    public func startPackage(_ package: LSPRegistryPackage, rootPath: String) async throws -> LSPClient? {
        let lang = package.language.lowercased()
        let resolved: (serverName: String, command: String, args: [String])? = await {
            if let (cmd, args) = LSPRegistryService.shared.launchCommand(for: package, languageId: lang),
               FileManager.default.isExecutableFile(atPath: cmd) {
                return (package.canonicalName(for: lang), cmd, args)
            }
            if package.download?.type == .systemOnly {
                let bin = package.binaryName(for: lang)
                if let path = (package.id == "sourcekit-lsp" ? checkXcodeSourceKitLSP() : nil) ?? which(bin) {
                    return (package.canonicalName(for: lang), path, package.launchArguments(for: lang))
                }
            }
            return await resolveServer(for: lang)
        }()

        guard let resolved else {
            throw LSPDownloadError.executableNotFound("Executable not found for package \(package.name)")
        }
        cancelIdleTimer(for: lang)
        if let existing = activeClients[lang] {
            await existing.stop()
        }
        let client = LSPClient(
            executablePath: resolved.command,
            arguments: resolved.args,
            workingDirectory: rootPath,
            serverName: resolved.serverName
        )
        try await client.start(rootPath: rootPath)
        activeClients[lang] = client
        recordActivity(for: lang)
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
        return client
    }

    public func stopPackage(_ package: LSPRegistryPackage) async {
        await stopServer(for: package.language.lowercased())
    }

    public func restartPackage(_ package: LSPRegistryPackage, rootPath: String) async throws -> LSPClient? {
        await stopPackage(package)
        return try await startPackage(package, rootPath: rootPath)
    }

    private func canonicalPath(_ filePath: String, rootPath: String? = nil) -> String {
        if (filePath as NSString).isAbsolutePath {
            return filePath
        }
        if let root = rootPath, !root.isEmpty {
            return (root as NSString).appendingPathComponent(filePath)
        }
        return filePath
    }

    // MARK: - Document Synchronization

    public func notifyDocumentOpened(filePath: String, text: String, rootPath: String) async {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        let lang = detectLanguage(for: absPath).lowercased()
        let docLang = documentLanguageId(for: absPath)
        openDocumentLanguages[absPath] = lang

        do {
            if let client = try await getOrStartClient(for: lang, rootPath: rootPath) {
                try await client.didOpen(filePath: absPath, text: text, languageId: docLang)
                recordActivity(for: lang)
            }
        } catch {
            // Silently ignore if server failed to start on background open
        }
    }

    public func notifyDocumentChanged(filePath: String, text: String, rootPath: String? = nil) async {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        guard let lang = openDocumentLanguages[absPath] ?? openDocumentLanguages[filePath],
              let client = activeClients[lang] else { return }
        recordActivity(for: lang)
        try? await client.didChange(filePath: absPath, text: text)
    }

    public func notifyDocumentSaved(filePath: String, rootPath: String? = nil) async {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        guard let lang = openDocumentLanguages[absPath] ?? openDocumentLanguages[filePath],
              let client = activeClients[lang] else { return }
        recordActivity(for: lang)
        try? await client.didSave(filePath: absPath)
    }

    public func notifyDocumentClosed(filePath: String, rootPath: String? = nil) async {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        guard let lang = openDocumentLanguages.removeValue(forKey: absPath) ?? openDocumentLanguages.removeValue(forKey: filePath),
              let client = activeClients[lang] else { return }
        recordActivity(for: lang)
        try? await client.didClose(filePath: absPath)
    }

    // MARK: - Go To Definition

    public func gotoDefinition(
        filePath: String,
        line: Int, // 1-based editor line
        column: Int, // 1-based editor column
        rootPath: String,
        contentSupplier: (() -> String)? = nil
    ) async throws -> [LSPLocation] {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        let lang = detectLanguage(for: absPath).lowercased()
        let docLang = documentLanguageId(for: absPath)
        guard let client = try await getOrStartClient(for: lang, rootPath: rootPath) else {
            return []
        }

        // Ensure file is opened and synchronized in LSP session
        if openDocumentLanguages[absPath] == nil {
            if let text = contentSupplier?() {
                try? await client.didOpen(filePath: absPath, text: text, languageId: docLang)
                openDocumentLanguages[absPath] = lang
            }
        } else if let text = contentSupplier?() {
            try? await client.didChange(filePath: absPath, text: text)
        }

        // LSP positions are 0-based
        let lspLine = max(0, line - 1)
        let lspCol = max(0, column - 1)

        defer { recordActivity(for: lang) }
        return try await client.gotoDefinition(filePath: absPath, line: lspLine, character: lspCol)
    }

    // MARK: - Code Completion

    public func getCompletions(
        filePath: String,
        line: Int, // 1-based editor line
        column: Int, // 1-based editor column
        rootPath: String,
        triggerCharacter: String? = nil,
        contentSupplier: (() -> String)? = nil
    ) async throws -> [LSPCompletionItem] {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        let lang = detectLanguage(for: absPath).lowercased()
        let docLang = documentLanguageId(for: absPath)
        guard let client = try await getOrStartClient(for: lang, rootPath: rootPath) else {
            return []
        }

        // Ensure file is opened and synchronized in LSP session
        if openDocumentLanguages[absPath] == nil {
            if let text = contentSupplier?() {
                try? await client.didOpen(filePath: absPath, text: text, languageId: docLang)
                openDocumentLanguages[absPath] = lang
            }
        } else if let text = contentSupplier?() {
            try? await client.didChange(filePath: absPath, text: text)
        }

        // LSP positions are 0-based
        let lspLine = max(0, line - 1)
        let lspCol = max(0, column - 1)

        defer { recordActivity(for: lang) }
        return try await client.getCompletions(
            filePath: absPath,
            line: lspLine,
            character: lspCol,
            triggerCharacter: triggerCharacter
        )
    }

    // MARK: - Hover

    public func getHover(
        filePath: String,
        line: Int, // 1-based editor line
        column: Int, // 1-based editor column
        rootPath: String,
        contentSupplier: (() -> String)? = nil
    ) async throws -> LSPHover? {
        let absPath = canonicalPath(filePath, rootPath: rootPath)
        let lang = detectLanguage(for: absPath).lowercased()
        let docLang = documentLanguageId(for: absPath)
        guard let client = try await getOrStartClient(for: lang, rootPath: rootPath) else {
            return nil
        }

        // Ensure file is opened and synchronized in LSP session
        if openDocumentLanguages[absPath] == nil {
            if let text = contentSupplier?() {
                try? await client.didOpen(filePath: absPath, text: text, languageId: docLang)
                openDocumentLanguages[absPath] = lang
            }
        } else if let text = contentSupplier?() {
            try? await client.didChange(filePath: absPath, text: text)
        }

        // LSP positions are 0-based
        let lspLine = max(0, line - 1)
        let lspCol = max(0, column - 1)

        defer { recordActivity(for: lang) }
        return try await client.getHover(
            filePath: absPath,
            line: lspLine,
            character: lspCol
        )
    }

    public func stopAll() async {
        for (_, task) in idleTimerTasks {
            task.cancel()
        }
        idleTimerTasks.removeAll()
        lastActivityDates.removeAll()
        for (_, client) in activeClients {
            await client.stop()
        }
        activeClients.removeAll()
        openDocumentLanguages.removeAll()
        NotificationCenter.default.post(name: Self.serversDidChangeNotification, object: nil)
    }

    // MARK: - Path Helpers

    private nonisolated func which(_ cmd: String) -> String? {
        LSPEnvironment.which(cmd)
    }

    private nonisolated func checkXcodeSourceKitLSP() -> String? {
        let standard = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        if FileManager.default.isExecutableFile(atPath: standard) {
            return standard
        }
        let clt = "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp"
        if FileManager.default.isExecutableFile(atPath: clt) {
            return clt
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc.arguments = ["--find", "sourcekit-lsp"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            if (try? proc.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0,
                   let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty,
                   FileManager.default.isExecutableFile(atPath: str) {
                    return str
                }
            }
        }
        return nil
    }
}
