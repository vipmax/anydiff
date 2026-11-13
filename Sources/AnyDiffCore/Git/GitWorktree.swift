import Foundation

/// Resolved Git directory paths for a working tree (supports both normal repos and linked worktrees).
public struct GitRepositoryPaths: Equatable, Sendable {
    public let worktreeRoot: String
    public let gitDir: String
    public let commonDir: String

    public var isLinkedWorktree: Bool {
        gitDir != commonDir
    }

    /// Root path of the main repository checkout (or the bare repository directory).
    public var mainRepositoryPath: String {
        guard isLinkedWorktree else { return worktreeRoot }
        let commonURL = URL(fileURLWithPath: commonDir)
        if commonURL.lastPathComponent == ".git" {
            return commonURL.deletingLastPathComponent().path
        }
        return commonDir
    }

    /// Stable repository folder name across the main checkout and any linked worktrees.
    public var repositoryName: String {
        let name = (mainRepositoryPath as NSString).lastPathComponent
        if !name.isEmpty && name != "/" {
            return name
        }
        return (worktreeRoot as NSString).lastPathComponent
    }

    public init(worktreeRoot: String, gitDir: String, commonDir: String) {
        self.worktreeRoot = worktreeRoot
        self.gitDir = gitDir
        self.commonDir = commonDir
    }
}

/// Represents an entry from `git worktree list --porcelain`.
public struct GitWorktree: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let head: String
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let prunableReason: String?
    public let isMain: Bool

    public var folderName: String {
        (path as NSString).lastPathComponent
    }

    public var displayTitle: String {
        if let branch, !branch.isEmpty {
            return branch
        }
        if isBare {
            return "bare"
        }
        if !head.isEmpty {
            return "detached (\(String(head.prefix(7))))"
        }
        return folderName
    }

    public init(
        path: String,
        head: String = "",
        branch: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil,
        isMain: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
        self.isMain = isMain
    }
}

public enum GitWorktreeError: LocalizedError, Sendable, Equatable {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

extension GitService {
    /// Resolves `worktreeRoot`, `gitDir`, and `commonDir` directly from `.git` without spawning `git`.
    /// Works identically for regular repositories and linked worktrees where `.git` is a `gitdir:` pointer file.
    public func resolveGitPaths(at directory: String) -> GitRepositoryPaths? {
        guard !directory.isEmpty else { return nil }
        let fm = FileManager.default
        var current = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL

        while true {
            let dotGitURL = current.appendingPathComponent(".git", isDirectory: false)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGitURL.path, isDirectory: &isDir) {
                let rootPath = current.resolvingSymlinksInPath().path
                if isDir.boolValue {
                    let gitDirPath = dotGitURL.resolvingSymlinksInPath().path
                    return GitRepositoryPaths(
                        worktreeRoot: rootPath,
                        gitDir: gitDirPath,
                        commonDir: gitDirPath
                    )
                }

                // `.git` is a file containing `gitdir: <path>`
                guard let content = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
                    return nil
                }
                var rawGitDir: String?
                for line in content.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("gitdir:") {
                        rawGitDir = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                guard let rawGitDir, !rawGitDir.isEmpty else { return nil }

                let gitDirURL: URL
                if (rawGitDir as NSString).isAbsolutePath {
                    gitDirURL = URL(fileURLWithPath: rawGitDir).resolvingSymlinksInPath()
                } else {
                    gitDirURL = current.appendingPathComponent(rawGitDir).resolvingSymlinksInPath()
                }
                let gitDirPath = gitDirURL.path

                let commonDirFile = gitDirURL.appendingPathComponent("commondir", isDirectory: false)
                let commonDirPath: String
                if let commonRaw = try? String(contentsOf: commonDirFile, encoding: .utf8) {
                    let trimmedCommon = commonRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedCommon.isEmpty {
                        commonDirPath = gitDirPath
                    } else if (trimmedCommon as NSString).isAbsolutePath {
                        commonDirPath = URL(fileURLWithPath: trimmedCommon).resolvingSymlinksInPath().path
                    } else {
                        commonDirPath = gitDirURL.appendingPathComponent(trimmedCommon).resolvingSymlinksInPath().path
                    }
                } else {
                    commonDirPath = gitDirPath
                }

                return GitRepositoryPaths(
                    worktreeRoot: rootPath,
                    gitDir: gitDirPath,
                    commonDir: commonDirPath
                )
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return nil
    }

    /// Returns a display title for the active linked (non-main) worktree at `directory`,
    /// or `nil` when `directory` points to the main worktree or is not inside a git repository.
    public func nonMainWorktreeDisplayTitle(
        at directory: String,
        worktrees: [GitWorktree]
    ) -> String? {
        guard !directory.isEmpty else { return nil }
        let expanded = (directory as NSString).expandingTildeInPath
        let resolvedDir = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let gitPaths = resolveGitPaths(at: directory)
        let targetRoot = gitPaths?.worktreeRoot ?? resolvedDir

        if let matched = worktrees.first(where: { wt in
            let wtResolved = URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path
            return wtResolved == targetRoot || wtResolved == resolvedDir
        }) {
            guard !matched.isMain else { return nil }
            return matched.displayTitle
        }

        guard let gitPaths, gitPaths.isLinkedWorktree else {
            return nil
        }

        let headURL = URL(fileURLWithPath: gitPaths.gitDir).appendingPathComponent("HEAD", isDirectory: false)
        if let rawHead = try? String(contentsOf: headURL, encoding: .utf8) {
            let head = rawHead.trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("ref:") {
                let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if ref.hasPrefix("refs/heads/") {
                    let branch = String(ref.dropFirst("refs/heads/".count))
                    if !branch.isEmpty {
                        return branch
                    }
                } else if !ref.isEmpty {
                    return ref
                }
            } else if !head.isEmpty {
                return "detached (\(String(head.prefix(7))))"
            }
        }

        let folder = (gitPaths.worktreeRoot as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }

    /// Lists all worktrees belonging to the repository at `path`.
    public func worktrees(at path: String) -> [GitWorktree] {
        guard !path.isEmpty else { return [] }
        if let data = runData(arguments: ["-C", path, "worktree", "list", "--porcelain", "-z"]) {
            let parsed = Self.parseWorktreesPorcelainZ(data)
            if !parsed.isEmpty {
                return parsed
            }
        }
        if let data = runData(arguments: ["-C", path, "worktree", "list", "--porcelain"]) {
            return Self.parseWorktreesPorcelainLines(data)
        }
        return []
    }

    /// Creates a new worktree at `destinationPath`.
    public func addWorktree(
        at repoPath: String,
        destinationPath: String,
        branch: String,
        baseRef: String? = nil,
        createBranch: Bool = true
    ) -> Result<String, GitWorktreeError> {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDest = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty, !trimmedDest.isEmpty else {
            return .failure(.commandFailed("Branch name and destination path are required."))
        }

        var args = ["-C", repoPath, "worktree", "add"]
        if createBranch {
            args.append(contentsOf: ["-b", trimmedBranch, trimmedDest])
            if let baseRef, !baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args.append(baseRef.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            args.append(contentsOf: [trimmedDest, trimmedBranch])
        }

        let parentURL = URL(fileURLWithPath: trimmedDest).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let result = runWithStatus(arguments: args)
        if result.exitCode == 0 {
            let resolved = URL(fileURLWithPath: trimmedDest).resolvingSymlinksInPath().path
            return .success(resolved)
        }
        let msg = result.stderr.isEmpty ? "git worktree add failed (exit \(result.exitCode))." : result.stderr
        return .failure(.commandFailed(msg))
    }

    /// Removes an existing linked worktree at `worktreePath`.
    public func removeWorktree(
        at repoPath: String,
        worktreePath: String,
        force: Bool = false
    ) -> Result<Void, GitWorktreeError> {
        var args = ["-C", repoPath, "worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append(worktreePath)

        let result = runWithStatus(arguments: args)
        if result.exitCode == 0 {
            return .success(())
        }
        let msg = result.stderr.isEmpty ? "git worktree remove failed (exit \(result.exitCode))." : result.stderr
        return .failure(.commandFailed(msg))
    }

    /// Base root directory for AnyDiff-managed worktrees (`~/.anydiff/worktrees`).
    public static var anydiffWorktreesRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".anydiff", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
    }

    /// Computes a managed worktree path under `~/.anydiff/worktrees/<repoName>/<sanitizedBranch>`
    /// so worktrees never clutter sibling project folders or nest inside repositories.
    public func defaultWorktreePath(
        at repoPath: String,
        branch: String,
        worktreesBaseDirectory: URL? = nil
    ) -> String {
        let rootPath: String
        if let mainPath = worktrees(at: repoPath).first?.path, !mainPath.isEmpty {
            rootPath = mainPath
        } else if let resolved = resolveGitPaths(at: repoPath)?.worktreeRoot {
            rootPath = resolved
        } else {
            rootPath = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        }

        let rootURL = URL(fileURLWithPath: rootPath)
        let repoName = Self.sanitizeFolderComponent(rootURL.lastPathComponent, fallback: "repo")
        let folder = Self.sanitizeFolderComponent(branch, fallback: "worktree")
        let baseDir = worktreesBaseDirectory ?? Self.anydiffWorktreesRootURL
        return baseDir
            .appendingPathComponent(repoName, isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .path
    }

    /// Generates a unique branch name and destination path from a user prompt.
    public func suggestedWorktreeBranchAndPath(
        at repoPath: String,
        prompt: String,
        existingBranches: [String]? = nil,
        worktreesBaseDirectory: URL? = nil
    ) -> (branch: String, path: String) {
        let baseSlug = Self.worktreeSlug(from: prompt)
        let knownBranches = Set(existingBranches ?? branches(at: repoPath).local)
        let fm = FileManager.default

        var candidate = baseSlug
        var candidatePath = defaultWorktreePath(
            at: repoPath,
            branch: candidate,
            worktreesBaseDirectory: worktreesBaseDirectory
        )
        var suffix = 2

        while knownBranches.contains(candidate) || fm.fileExists(atPath: candidatePath) {
            candidate = "\(baseSlug)-\(suffix)"
            candidatePath = defaultWorktreePath(
                at: repoPath,
                branch: candidate,
                worktreesBaseDirectory: worktreesBaseDirectory
            )
            suffix += 1
        }

        return (candidate, candidatePath)
    }

    /// Derives a short ASCII kebab-case slug suitable for both git branch names and folder names.
    public static func worktreeSlug(from prompt: String) -> String {
        let cleanedSource: Substring
        if let contextRange = prompt.range(of: "[Diff Context]:") {
            cleanedSource = prompt[..<contextRange.lowerBound]
        } else {
            cleanedSource = prompt[...]
        }

        let trimmed = cleanedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(trimmed.prefix(160))
        let latin = snippet.applyingTransform(.toLatin, reverse: false) ?? snippet
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        var bytes: [UInt8] = []
        bytes.reserveCapacity(40)
        var wordCount = 0
        var lastWasDash = true

        for b in folded.utf8 {
            let isLowerAlpha = (b >= 97 && b <= 122)
            let isUpperAlpha = (b >= 65 && b <= 90)
            let isDigit = (b >= 48 && b <= 57)

            if isLowerAlpha || isUpperAlpha || isDigit {
                let normalized = isUpperAlpha ? (b &+ 32) : b
                if lastWasDash {
                    if wordCount >= 5 || bytes.count >= 36 {
                        break
                    }
                    if !bytes.isEmpty {
                        bytes.append(45) // '-'
                    }
                    wordCount &+= 1
                    lastWasDash = false
                }
                if bytes.count >= 40 {
                    break
                }
                bytes.append(normalized)
            } else {
                if !bytes.isEmpty {
                    lastWasDash = true
                }
            }
        }

        while bytes.last == 45 {
            bytes.removeLast()
        }

        if let slug = String(bytes: bytes, encoding: .utf8), !slug.isEmpty {
            return slug
        }
        return "task-\(Int(Date().timeIntervalSince1970) % 100_000)"
    }

    private static func sanitizeFolderComponent(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.utf8.count)
        for b in trimmed.utf8 {
            // Replace path separators, whitespace, and colon with '-'
            if b == 47 || b == 92 || b == 32 || b == 9 || b == 10 || b == 13 || b == 58 {
                if bytes.last != 45 {
                    bytes.append(45)
                }
            } else {
                bytes.append(b)
            }
        }
        while bytes.first == 46 || bytes.first == 45 {
            bytes.removeFirst()
        }
        while bytes.last == 45 {
            bytes.removeLast()
        }
        let result = String(bytes: bytes, encoding: .utf8) ?? ""
        return result.isEmpty || result == "." || result == ".." ? fallback : result
    }

    // MARK: - Porcelain Parsers

    public static func parseWorktreesPorcelainZ(_ data: Data) -> [GitWorktree] {
        var result: [GitWorktree] = []

        var currentPath: String?
        var currentHead = ""
        var currentBranch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        func flushCurrent() {
            guard let path = currentPath, !path.isEmpty else { return }
            result.append(GitWorktree(
                path: path,
                head: currentHead,
                branch: currentBranch,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                lockReason: lockReason,
                isPrunable: isPrunable,
                prunableReason: prunableReason,
                isMain: result.isEmpty
            ))
            currentPath = nil
            currentHead = ""
            currentBranch = nil
            isBare = false
            isDetached = false
            isLocked = false
            lockReason = nil
            isPrunable = false
            prunableReason = nil
        }

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var start = 0
            let count = bytes.count

            func processToken(_ slice: UnsafeBufferPointer<UInt8>.SubSequence) {
                if slice.isEmpty {
                    flushCurrent()
                    return
                }
                guard let line = String(bytes: slice, encoding: .utf8) else { return }
                if line.hasPrefix("worktree ") {
                    flushCurrent()
                    currentPath = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    currentHead = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    if ref.hasPrefix("refs/heads/") {
                        currentBranch = String(ref.dropFirst("refs/heads/".count))
                    } else {
                        currentBranch = ref
                    }
                } else if line == "bare" {
                    isBare = true
                } else if line == "detached" {
                    isDetached = true
                } else if line == "locked" {
                    isLocked = true
                } else if line.hasPrefix("locked ") {
                    isLocked = true
                    lockReason = String(line.dropFirst("locked ".count))
                } else if line == "prunable" {
                    isPrunable = true
                } else if line.hasPrefix("prunable ") {
                    isPrunable = true
                    prunableReason = String(line.dropFirst("prunable ".count))
                }
            }

            for i in 0..<count {
                if bytes[i] == 0 {
                    processToken(bytes[start..<i])
                    start = i + 1
                }
            }
            if start < count {
                processToken(bytes[start..<count])
            }
            flushCurrent()
        }

        return result
    }

    public static func parseWorktreesPorcelainLines(_ data: Data) -> [GitWorktree] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [GitWorktree] = []

        var currentPath: String?
        var currentHead = ""
        var currentBranch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?

        func flushCurrent() {
            guard let path = currentPath, !path.isEmpty else { return }
            result.append(GitWorktree(
                path: path,
                head: currentHead,
                branch: currentBranch,
                isBare: isBare,
                isDetached: isDetached,
                isLocked: isLocked,
                lockReason: lockReason,
                isPrunable: isPrunable,
                prunableReason: prunableReason,
                isMain: result.isEmpty
            ))
            currentPath = nil
            currentHead = ""
            currentBranch = nil
            isBare = false
            isDetached = false
            isLocked = false
            lockReason = nil
            isPrunable = false
            prunableReason = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flushCurrent()
            } else if line.hasPrefix("worktree ") {
                flushCurrent()
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line == "locked" {
                isLocked = true
            } else if line.hasPrefix("locked ") {
                isLocked = true
                lockReason = String(line.dropFirst("locked ".count))
            } else if line == "prunable" {
                isPrunable = true
            } else if line.hasPrefix("prunable ") {
                isPrunable = true
                prunableReason = String(line.dropFirst("prunable ".count))
            }
        }
        flushCurrent()
        return result
    }
}
