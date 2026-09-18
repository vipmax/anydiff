import Foundation

/// High-performance Git log reader and parser using ASCII delimiter streaming.
public final class GitLogReader: Sendable {
    public static let shared = GitLogReader()

    public static let fieldSeparator: UInt8 = 0x1f // Unit Separator
    public static let recordSeparator: UInt8 = 0x1e // Record Separator

    public init() {}

    /// Reads Git commits with topology and metadata from a repository directory.
    public func readCommits(
        directory: String,
        limit: Int = 150,
        skip: Int = 0,
        branch: String? = nil,
        all: Bool = false
    ) -> [GitCommit] {
        let refsByHash = fetchRefsByCommitHash(at: directory)

        var args = ["-C", directory, "log", "--topo-order"]
        if all {
            args.append("--all")
        } else if let branch = branch, !branch.isEmpty {
            args.append(branch)
        }

        args.append(contentsOf: [
            "-n", String(limit),
            "--skip", String(skip),
            "--shortstat",
            "--format=%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1f"
        ])

        guard let data = runGitData(arguments: args) else {
            return []
        }

        return parseLogData(data, refsByHash: refsByHash)
    }

    /// Reads a single Git commit by hash with its metadata and diff stats.
    public func readCommit(directory: String, hash: String) -> GitCommit? {
        guard !directory.isEmpty, !hash.isEmpty else { return nil }
        let refsByHash = fetchRefsByCommitHash(at: directory)
        let args = [
            "-C", directory, "log", "-n", "1",
            "--shortstat",
            "--format=%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%b%x1f",
            hash
        ]
        guard let data = runGitData(arguments: args) else { return nil }
        return parseLogData(data, refsByHash: refsByHash).first
    }

    /// Reads the list of files changed in a commit with additions and deletions stats.
    public func readCommitFiles(directory: String, hash: String) -> [CommitFileChange] {
        guard !directory.isEmpty, !hash.isEmpty else { return [] }
        let args = [
            "-C", directory,
            "diff-tree", "--no-commit-id", "-r", "--numstat", "--root", "-m", "--first-parent",
            hash
        ]
        guard let data = runGitData(arguments: args),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var results: [CommitFileChange] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let addsStr = parts[0]
            let delsStr = parts[1]
            let filePath = String(parts[2])

            let isBinary = (addsStr == "-" && delsStr == "-")
            let adds = Int(addsStr) ?? 0
            let dels = Int(delsStr) ?? 0

            results.append(CommitFileChange(
                path: filePath,
                additions: adds,
                deletions: dels,
                isBinary: isBinary
            ))
        }
        return results
    }

    /// Parses the raw binary log output into structured `GitCommit`s.
    public func parseLogData(_ data: Data, refsByHash: [String: [GitRef]] = [:]) -> [GitCommit] {
        guard !data.isEmpty else { return [] }

        var commits: [GitCommit] = []
        commits.reserveCapacity(min(128, data.count / 256))

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let totalCount = buffer.count

            var recordStart = 0

            for i in 0..<totalCount {
                if baseAddress[i] == Self.recordSeparator {
                    if i > recordStart {
                        let recordBytes = UnsafeBufferPointer(start: baseAddress + recordStart, count: i - recordStart)
                        if let commit = parseCommitRecord(recordBytes, refsByHash: refsByHash) {
                            commits.append(commit)
                        }
                    }
                    recordStart = i + 1
                }
            }

            // Handle possible trailing record without separator
            if recordStart < totalCount {
                let recordBytes = UnsafeBufferPointer(start: baseAddress + recordStart, count: totalCount - recordStart)
                if let commit = parseCommitRecord(recordBytes, refsByHash: refsByHash) {
                    commits.append(commit)
                }
            }
        }

        return commits
    }

    private func parseShortstat(_ text: Substring) -> (files: Int, adds: Int, dels: Int) {
        var files = 0
        var adds = 0
        var dels = 0

        let components = text.split(separator: ",")
        for part in components {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("file") {
                if let numStr = trimmed.split(separator: " ").first, let num = Int(numStr) {
                    files = num
                }
            } else if trimmed.contains("insertion") {
                if let numStr = trimmed.split(separator: " ").first, let num = Int(numStr) {
                    adds = num
                }
            } else if trimmed.contains("deletion") {
                if let numStr = trimmed.split(separator: " ").first, let num = Int(numStr) {
                    dels = num
                }
            }
        }
        return (files, adds, dels)
    }

    private func parseCommitRecord(_ buffer: UnsafeBufferPointer<UInt8>, refsByHash: [String: [GitRef]]) -> GitCommit? {
        guard !buffer.isEmpty else { return nil }

        var fields: [Substring] = []
        fields.reserveCapacity(9)

        var fieldStart = 0
        for i in 0..<buffer.count {
            if buffer[i] == Self.fieldSeparator {
                let sub = decodeSubstring(buffer: buffer, from: fieldStart, to: i)
                fields.append(sub)
                fieldStart = i + 1
            }
        }

        if fieldStart <= buffer.count {
            let sub = decodeSubstring(buffer: buffer, from: fieldStart, to: buffer.count)
            fields.append(sub)
        }

        // Expected fields:
        // 0: hash, 1: shortHash, 2: parentHashes, 3: authorName, 4: authorEmail, 5: timestamp, 6: summary, 7: body, 8: shortstat
        guard fields.count >= 7 else { return nil }

        let hash = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return nil }

        let shortHash = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentsString = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parents = parentsString.isEmpty ? [] : parentsString.split(separator: " ").map(String.init)

        let authorName = String(fields[3])
        let authorEmail = String(fields[4])

        let timestampString = String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = TimeInterval(timestampString) ?? 0
        let date = Date(timeIntervalSince1970: timestamp)

        let summary = String(fields[6])
        let body = fields.count > 7 ? String(fields[7]).trimmingCharacters(in: .newlines) : ""

        let attachedRefs = refsByHash[hash] ?? []

        let stats: (files: Int, adds: Int, dels: Int)
        if fields.count > 8 {
            stats = parseShortstat(fields[8])
        } else {
            stats = (0, 0, 0)
        }

        return GitCommit(
            hash: hash,
            shortHash: shortHash.isEmpty ? String(hash.prefix(7)) : shortHash,
            parentHashes: parents,
            authorName: authorName,
            authorEmail: authorEmail,
            date: date,
            summary: summary.isEmpty ? "(no commit message)" : summary,
            body: body,
            refs: attachedRefs,
            filesChanged: stats.files,
            additions: stats.adds,
            deletions: stats.dels
        )
    }

    private func decodeSubstring(buffer: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Substring {
        guard start < end, let base = buffer.baseAddress else { return "" }
        let rawSlice = UnsafeBufferPointer(start: base + start, count: end - start)
        return Substring(String(decoding: rawSlice, as: UTF8.self))
    }

    /// Fetches all branch and tag references grouped by the commit hash they point to.
    public func fetchRefsByCommitHash(at directory: String) -> [String: [GitRef]] {
        var result: [String: [GitRef]] = [:]

        // 1. Fetch current HEAD symbol
        let currentHeadRef = runGit(arguments: ["-C", directory, "symbolic-ref", "--short", "HEAD"])

        // 2. Fetch refs via for-each-ref
        let args = [
            "-C", directory,
            "for-each-ref",
            "--format=%(objectname)%x1f%(refname:short)%x1f%(refname)",
            "refs/heads/", "refs/remotes/", "refs/tags/"
        ]

        guard let output = runGit(arguments: args), !output.isEmpty else {
            return result
        }

        let lines = output.split(whereSeparator: \.isNewline)
        for line in lines {
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let hash = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let shortName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fullName = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !hash.isEmpty, !shortName.isEmpty else { continue }

            let type: GitRefType
            if fullName.hasPrefix("refs/tags/") {
                type = .tag
            } else if fullName.hasPrefix("refs/remotes/") {
                type = .remoteBranch
            } else if shortName == currentHeadRef {
                type = .head
            } else {
                type = .localBranch
            }

            let ref = GitRef(name: fullName, shortName: shortName, type: type)
            result[hash, default: []].append(ref)
        }

        return result
    }

    private func runGit(arguments: [String]) -> String? {
        if let data = runGitData(arguments: arguments) {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func runGitData(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}
