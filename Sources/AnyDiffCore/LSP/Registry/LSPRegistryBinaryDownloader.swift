import Foundation

public enum LSPDownloadError: LocalizedError, Sendable {
    case unsupportedArchiveFormat(String)
    case unsupportedPlatform(String)
    case extractionFailed(String)
    case executableNotFound(String)
    case networkError(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchiveFormat(let url):
            return "Unsupported archive format: \(url)"
        case .unsupportedPlatform(let msg):
            return "Unsupported platform: \(msg)"
        case .extractionFailed(let msg):
            return "Failed to extract archive: \(msg)"
        case .executableNotFound(let path):
            return "Executable not found at path: \(path)"
        case .networkError(let msg):
            return "Network download failed: \(msg)"
        case .executionFailed(let msg):
            return "Execution failed: \(msg)"
        }
    }
}

public enum LSPRegistryBinaryDownloader {
    public static var isRunningUnderTestingEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    public static var customBaseBinDirectory: URL? = nil

    public static var baseBinDirectory: URL {
        if let custom = customBaseBinDirectory {
            return custom
        }
        if isRunningUnderTestingEnvironment {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anydiff-test-lsp-bin", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return tempDir
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anydiff", isDirectory: true)
            .appendingPathComponent("lsp", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    public static func packageDirectory(serverId: String) -> URL {
        let sanitizedId = serverId.replacingOccurrences(of: "/", with: "_")
        return baseBinDirectory.appendingPathComponent(sanitizedId, isDirectory: true)
    }

    // MARK: - Status & Inspection

    public static func isInstalled(package: LSPServerDefinition) -> Bool {
        installedExecutablePath(package: package) != nil
    }

    public static func installedExecutablePath(package: LSPServerDefinition, languageId: String? = nil) -> String? {
        let fm = FileManager.default
        let dirsToCheck: [URL] = [
            packageDirectory(serverId: package.id),
            packageDirectory(serverId: package.binary)
        ]

        let targetBinName = package.binaryName(for: languageId)
        for targetDir in Set(dirsToCheck) {
            guard fm.fileExists(atPath: targetDir.path) else { continue }

            var candidates: [String] = [
                targetDir.appendingPathComponent(targetBinName).path,
                targetDir.appendingPathComponent("bin/\(targetBinName)").path,
                targetDir.appendingPathComponent("node_modules/.bin/\(targetBinName)").path
            ]

            if let asset = package.download?.matchingAsset(), let relBin = asset.relativeBin {
                candidates.append(targetDir.appendingPathComponent(relBin).path)
            }

            if let npmBin = package.download?.bin {
                candidates.append(targetDir.appendingPathComponent(npmBin).path)
            }

            // Direct candidate checks
            for cand in candidates {
                if fm.isExecutableFile(atPath: cand) {
                    return cand
                }
            }

            // Recursive directory search for matching binary
            if let enumerator = fm.enumerator(at: targetDir, includingPropertiesForKeys: [.isExecutableKey], options: []) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent == targetBinName, fm.isExecutableFile(atPath: fileURL.path) {
                        return fileURL.path
                    }
                }
            }
        }

        return nil
    }

    public static func removePackage(packageId: String) {
        let dir = packageDirectory(serverId: packageId)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Download & Installation

    public static func downloadAndInstall(
        package: LSPServerDefinition,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard let download = package.download else {
            throw LSPDownloadError.unsupportedPlatform("No download configuration available for \(package.name).")
        }

        let targetDir = packageDirectory(serverId: package.id)
        let fm = FileManager.default
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        switch download.type {
        case .githubRelease:
            return try await installGitHubRelease(package: package, download: download, targetDir: targetDir, progressHandler: progressHandler)

        case .npm:
            return try await installNpmPackage(package: package, download: download, targetDir: targetDir, progressHandler: progressHandler)

        case .go:
            return try await installGoPackage(package: package, download: download, targetDir: targetDir, progressHandler: progressHandler)

        case .systemOnly:
            throw LSPDownloadError.unsupportedPlatform(download.instructions ?? "\(package.name) is managed by macOS system toolchains.")
        }
    }

    // MARK: - GitHub Release Installer

    private static func installGitHubRelease(
        package: LSPServerDefinition,
        download: LSPServerDownloadSpec,
        targetDir: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        guard let asset = download.matchingAsset() else {
            throw LSPDownloadError.unsupportedPlatform("No compatible asset found for macOS (\(LSPArchitecture.current.displayName)).")
        }

        let urlString: String
        if let directURL = asset.url, !directURL.isEmpty {
            urlString = directURL
        } else {
            guard let owner = download.owner, let repo = download.repo, let tag = download.tag else {
                throw LSPDownloadError.networkError("Incomplete GitHub release metadata for \(package.id).")
            }
            urlString = "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(asset.file)"
        }
        guard let downloadURL = URL(string: urlString) else {
            throw LSPDownloadError.networkError("Invalid download URL: \(urlString)")
        }

        let fm = FileManager.default
        let tempArchive = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + asset.file)
        defer { try? fm.removeItem(at: tempArchive) }

        progressHandler?(0.1)
        try await downloadFile(from: downloadURL, to: tempArchive) { prog in
            progressHandler?(0.1 + prog * 0.75)
        }

        progressHandler?(0.85)

        switch asset.archiveType.lowercased() {
        case "gz":
            let dest = targetDir.appendingPathComponent(package.binary)
            try extractGunzip(archive: tempArchive, destination: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        case "tar.gz", "tgz":
            try extractTar(archive: tempArchive, destination: targetDir, flags: "-xzf")

        case "tar.xz":
            try extractTar(archive: tempArchive, destination: targetDir, flags: "-xJf")

        case "zip":
            try extractZip(archive: tempArchive, destination: targetDir)

        case "binary":
            let dest = targetDir.appendingPathComponent(package.binary)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: tempArchive, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        default:
            throw LSPDownloadError.unsupportedArchiveFormat("Unknown format \(asset.archiveType)")
        }

        progressHandler?(0.95)

        // Ensure all extracted files in targetDir have 0o755 permissions
        setExecutablePermissionsRecursively(at: targetDir)

        guard let installed = installedExecutablePath(package: package) else {
            throw LSPDownloadError.executableNotFound("Executable for \(package.name) not found after installation in \(targetDir.path).")
        }

        progressHandler?(1.0)
        return installed
    }

    // MARK: - npm Installer

    private static func installNpmPackage(
        package: LSPServerDefinition,
        download: LSPServerDownloadSpec,
        targetDir: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        guard let pkgName = download.package, let version = download.version else {
            throw LSPDownloadError.executionFailed("Missing npm package name or version.")
        }

        let npmPath = which("npm") ?? "/usr/local/bin/npm"
        guard FileManager.default.isExecutableFile(atPath: npmPath) else {
            throw LSPDownloadError.executionFailed("Node.js / npm is not installed on this Mac. Please install Node.js to use \(package.name).")
        }

        progressHandler?(0.2)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npmPath)
        process.environment = LSPEnvironment.makeProcessEnvironment()
        var npmArgs = ["install", "--prefix", targetDir.path, "\(pkgName)@\(version)"]
        let tsPeerPackages: Set<String> = [
            "typescript-language-server",
            "@vue/language-server",
            "svelte-language-server",
            "@astrojs/language-server"
        ]
        if tsPeerPackages.contains(pkgName) {
            npmArgs.append("typescript@5.9.3")
        }
        process.arguments = npmArgs
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "npm install error"
            throw LSPDownloadError.executionFailed("npm install failed: \(err)")
        }

        progressHandler?(0.9)
        let binDir = targetDir.appendingPathComponent("node_modules/.bin", isDirectory: true)
        setExecutablePermissionsRecursively(at: binDir)

        guard let installed = installedExecutablePath(package: package) else {
            throw LSPDownloadError.executableNotFound("npm binary not found for \(package.name) in \(targetDir.path).")
        }

        progressHandler?(1.0)
        return installed
    }

    // MARK: - Go Installer

    private static func installGoPackage(
        package: LSPServerDefinition,
        download: LSPServerDownloadSpec,
        targetDir: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        guard let pkgSpec = download.package else {
            throw LSPDownloadError.executionFailed("Missing Go package specification.")
        }

        let goPath = which("go") ?? "/usr/local/bin/go"
        guard FileManager.default.isExecutableFile(atPath: goPath) else {
            throw LSPDownloadError.executionFailed("Go compiler is not installed on this Mac. Please install Go to use \(package.name).")
        }

        progressHandler?(0.2)
        var env = LSPEnvironment.makeProcessEnvironment()
        env["GOBIN"] = targetDir.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: goPath)
        process.environment = env
        process.arguments = ["install", pkgSpec]
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "go install error"
            throw LSPDownloadError.executionFailed("go install failed: \(err)")
        }

        progressHandler?(0.95)
        setExecutablePermissionsRecursively(at: targetDir)

        guard let installed = installedExecutablePath(package: package) else {
            throw LSPDownloadError.executableNotFound("Go binary not found for \(package.name) in \(targetDir.path).")
        }

        progressHandler?(1.0)
        return installed
    }

    // MARK: - Archive Utilities

    private static func downloadFile(
        from url: URL,
        to destination: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LSPDownloadError.networkError("HTTP \(code) while downloading from \(url.absoluteString)")
        }

        let expectedLength = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destination)
        defer { try? fileHandle.close() }

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65536)

        for try await byte in bytes {
            buffer.append(byte)
            downloadedBytes += 1
            if buffer.count >= 65536 {
                fileHandle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    progressHandler?(Double(downloadedBytes) / Double(expectedLength))
                }
            }
        }
        if !buffer.isEmpty {
            fileHandle.write(buffer)
        }
        progressHandler?(1.0)
    }

    private static func extractTar(archive: URL, destination: URL, flags: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [flags, archive.path, "-C", destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw LSPDownloadError.extractionFailed("tar extraction failed with code \(process.terminationStatus)")
        }
    }

    private static func extractZip(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw LSPDownloadError.extractionFailed("unzip failed with code \(process.terminationStatus)")
        }
    }

    private static func extractGunzip(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-d", "-c", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 || data.isEmpty {
            throw LSPDownloadError.extractionFailed("gunzip failed with code \(process.terminationStatus)")
        }
        try data.write(to: destination)
    }

    private static func setExecutablePermissionsRecursively(at directory: URL) {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: []) {
            for case let fileURL as URL in enumerator {
                if !fileURL.hasDirectoryPath {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
                }
            }
        }
    }

    private static func which(_ cmd: String) -> String? {
        LSPEnvironment.which(cmd)
    }
}
