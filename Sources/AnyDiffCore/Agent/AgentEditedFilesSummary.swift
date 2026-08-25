import Foundation

public struct AgentEditedFileItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let additions: Int
    public let deletions: Int

    public init(path: String, additions: Int, deletions: Int) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
    }

    public var directory: String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        return dir.isEmpty ? "" : "\(dir)/"
    }

    public var filename: String {
        (path as NSString).lastPathComponent
    }
}

public struct AgentEditedFilesSummary: Codable, Sendable, Equatable {
    public let files: [AgentEditedFileItem]
    public let baseCommitHash: String?
    public var postTurnCommitHash: String?
    public var savedCreatedFiles: [String: String]?
    public let rawDiffData: Data?
    public let rawTextData: Data?
    public let contentMode: ContentMode
    public var isReverted: Bool
    public let createdFiles: [String]
    public let modifiedFiles: [String]
    public let deletedFiles: [String]

    public init(
        files: [AgentEditedFileItem],
        baseCommitHash: String? = nil,
        postTurnCommitHash: String? = nil,
        savedCreatedFiles: [String: String]? = nil,
        rawDiffData: Data? = nil,
        rawTextData: Data? = nil,
        contentMode: ContentMode = .diff,
        isReverted: Bool = false,
        createdFiles: [String] = [],
        modifiedFiles: [String] = [],
        deletedFiles: [String] = []
    ) {
        self.files = files
        self.baseCommitHash = baseCommitHash
        self.postTurnCommitHash = postTurnCommitHash
        self.savedCreatedFiles = savedCreatedFiles
        self.rawDiffData = rawDiffData
        self.rawTextData = rawTextData
        self.contentMode = contentMode
        self.isReverted = isReverted
        self.createdFiles = createdFiles
        self.modifiedFiles = modifiedFiles
        self.deletedFiles = deletedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case files, baseCommitHash, postTurnCommitHash, savedCreatedFiles, rawDiffData, rawTextData, contentMode, isReverted, createdFiles, modifiedFiles, deletedFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([AgentEditedFileItem].self, forKey: .files)
        baseCommitHash = try container.decodeIfPresent(String.self, forKey: .baseCommitHash)
        postTurnCommitHash = try container.decodeIfPresent(String.self, forKey: .postTurnCommitHash)
        savedCreatedFiles = try container.decodeIfPresent([String: String].self, forKey: .savedCreatedFiles)
        rawDiffData = try container.decodeIfPresent(Data.self, forKey: .rawDiffData)
        rawTextData = try container.decodeIfPresent(Data.self, forKey: .rawTextData)
        contentMode = try container.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? .diff
        isReverted = try container.decodeIfPresent(Bool.self, forKey: .isReverted) ?? false
        createdFiles = try container.decodeIfPresent([String].self, forKey: .createdFiles) ?? []
        modifiedFiles = try container.decodeIfPresent([String].self, forKey: .modifiedFiles) ?? []
        deletedFiles = try container.decodeIfPresent([String].self, forKey: .deletedFiles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(files, forKey: .files)
        try container.encodeIfPresent(baseCommitHash, forKey: .baseCommitHash)
        try container.encodeIfPresent(postTurnCommitHash, forKey: .postTurnCommitHash)
        try container.encodeIfPresent(savedCreatedFiles, forKey: .savedCreatedFiles)
        try container.encodeIfPresent(rawDiffData, forKey: .rawDiffData)
        try container.encodeIfPresent(rawTextData, forKey: .rawTextData)
        try container.encode(contentMode, forKey: .contentMode)
        try container.encode(isReverted, forKey: .isReverted)
        try container.encode(createdFiles, forKey: .createdFiles)
        try container.encode(modifiedFiles, forKey: .modifiedFiles)
        try container.encode(deletedFiles, forKey: .deletedFiles)
    }

    public var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    public var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    public var filePaths: [String] {
        files.map(\.path)
    }

    public var displayTitle: String {
        let count = files.count
        if isReverted {
            return count == 1 ? "1 file (Reverted)" : "\(count) files (Reverted)"
        }
        return count == 1 ? "Edited 1 file" : "Edited \(count) files"
    }
}

public struct PreTurnGitSnapshot: Sendable {
    public let stashCommitHash: String?
    public let untrackedFiles: Set<String>
    public let untrackedModTimes: [String: TimeInterval]

    public init(
        stashCommitHash: String? = nil,
        untrackedFiles: Set<String> = [],
        untrackedModTimes: [String: TimeInterval] = [:]
    ) {
        self.stashCommitHash = stashCommitHash
        self.untrackedFiles = untrackedFiles
        self.untrackedModTimes = untrackedModTimes
    }
}

public enum AgentGitChangesDetector {
    /// Captures a fast (1-3ms) shadow snapshot of the current working tree using `git stash create`.
    /// Does not modify working files, index, or git log.
    public static func capturePreTurnSnapshot(workingDirectory: String) -> PreTurnGitSnapshot {
        guard !workingDirectory.isEmpty, FileManager.default.fileExists(atPath: workingDirectory) else {
            return PreTurnGitSnapshot()
        }

        let stashCommit = runGit(arguments: ["-C", workingDirectory, "stash", "create"])
        var untracked = Set<String>()
        var modTimes: [String: TimeInterval] = [:]

        if let output = runGit(arguments: ["-C", workingDirectory, "ls-files", "--others", "--exclude-standard"]) {
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                untracked.insert(trimmed)
                let fullPath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(trimmed).path
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    modTimes[trimmed] = modDate.timeIntervalSince1970
                }
            }
        }

        let validHash = (stashCommit != nil && !stashCommit!.isEmpty) ? stashCommit : nil
        return PreTurnGitSnapshot(
            stashCommitHash: validHash,
            untrackedFiles: untracked,
            untrackedModTimes: modTimes
        )
    }

    /// Computes the isolated diff and summary representing strictly changes made during this turn.
    public static func computeTurnSummary(
        workingDirectory: String,
        snapshot: PreTurnGitSnapshot?
    ) -> (summary: AgentEditedFilesSummary?, rawDiffData: Data?) {
        guard !workingDirectory.isEmpty, FileManager.default.fileExists(atPath: workingDirectory) else {
            return (nil, nil)
        }

        guard let snapshot = snapshot else {
            return (nil, nil)
        }

        var items: [AgentEditedFileItem] = []
        var createdList: [String] = []
        var modifiedList: [String] = []
        var deletedList: [String] = []

        let baseRef = snapshot.stashCommitHash ?? "HEAD"

        // 1. Get numstat and status for tracked files against base snapshot
        if let numstat = runGit(arguments: ["-C", workingDirectory, "diff", "--numstat", baseRef]) {
            for line in numstat.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 3 {
                    let adds = Int(parts[0]) ?? 0
                    let dels = Int(parts[1]) ?? 0
                    let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        items.append(AgentEditedFileItem(path: path, additions: adds, deletions: dels))
                    }
                }
            }
        }

        if let nameStatus = runGit(arguments: ["-C", workingDirectory, "diff", "--name-status", baseRef]) {
            for line in nameStatus.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "\t")
                guard !parts.isEmpty else { continue }
                let statusLetter = parts[0].prefix(1)
                if statusLetter == "A" && parts.count >= 2 {
                    createdList.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                } else if statusLetter == "D" && parts.count >= 2 {
                    deletedList.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                } else if parts.count >= 2 {
                    modifiedList.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        // 2. Untracked files created or modified during THIS turn
        if let untrackedOutput = runGit(arguments: ["-C", workingDirectory, "ls-files", "--others", "--exclude-standard"]) {
            let existingTrackedPaths = Set(items.map(\.path))
            for path in untrackedOutput.components(separatedBy: "\n") {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !existingTrackedPaths.contains(trimmed) else { continue }

                let fullPath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(trimmed).path
                let currentMtime = (try? FileManager.default.attributesOfItem(atPath: fullPath))?[.modificationDate] as? Date

                let isNewFile = !snapshot.untrackedFiles.contains(trimmed)
                let isModified = snapshot.untrackedFiles.contains(trimmed) &&
                    (currentMtime?.timeIntervalSince1970 ?? 0) > (snapshot.untrackedModTimes[trimmed] ?? 0) + 0.5

                if isNewFile {
                    createdList.append(trimmed)
                    if let contents = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        let lineCount = contents.components(separatedBy: "\n").count
                        items.append(AgentEditedFileItem(path: trimmed, additions: lineCount, deletions: 0))
                    }
                } else if isModified {
                    modifiedList.append(trimmed)
                    if let contents = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        let lineCount = contents.components(separatedBy: "\n").count
                        items.append(AgentEditedFileItem(path: trimmed, additions: lineCount, deletions: 0))
                    }
                }
            }
        }

        guard !items.isEmpty else { return (nil, nil) }

        // 3. Capture raw unified diff data for fast MultiBuffer rendering
        var rawData: Data? = nil
        if let diffData = runGitData(arguments: ["-C", workingDirectory, "diff", "-U3", baseRef]) {
            rawData = diffData
        }

        let summary = AgentEditedFilesSummary(
            files: items,
            baseCommitHash: snapshot.stashCommitHash,
            rawDiffData: rawData,
            isReverted: false,
            createdFiles: createdList,
            modifiedFiles: modifiedList,
            deletedFiles: deletedList
        )
        return (summary, rawData)
    }

    /// Fetches the raw diff against base commit for specific filtered paths.
    public static func fetchTurnDiffData(
        workingDirectory: String,
        baseCommit: String,
        pathFilter: Set<String>? = nil
    ) -> Data? {
        var args = ["-C", workingDirectory, "diff", "-U3", baseCommit]
        if let filter = pathFilter, !filter.isEmpty {
            args.append("--")
            args.append(contentsOf: filter.sorted())
        }
        return runGitData(arguments: args)
    }

    private static func runGit(arguments: [String]) -> String? {
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
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func runGitData(arguments: [String]) -> Data? {
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
            guard process.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
