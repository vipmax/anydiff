import CryptoKit
import Foundation

/// How this copy of AnyDiff was installed, which decides how it updates itself.
public enum InstallMethod: Equatable, Sendable {
    /// Installed by the Homebrew cask `vipmax/tap/anydiff`; `brew` upgrades it in place.
    case homebrewCask(brew: URL)
    /// Anything else: the app downloads the release zip from GitHub and replaces itself.
    case directDownload

    /// Homebrew owns the app only when its Caskroom entry and `brew` binary exist under the same prefix
    /// and the running bundle is the `AnyDiff.app` the cask installs into an applications folder.
    public static func detect(
        bundleURL: URL,
        homebrewPrefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")],
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ],
        fileManager: FileManager = .default
    ) -> InstallMethod {
        let bundle = bundleURL.standardizedFileURL
        let inApplications = applicationsDirectories.contains { $0.standardizedFileURL == bundle.deletingLastPathComponent() }
        guard inApplications, bundle.lastPathComponent == UpdateInstaller.appBundleName else {
            return .directDownload
        }
        for prefix in homebrewPrefixes {
            let caskroom = prefix.appendingPathComponent("Caskroom/anydiff").path
            let brew = prefix.appendingPathComponent("bin/brew").path
            if fileManager.fileExists(atPath: caskroom), fileManager.isExecutableFile(atPath: brew) {
                return .homebrewCask(brew: URL(fileURLWithPath: brew))
            }
        }
        return .directDownload
    }
}

public enum UpdateInstallError: LocalizedError, Equatable {
    case noDownloadForThisMac
    case notWritable(String)
    case downloadFailed
    case checksumMismatch
    case unpackFailed
    case unexpectedBundle
    case homebrewFailed(String)
    case homebrewNotUpdated(SemanticVersion)

    public var errorDescription: String? {
        switch self {
        case .noDownloadForThisMac:
            return "This release has no download for this Mac."
        case .notWritable(let path):
            return "AnyDiff cannot be replaced because \(path) is not writable."
        case .downloadFailed:
            return "Downloading the update failed."
        case .checksumMismatch:
            return "The downloaded update does not match the checksum published for the release."
        case .unpackFailed:
            return "The downloaded update could not be unpacked."
        case .unexpectedBundle:
            return "The downloaded archive does not contain the expected AnyDiff version."
        case .homebrewFailed(let output):
            return "brew upgrade --cask failed:\n\(output)"
        case .homebrewNotUpdated(let version):
            return "Homebrew still installs an AnyDiff older than \(version). Try again later."
        }
    }
}

/// Installs a release either through Homebrew or by downloading the zip from GitHub.
/// Swapping the app and reopening it is `AppRelauncher`'s job, because it has to run after this process exits.
public struct UpdateInstaller: Sendable {
    public static let appBundleName = "AnyDiff.app"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Upgrades the cask in place. Homebrew may lag behind the release, so the result is checked against `info`.
    public func upgradeWithHomebrew(brew: URL, to info: UpdateInfo, appBundleURL: URL) async throws {
        let result = try await Self.runProcess(brew, arguments: ["upgrade", "--cask", "vipmax/tap/anydiff"])
        guard result.status == 0 else {
            throw UpdateInstallError.homebrewFailed(String(result.output.suffix(800)))
        }
        guard let installed = Self.installedVersion(of: appBundleURL), installed >= info.version else {
            throw UpdateInstallError.homebrewNotUpdated(info.version)
        }
    }

    /// Downloads the release zip into a new staging directory and checks its SHA-256 and version.
    /// Returns the staging directory, which holds the verified `AnyDiff.app`.
    public func downloadRelease(_ info: UpdateInfo, replacing appBundleURL: URL) async throws -> URL {
        guard let downloadURL = info.downloadURL, let expectedSHA256 = info.sha256 else {
            throw UpdateInstallError.noDownloadForThisMac
        }
        let parent = appBundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.notWritable(parent.path)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let (downloaded, response) = try await session.download(from: downloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateInstallError.downloadFailed
            }
            let archive = staging.appendingPathComponent("download.zip")
            try FileManager.default.moveItem(at: downloaded, to: archive)
            guard try Self.sha256Hex(of: archive) == expectedSHA256.lowercased() else {
                throw UpdateInstallError.checksumMismatch
            }

            let unpack = try await Self.runProcess(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, staging.path]
            )
            guard unpack.status == 0 else { throw UpdateInstallError.unpackFailed }
            try FileManager.default.removeItem(at: archive)

            guard Self.installedVersion(of: staging.appendingPathComponent(Self.appBundleName)) == info.version else {
                throw UpdateInstallError.unexpectedBundle
            }
            return staging
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Reads the version from disk. `Bundle(url:)` may return a cached instance for a path that was replaced.
    public static func installedVersion(of appBundleURL: URL) -> SemanticVersion? {
        let infoPlist = appBundleURL.appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: infoPlist)?["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init)
    }

    private static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a command without a shell and returns its exit status and combined output.
    private static func runProcess(_ executable: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Read while the process runs so a chatty command cannot fill the pipe and block.
        let reader = Task.detached { (try? pipe.fileHandleForReading.readToEnd()) ?? Data() }

        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
            // Only the child should hold the write end, so the reader sees end-of-file when it exits.
            try? pipe.fileHandleForWriting.close()
        }
        return (status, String(decoding: await reader.value, as: UTF8.self))
    }
}
