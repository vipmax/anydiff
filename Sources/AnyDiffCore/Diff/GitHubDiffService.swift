import Foundation

/// Reference to a remote GitHub or git diff source
public struct GitHubDiffReference: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case pullRequest(Int)
        case commit(String)
        case compare(base: String, head: String)
        case custom(URL)
    }

    public let owner: String?
    public let repo: String?
    public let kind: Kind
    public let diffURL: URL
    public let webURL: URL?
    public let displayTitle: String

    public init(
        owner: String? = nil,
        repo: String? = nil,
        kind: Kind,
        diffURL: URL,
        webURL: URL? = nil,
        displayTitle: String
    ) {
        self.owner = owner
        self.repo = repo
        self.kind = kind
        self.diffURL = diffURL
        self.webURL = webURL
        self.displayTitle = displayTitle
    }
}

/// Service for resolving and fetching public GitHub diffs and patches
public final class GitHubDiffService: Sendable {
    public static let shared = GitHubDiffService()

    public init() {}

    public enum ServiceError: LocalizedError {
        case invalidURL(String)
        case networkError(String)
        case notFound
        case emptyDiff
        case forbiddenOrRateLimited

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let str):
                return "Invalid GitHub or Diff URL: \"\(str)\""
            case .networkError(let msg):
                return "Network request failed: \(msg)"
            case .notFound:
                return "Diff not found. Ensure the repository and Pull Request are public."
            case .emptyDiff:
                return "The diff returned from GitHub was empty (no changes)."
            case .forbiddenOrRateLimited:
                return "GitHub rate limit exceeded or access denied."
            }
        }
    }

    /// Parses an input string (GitHub URL, DiffsHub URL, shorthand like `owner/repo#123`, or raw diff URL) into a `GitHubDiffReference`
    public func parseReference(from input: String) -> Result<GitHubDiffReference, ServiceError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidURL(input))
        }

        // 1. Shorthand: `owner/repo#123` or `owner/repo/pull/123`
        if let shorthandRef = parseShorthand(trimmed) {
            return .success(shorthandRef)
        }

        // 2. Parse URL
        var normalizedString = trimmed
        if !normalizedString.lowercased().hasPrefix("http://") && !normalizedString.lowercased().hasPrefix("https://") {
            normalizedString = "https://" + normalizedString
        }

        guard let url = URL(string: normalizedString), let host = url.host?.lowercased() else {
            return .failure(.invalidURL(input))
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        // 3. GitHub or DiffsHub URLs:
        if host == "github.com" || host == "www.github.com" || host == "diffshub.com" || host == "www.diffshub.com" {
            // Pattern: /owner/repo/pull/123
            if pathComponents.count >= 4 && pathComponents[2].lowercased() == "pull" {
                let owner = pathComponents[0]
                let repo = pathComponents[1]
                let prStr = pathComponents[3].replacingOccurrences(of: ".diff", with: "").replacingOccurrences(of: ".patch", with: "")
                if let prNumber = Int(prStr) {
                    guard let diffURL = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(prNumber).diff"),
                          let webURL = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(prNumber)") else {
                        return .failure(.invalidURL(input))
                    }
                    return .success(GitHubDiffReference(
                        owner: owner,
                        repo: repo,
                        kind: .pullRequest(prNumber),
                        diffURL: diffURL,
                        webURL: webURL,
                        displayTitle: "\(owner)/\(repo) #\(prNumber)"
                    ))
                }
            }

            // Pattern: /owner/repo/commit/sha
            if pathComponents.count >= 4 && pathComponents[2].lowercased() == "commit" {
                let owner = pathComponents[0]
                let repo = pathComponents[1]
                let sha = pathComponents[3].replacingOccurrences(of: ".diff", with: "").replacingOccurrences(of: ".patch", with: "")
                let shortSha = String(sha.prefix(7))
                guard let diffURL = URL(string: "https://github.com/\(owner)/\(repo)/commit/\(sha).diff"),
                      let webURL = URL(string: "https://github.com/\(owner)/\(repo)/commit/\(sha)") else {
                    return .failure(.invalidURL(input))
                }
                return .success(GitHubDiffReference(
                    owner: owner,
                    repo: repo,
                    kind: .commit(sha),
                    diffURL: diffURL,
                    webURL: webURL,
                    displayTitle: "\(owner)/\(repo) @ \(shortSha)"
                ))
            }

            // Pattern: /owner/repo/compare/base...head
            if pathComponents.count >= 4 && pathComponents[2].lowercased() == "compare" {
                let owner = pathComponents[0]
                let repo = pathComponents[1]
                let compareRef = pathComponents[3].replacingOccurrences(of: ".diff", with: "").replacingOccurrences(of: ".patch", with: "")
                let parts = compareRef.components(separatedBy: "...")
                let base = parts.first ?? compareRef
                let head = parts.count > 1 ? parts[1] : ""
                guard let diffURL = URL(string: "https://github.com/\(owner)/\(repo)/compare/\(compareRef).diff"),
                      let webURL = URL(string: "https://github.com/\(owner)/\(repo)/compare/\(compareRef)") else {
                    return .failure(.invalidURL(input))
                }
                return .success(GitHubDiffReference(
                    owner: owner,
                    repo: repo,
                    kind: .compare(base: base, head: head),
                    diffURL: diffURL,
                    webURL: webURL,
                    displayTitle: "\(owner)/\(repo): \(compareRef)"
                ))
            }
        }

        // 4. Raw Diff / Patch URLs (e.g. patch-diff.githubusercontent.com, gist, or direct .diff/.patch)
        if host.contains("githubusercontent.com") || host.contains("gist.github.com") || url.pathExtension == "diff" || url.pathExtension == "patch" || trimmed.hasSuffix(".diff") || trimmed.hasSuffix(".patch") {
            let title = url.lastPathComponent.isEmpty ? url.host ?? "Remote Diff" : url.lastPathComponent
            return .success(GitHubDiffReference(
                owner: nil,
                repo: nil,
                kind: .custom(url),
                diffURL: url,
                webURL: url,
                displayTitle: title
            ))
        }

        // 5. Fallback generic HTTP URL
        return .success(GitHubDiffReference(
            owner: nil,
            repo: nil,
            kind: .custom(url),
            diffURL: url,
            webURL: url,
            displayTitle: url.host ?? "Remote Diff"
        ))
    }

    private func parseShorthand(_ input: String) -> GitHubDiffReference? {
        // e.g. "oven-sh/bun#30412" or "bun#30412"
        let hashParts = input.components(separatedBy: "#")
        if hashParts.count == 2, let prNumber = Int(hashParts[1].trimmingCharacters(in: .whitespaces)) {
            let repoPart = hashParts[0].trimmingCharacters(in: .whitespaces)
            let slashParts = repoPart.components(separatedBy: "/")
            let owner = slashParts.count > 1 ? slashParts[0] : nil
            let repo = slashParts.count > 1 ? slashParts[1] : slashParts[0]

            if let owner = owner {
                guard let diffURL = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(prNumber).diff"),
                      let webURL = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(prNumber)") else {
                    return nil
                }
                return GitHubDiffReference(
                    owner: owner,
                    repo: repo,
                    kind: .pullRequest(prNumber),
                    diffURL: diffURL,
                    webURL: webURL,
                    displayTitle: "\(owner)/\(repo) #\(prNumber)"
                )
            }
        }
        return nil
    }

    /// Fetches the raw diff text for a given `GitHubDiffReference`
    public func fetchDiff(for reference: GitHubDiffReference) async throws -> String {
        var request = URLRequest(url: reference.diffURL)
        request.httpMethod = "GET"
        request.setValue("AnyDiff/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, application/vnd.github.v3.diff, */*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 45

        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.networkError("Invalid server response")
            }

            if httpResponse.statusCode == 404 {
                throw ServiceError.notFound
            } else if httpResponse.statusCode == 403 {
                throw ServiceError.forbiddenOrRateLimited
            } else if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                throw ServiceError.networkError("HTTP Status \(httpResponse.statusCode)")
            }

            guard let diffText = String(data: data, encoding: .utf8) else {
                // Try ISO Latin 1 fallback
                if let latinStr = String(data: data, encoding: .isoLatin1) {
                    return latinStr
                }
                throw ServiceError.networkError("Failed to decode diff text from server (unknown character encoding)")
            }

            let trimmed = diffText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ServiceError.emptyDiff
            }

            return diffText
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.networkError(error.localizedDescription)
        }
    }

    /// Streams `FileDiff`s incrementally in real time as HTTP chunks arrive from GitHub
    public func streamDiff(for reference: GitHubDiffReference) -> AsyncThrowingStream<FileDiff, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: reference.diffURL)
                    request.httpMethod = "GET"
                    request.setValue("AnyDiff/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
                    request.setValue("text/plain, application/vnd.github.v3.diff, */*", forHTTPHeaderField: "Accept")
                    request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
                    request.timeoutInterval = 60

                    let configuration = URLSessionConfiguration.default
                    configuration.httpShouldSetCookies = true
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let session = URLSession(configuration: configuration)

                    let (asyncBytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ServiceError.networkError("Invalid server response")
                    }

                    if httpResponse.statusCode == 404 {
                        throw ServiceError.notFound
                    } else if httpResponse.statusCode == 403 {
                        throw ServiceError.forbiddenOrRateLimited
                    } else if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                        throw ServiceError.networkError("HTTP Status \(httpResponse.statusCode)")
                    }

                    let streamer = StreamingGitDiffParser()
                    for try await line in asyncBytes.lines {
                        if Task.isCancelled { break }
                        if let fileDiff = streamer.feed(line: line) {
                            continuation.yield(fileDiff)
                        }
                    }

                    if !Task.isCancelled, let finalFile = streamer.finish() {
                        continuation.yield(finalFile)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Convenience method to parse and fetch a diff directly from an input string
    public func fetchDiff(from input: String) async throws -> (reference: GitHubDiffReference, diffText: String) {
        switch parseReference(from: input) {
        case .success(let ref):
            let diff = try await fetchDiff(for: ref)
            return (ref, diff)
        case .failure(let err):
            throw err
        }
    }
}
