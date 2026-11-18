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
    public var preTurnUntrackedBlobs: [String: String]?
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
        preTurnUntrackedBlobs: [String: String]? = nil,
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
        self.preTurnUntrackedBlobs = preTurnUntrackedBlobs
        self.rawDiffData = rawDiffData
        self.rawTextData = rawTextData
        self.contentMode = contentMode
        self.isReverted = isReverted
        self.createdFiles = createdFiles
        self.modifiedFiles = modifiedFiles
        self.deletedFiles = deletedFiles
    }

    private enum CodingKeys: String, CodingKey {
        case files, baseCommitHash, postTurnCommitHash, savedCreatedFiles, preTurnUntrackedBlobs, rawDiffData, rawTextData, contentMode, isReverted, createdFiles, modifiedFiles, deletedFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([AgentEditedFileItem].self, forKey: .files)
        baseCommitHash = try container.decodeIfPresent(String.self, forKey: .baseCommitHash)
        postTurnCommitHash = try container.decodeIfPresent(String.self, forKey: .postTurnCommitHash)
        savedCreatedFiles = try container.decodeIfPresent([String: String].self, forKey: .savedCreatedFiles)
        preTurnUntrackedBlobs = try container.decodeIfPresent([String: String].self, forKey: .preTurnUntrackedBlobs)
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
        try container.encodeIfPresent(preTurnUntrackedBlobs, forKey: .preTurnUntrackedBlobs)
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

public struct PreTurnGitSnapshot: Sendable, Equatable, Codable {
    public let baseCommitHash: String?
    public let untrackedFiles: Set<String>
    public let untrackedModTimes: [String: TimeInterval]
    public let untrackedBlobHashes: [String: String]
    public let isGitRepository: Bool

    public var stashCommitHash: String? { baseCommitHash }

    public init(
        stashCommitHash: String? = nil,
        baseCommitHash: String? = nil,
        untrackedFiles: Set<String> = [],
        untrackedModTimes: [String: TimeInterval] = [:],
        untrackedBlobHashes: [String: String] = [:],
        isGitRepository: Bool = true
    ) {
        self.baseCommitHash = baseCommitHash ?? stashCommitHash
        self.untrackedFiles = untrackedFiles
        self.untrackedModTimes = untrackedModTimes
        self.untrackedBlobHashes = untrackedBlobHashes
        self.isGitRepository = isGitRepository
    }
}

public enum AgentGitChangesDetector {
    /// Captures a fast (1-3ms) shadow snapshot of the current working tree using `git stash create`.
    /// Does not modify working files, index, or git log.
    public static func capturePreTurnSnapshot(workingDirectory: String) -> PreTurnGitSnapshot {
        guard !workingDirectory.isEmpty, FileManager.default.fileExists(atPath: workingDirectory) else {
            return PreTurnGitSnapshot(isGitRepository: false)
        }

        // Fast single-process probe: verifies git repo, retrieves HEAD OID, detects tracked dirtiness,
        // and enumerates all non-ignored untracked files at once.
        guard let statusData = runGitData(arguments: ["-C", workingDirectory, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]) else {
            return PreTurnGitSnapshot(baseCommitHash: nil, isGitRepository: false)
        }

        let parsedStatus = parsePorcelainV2Status(statusData)
        let headOid = parsedStatus.headOid
        let hasTrackedDirty = parsedStatus.hasTrackedDirty
        let untrackedList = parsedStatus.untrackedFiles
        let untracked = Set(untrackedList)
        var modTimes: [String: TimeInterval] = [:]
        modTimes.reserveCapacity(untrackedList.count)
        var blobHashes: [String: String] = [:]

        for trimmed in untrackedList {
            let fullPath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(trimmed).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let modDate = attrs[.modificationDate] as? Date {
                modTimes[trimmed] = modDate.timeIntervalSince1970
            }
        }

        var baseRef: String? = nil
        if hasTrackedDirty {
            if let stashOutput = runGit(arguments: ["-C", workingDirectory, "stash", "create"]) {
                baseRef = !stashOutput.isEmpty ? stashOutput : (headOid ?? "HEAD")
            } else {
                // git stash create failed. Do NOT guess "HEAD" to avoid attributing existing diffs.
                baseRef = nil
            }
        } else {
            baseRef = headOid ?? "HEAD"
        }

        if !untrackedList.isEmpty {
            var hashArgs = ["-C", workingDirectory, "hash-object", "-w", "--"]
            hashArgs.append(contentsOf: untrackedList)
            if let shasOutput = runGit(arguments: hashArgs) {
                let shas = shasOutput.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if shas.count == untrackedList.count {
                    for (idx, sha) in shas.enumerated() {
                        blobHashes[untrackedList[idx]] = sha
                    }
                }
            }
        }

        return PreTurnGitSnapshot(
            baseCommitHash: baseRef,
            untrackedFiles: untracked,
            untrackedModTimes: modTimes,
            untrackedBlobHashes: blobHashes,
            isGitRepository: true
        )
    }

    /// Enumerates all current non-ignored untracked file paths relative to `workingDirectory`.
    public static func listUntrackedFiles(workingDirectory: String) -> [String]? {
        guard let statusData = runGitData(arguments: ["-C", workingDirectory, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]) else {
            return nil
        }
        return parsePorcelainV2Status(statusData).untrackedFiles
    }

    private static func parsePorcelainV2Status(_ statusData: Data) -> (headOid: String?, hasTrackedDirty: Bool, untrackedFiles: [String]) {
        var headOid: String? = nil
        var hasTrackedDirty = false
        var untrackedList: [String] = []

        let statusRecords = statusData.split(separator: 0, omittingEmptySubsequences: true)
        var recordIdx = 0
        while recordIdx < statusRecords.count {
            let recordBytes = statusRecords[recordIdx]
            recordIdx += 1
            guard let record = String(data: recordBytes, encoding: .utf8) else { continue }
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst("# branch.oid ".count))
                if !oid.isEmpty, oid != "(initial)" {
                    headOid = oid
                }
            } else if record.hasPrefix("2 ") {
                hasTrackedDirty = true
                // Rename/copy v2 -z records are followed by an extra NUL-terminated origPath token.
                if recordIdx < statusRecords.count {
                    recordIdx += 1
                }
            } else if record.hasPrefix("1 ") || record.hasPrefix("u ") {
                hasTrackedDirty = true
            } else if record.hasPrefix("? ") {
                let trimmed = String(record.dropFirst(2))
                if !trimmed.isEmpty {
                    untrackedList.append(trimmed)
                }
            }
        }
        return (headOid: headOid, hasTrackedDirty: hasTrackedDirty, untrackedFiles: untrackedList)
    }

    /// Asynchronously captures a fast shadow snapshot on a detached background task so the main thread is never blocked.
    public static func capturePreTurnSnapshotAsync(workingDirectory: String) async -> PreTurnGitSnapshot {
        await Task.detached(priority: .userInitiated) {
            capturePreTurnSnapshot(workingDirectory: workingDirectory)
        }.value
    }

    /// Asynchronously computes the isolated diff and summary on a detached background task so the main thread is never blocked.
    public static func computeTurnSummaryAsync(
        workingDirectory: String,
        snapshot: PreTurnGitSnapshot?
    ) async -> (summary: AgentEditedFilesSummary?, rawDiffData: Data?) {
        await Task.detached(priority: .userInitiated) {
            computeTurnSummary(workingDirectory: workingDirectory, snapshot: snapshot)
        }.value
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

        // 1. Get raw status and numstat for tracked files against base snapshot ref in a single git invocation
        var numstatItems: [String: (adds: Int, dels: Int)] = [:]
        var rawEntries: [(statusLetter: Substring, path: String)] = []
        if let baseRef = snapshot.baseCommitHash,
           let combinedDiff = runGit(arguments: ["-C", workingDirectory, "diff", "--raw", "--numstat", baseRef]) {
            for line in combinedDiff.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(":") {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard !parts.isEmpty else { continue }
                    let statusField = parts[0].split(separator: " ").last ?? ""
                    let statusLetter = statusField.prefix(1)
                    let pathSubstring: Substring = if (statusLetter == "R" || statusLetter == "C") && parts.count >= 3 {
                        parts[2]
                    } else if parts.count >= 2 {
                        parts[1]
                    } else {
                        ""
                    }
                    let path = pathSubstring.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty {
                        rawEntries.append((statusLetter: statusLetter, path: path))
                    }
                } else {
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    if parts.count >= 3 {
                        let adds = Int(parts[0]) ?? 0
                        let dels = Int(parts[1]) ?? 0
                        let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !path.isEmpty {
                            numstatItems[path] = (adds, dels)
                        }
                    }
                }
            }

            for entry in rawEntries {
                let statusLetter = entry.statusLetter
                let path = entry.path

                // If git diff reports this file as Added ("A"), check if it was already
                // present as an untracked file before this turn started.
                // Because `git stash create` does not capture untracked files, any pre-existing
                // untracked file that was merely staged/committed during this turn will appear
                // in `git diff baseRef` as Added ("A").
                if statusLetter == "A" && snapshot.untrackedFiles.contains(path) {
                    let fullPath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path
                    let currentMtime = (try? FileManager.default.attributesOfItem(atPath: fullPath))?[.modificationDate] as? Date
                    let wasModified = (currentMtime?.timeIntervalSince1970 ?? 0) > (snapshot.untrackedModTimes[path] ?? 0) + 0.5
                    if wasModified {
                        modifiedList.append(path)
                        let (adds, dels) = numstatItems[path] ?? (0, 0)
                        items.append(AgentEditedFileItem(path: path, additions: adds, deletions: dels))
                    }
                    // If not modified, it was just staged/committed without changes during this turn — ignore!
                    continue
                }

                let (adds, dels) = numstatItems[path] ?? (0, 0)
                if statusLetter == "A" {
                    createdList.append(path)
                    items.append(AgentEditedFileItem(path: path, additions: adds, deletions: dels))
                } else if statusLetter == "D" {
                    deletedList.append(path)
                    items.append(AgentEditedFileItem(path: path, additions: adds, deletions: dels))
                } else {
                    modifiedList.append(path)
                    items.append(AgentEditedFileItem(path: path, additions: adds, deletions: dels))
                }
            }
        }

        // 2. Untracked files created, modified, or deleted during THIS turn
        var preTurnBlobsForSummary: [String: String] = [:]
        var cachedUntrackedDiffs: [String: Data] = [:]
        if snapshot.isGitRepository,
           let untrackedOutput = runGit(arguments: ["-C", workingDirectory, "ls-files", "--others", "--exclude-standard"]) {
            let existingTrackedPaths = Set(items.map(\.path))
            var currentUntrackedPaths: Set<String> = []
            for path in untrackedOutput.components(separatedBy: "\n") {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                currentUntrackedPaths.insert(trimmed)
                guard !existingTrackedPaths.contains(trimmed) else { continue }

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
                    var adds = 0
                    var dels = 0
                    if let oldBlobSha = snapshot.untrackedBlobHashes[trimmed],
                       let combined = runGitData(arguments: ["-C", workingDirectory, "diff", "--numstat", "-p", "-U3", oldBlobSha, "--", trimmed]) {
                        preTurnBlobsForSummary[trimmed] = oldBlobSha
                        if let parsed = splitNumstatAndPatch(combined) {
                            adds = parsed.adds
                            dels = parsed.dels
                            cachedUntrackedDiffs[trimmed] = parsed.patchData
                        }
                    } else if let contents = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        adds = contents.components(separatedBy: "\n").count
                    }
                    items.append(AgentEditedFileItem(path: trimmed, additions: adds, deletions: dels))
                }
            }

            // 2b. Pre-existing untracked files deleted during THIS turn
            for path in snapshot.untrackedFiles.sorted() {
                guard !existingTrackedPaths.contains(path),
                      !currentUntrackedPaths.contains(path) else { continue }
                let fullPath = URL(fileURLWithPath: workingDirectory).appendingPathComponent(path).path
                guard !FileManager.default.fileExists(atPath: fullPath) else { continue }

                deletedList.append(path)
                var dels = 0
                if let oldBlobSha = snapshot.untrackedBlobHashes[path] {
                    preTurnBlobsForSummary[path] = oldBlobSha
                    if let blobData = runGitData(arguments: ["-C", workingDirectory, "cat-file", "blob", oldBlobSha], allowEmpty: true) {
                        let deletedDiff = makeDeletedFileDiff(path: path, blobData: blobData)
                        dels = deletedDiff.deletions
                        cachedUntrackedDiffs[path] = deletedDiff.patchData
                    }
                }
                items.append(AgentEditedFileItem(path: path, additions: 0, deletions: dels))
            }
        }

        guard !items.isEmpty else { return (nil, nil) }

        // 3. Capture raw unified diff data for fast MultiBuffer rendering
        var rawData: Data? = nil
        var diffChunks: [Data] = []

        if let baseRef = snapshot.baseCommitHash {
            let trackedFilterPaths = Set(items.map(\.path)).subtracting(snapshot.untrackedFiles)
            if !trackedFilterPaths.isEmpty {
                var diffArgs = ["-C", workingDirectory, "diff", "-U3", baseRef, "--"]
                diffArgs.append(contentsOf: trackedFilterPaths.sorted())
                if let diffData = runGitData(arguments: diffArgs) {
                    diffChunks.append(diffData)
                }
            }
        }

        // Include diffs for untracked files (reusing precomputed diffs from step 2)
        for item in items {
            if snapshot.untrackedFiles.contains(item.path) {
                if let cached = cachedUntrackedDiffs[item.path] {
                    diffChunks.append(cached)
                } else if let oldBlobSha = snapshot.untrackedBlobHashes[item.path],
                          !deletedList.contains(item.path),
                          let fileDiffData = runGitData(arguments: ["-C", workingDirectory, "diff", "-U3", oldBlobSha, "--", item.path]) {
                    diffChunks.append(fileDiffData)
                }
            } else if createdList.contains(item.path) {
                if let fileDiffData = runGitData(arguments: ["-C", workingDirectory, "diff", "-U3", "--no-index", "/dev/null", item.path]) {
                    diffChunks.append(fileDiffData)
                }
            }
        }

        if !diffChunks.isEmpty {
            var combined = Data()
            for chunk in diffChunks {
                combined.append(chunk)
                if chunk.last != 0x0A {
                    combined.append(0x0A)
                }
            }
            rawData = combined
        }

        let summary = AgentEditedFilesSummary(
            files: items,
            baseCommitHash: snapshot.baseCommitHash,
            preTurnUntrackedBlobs: preTurnBlobsForSummary.isEmpty ? nil : preTurnBlobsForSummary,
            rawDiffData: rawData,
            isReverted: false,
            createdFiles: createdList,
            modifiedFiles: modifiedList,
            deletedFiles: deletedList
        )
        return (summary, rawData)
    }

    /// Fetches the raw diff against base commit (or between base and target commits) for specific filtered paths.
    public static func fetchTurnDiffData(
        workingDirectory: String,
        baseCommit: String,
        targetCommit: String? = nil,
        pathFilter: Set<String>? = nil
    ) -> Data? {
        var args = ["-C", workingDirectory, "diff", "-U3", baseCommit]
        if let targetCommit, !targetCommit.isEmpty {
            args.append(targetCommit)
        }
        if let filter = pathFilter, !filter.isEmpty {
            args.append("--")
            args.append(contentsOf: filter.sorted())
        }
        return runGitData(arguments: args)
    }

    private static let diffGitMarker = Data("\ndiff --git ".utf8)

    private static func makeDeletedFileDiff(path: String, blobData: Data) -> (deletions: Int, patchData: Data) {
        var patch = "diff --git a/\(path) b/\(path)\ndeleted file mode 100644\n"
        if blobData.isEmpty {
            patch += "--- a/\(path)\n+++ /dev/null\n"
            return (0, Data(patch.utf8))
        }
        if blobData.contains(0) || String(data: blobData, encoding: .utf8) == nil {
            patch += "Binary files a/\(path) and /dev/null differ\n"
            return (0, Data(patch.utf8))
        }
        let text = String(decoding: blobData, as: UTF8.self)
        let hasTrailingNewline = text.hasSuffix("\n")
        let body = hasTrailingNewline ? String(text.dropLast()) : text
        let lines = body.components(separatedBy: "\n")
        patch += "--- a/\(path)\n+++ /dev/null\n@@ -1,\(lines.count) +0,0 @@\n"
        for line in lines {
            patch += "-\(line)\n"
        }
        if !hasTrailingNewline {
            patch += "\\ No newline at end of file\n"
        }
        return (lines.count, Data(patch.utf8))
    }

    private static func splitNumstatAndPatch(_ data: Data) -> (adds: Int, dels: Int, patchData: Data)? {
        guard let markerRange = data.range(of: diffGitMarker) else { return nil }
        let headerData = data[data.startIndex..<markerRange.lowerBound]
        var adds = 0
        var dels = 0
        if let headerText = String(data: headerData, encoding: .utf8) {
            let parts = headerText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            if parts.count >= 2 {
                adds = Int(parts[0]) ?? 0
                dels = Int(parts[1]) ?? 0
            }
        }
        // Skip the leading '\n' so patchData starts directly at "diff --git ".
        let patchStart = data.index(after: markerRange.lowerBound)
        return (adds, dels, Data(data[patchStart..<data.endIndex]))
    }

    private static func runGit(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var fullArgs = ["-c", "user.name=AnyDiff", "-c", "user.email=anydiff@local"]
        fullArgs.append(contentsOf: arguments)
        process.arguments = fullArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return nil
        }
    }

    private static func runGitData(arguments: [String], allowEmpty: Bool = false) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var fullArgs = ["-c", "user.name=AnyDiff", "-c", "user.email=anydiff@local"]
        fullArgs.append(contentsOf: arguments)
        process.arguments = fullArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let allowedStatuses: Set<Int32> = arguments.contains("--no-index") ? [0, 1] : [0]
            guard allowedStatuses.contains(process.terminationStatus), (allowEmpty || !data.isEmpty) else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
