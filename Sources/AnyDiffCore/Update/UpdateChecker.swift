import Foundation

/// A newer release than the running app.
public struct UpdateInfo: Codable, Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseURL: URL
    public let notes: String
    /// Zipped app for this Mac's architecture, when the release publishes one.
    public let downloadURL: URL?
    /// Expected SHA-256 of the zip (lowercase hex), as reported by GitHub.
    public let sha256: String?

    public init(
        version: SemanticVersion,
        releaseURL: URL,
        notes: String,
        downloadURL: URL? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.releaseURL = releaseURL
        self.notes = notes
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case badResponse
    case unrecognizedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return "GitHub did not return the latest release."
        case .unrecognizedVersion(let tag):
            return "Latest release has an unrecognized version: \"\(tag)\"."
        }
    }
}

/// Asks GitHub for the latest published (non-prerelease) release of AnyDiff.
public struct UpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/vipmax/anydiff/releases/latest")!

    /// Release zip name for this Mac's architecture, as published by `scripts/package_app.sh`.
    public static let appArchiveName: String = {
        #if arch(arm64)
        return "AnyDiff-macOS-arm64.zip"
        #else
        return "AnyDiff-macOS-x86_64.zip"
        #endif
    }()

    private let session: URLSession
    private let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = UpdateChecker.latestReleaseURL) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Returns the latest release only when it is newer than `currentVersion`.
    public func latestUpdate(newerThan currentVersion: SemanticVersion) async throws -> UpdateInfo? {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AnyDiff", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateCheckError.badResponse
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = SemanticVersion(release.tagName) else {
            throw UpdateCheckError.unrecognizedVersion(release.tagName)
        }
        guard version > currentVersion else { return nil }
        let archive = release.assets?.first { $0.name == Self.appArchiveName }
        return UpdateInfo(
            version: version,
            releaseURL: release.htmlURL,
            notes: release.body ?? "",
            downloadURL: archive?.browserDownloadURL,
            sha256: archive?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]?

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}
