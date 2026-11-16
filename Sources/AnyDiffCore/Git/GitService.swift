import Foundation

/// Aggregate added/deleted line counts for a diff.
public struct GitDiffStats: Equatable, Sendable {
    public let additions: Int
    public let deletions: Int

    public static let zero = GitDiffStats(additions: 0, deletions: 0)

    public var hasChanges: Bool {
        additions > 0 || deletions > 0
    }

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }
}

/// Service for executing git commands and reading repository state.
public final class GitService: Sendable {
    public static let shared = GitService()

    public init() {}

    public func run(arguments: [String]) -> String? {
        if let data = runData(arguments: arguments) {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public func runData(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            exitSemaphore.wait()
            process.terminationHandler = nil
            return data.isEmpty ? nil : data
        } catch {
            process.terminationHandler = nil
            return nil
        }
    }

    public func runWithStatus(arguments: [String]) -> (exitCode: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            exitSemaphore.wait()
            process.terminationHandler = nil
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, outData, errText)
        } catch {
            process.terminationHandler = nil
            return (-1, Data(), error.localizedDescription)
        }
    }

    public func isRepository(at path: String) -> Bool {
        run(arguments: ["-C", path, "rev-parse", "--is-inside-work-tree"]) == "true"
    }

    public func currentBranch(at path: String) -> String {
        run(arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
    }

    public func branches(at path: String) -> (local: [String], remote: [String]) {
        let localOut = run(arguments: ["-C", path, "branch", "--format=%(refname:short)"]) ?? ""
        let local = localOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let remoteOut = run(arguments: ["-C", path, "branch", "-r", "--format=%(refname:short)"]) ?? ""
        let remote = remoteOut.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.contains("HEAD") }

        return (local, remote)
    }

    public func diffFiles(
        at path: String,
        target: ComparisonTarget = .workingTree,
        pathFilter: Set<String>? = nil
    ) -> (files: [FileDiff], data: Data?) {
        let argumentSets: [[String]]
        switch target {
        case .workingTree:
            argumentSets = [
                ["-C", path, "diff", "HEAD"],
                ["-C", path, "diff"],
                ["-C", path, "diff", "--staged"]
            ]
        case .baseBranch(let base):
            argumentSets = [
                ["-C", path, "diff", "\(base)..."],
                ["-C", path, "diff", "\(base)..HEAD"]
            ]
        case .directBranch(let branch):
            argumentSets = [
                ["-C", path, "diff", branch]
            ]
        case .commit(let hash, _):
            argumentSets = [
                ["-C", path, "show", "--format=", "--patch", "-m", "--first-parent", hash]
            ]
        case .remote:
            return (files: [], data: nil)
        }

        var allFiles: [FileDiff] = []
        var rawData: Data? = nil
        for baseArgs in argumentSets {
            var args = baseArgs
            if let pathFilter, !pathFilter.isEmpty {
                args += ["--"] + pathFilter.sorted()
            }
            if let data = runData(arguments: args) {
                let files = GitDiffParser.shared.parseZeroCopy(data: data)
                if !files.isEmpty {
                    allFiles = files
                    rawData = data
                    break
                }
            }
        }
        if case .workingTree = target {
            let untracked = untrackedFiles(at: path, pathFilter: pathFilter)
            allFiles.append(contentsOf: untracked)
            allFiles = filterIgnoredFiles(allFiles, at: path)
        }
        return (files: allFiles, data: rawData)
    }

    /// Incrementally streams `FileDiff`s in real time as `git` outputs diff lines
    public func streamDiffFiles(
        at path: String,
        target: ComparisonTarget = .workingTree,
        pathFilter: Set<String>? = nil
    ) -> AsyncThrowingStream<FileDiff, Error> {
        let argumentSets: [[String]]
        switch target {
        case .workingTree:
            argumentSets = [
                ["-C", path, "diff", "HEAD"],
                ["-C", path, "diff"],
                ["-C", path, "diff", "--staged"]
            ]
        case .baseBranch(let base):
            argumentSets = [
                ["-C", path, "diff", "\(base)..."],
                ["-C", path, "diff", "\(base)..HEAD"]
            ]
        case .directBranch(let branch):
            argumentSets = [
                ["-C", path, "diff", branch]
            ]
        case .commit(let hash, _):
            argumentSets = [
                ["-C", path, "show", "--format=", "--patch", "-m", "--first-parent", hash]
            ]
        case .remote:
            return AsyncThrowingStream { $0.finish() }
        }

        return AsyncThrowingStream { continuation in
            let state = StreamCancellationState()

            continuation.onTermination = { _ in
                state.cancel()
            }

            DispatchQueue.global(qos: .userInitiated).async {
                for baseArgs in argumentSets {
                    if state.isCancelled { break }
                    var args = baseArgs
                    if let pathFilter, !pathFilter.isEmpty {
                        args += ["--"] + pathFilter.sorted()
                    }

                    var yieldedAny = false
                    do {
                        try GitStreamReader.shared.streamGitDiff(
                            arguments: args,
                            shouldCancel: { state.isCancelled },
                            onProcessStarted: { state.setActiveProcess($0) },
                            onProcessFinished: { state.clearActiveProcess() }
                        ) { file in
                            if !state.isCancelled {
                                yieldedAny = true
                                continuation.yield(file)
                            }
                        }
                    } catch {
                        state.clearActiveProcess()
                        continue
                    }

                    if yieldedAny {
                        break
                    }
                }

                if case .workingTree = target, !state.isCancelled {
                    let untracked = self.untrackedFiles(at: path, pathFilter: pathFilter)
                    let filtered = self.filterIgnoredFiles(untracked, at: path)
                    for file in filtered {
                        if state.isCancelled { break }
                        continuation.yield(file)
                    }
                }

                continuation.finish()
            }
        }
    }

    private final class StreamCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var activeProcess: Process?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func setActiveProcess(_ process: Process) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled {
                activeProcess = process
            }
            lock.unlock()
            if alreadyCancelled {
                process.terminate()
            }
        }

        func clearActiveProcess() {
            lock.lock()
            activeProcess = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = activeProcess
            activeProcess = nil
            lock.unlock()
            process?.terminate()
        }
    }

    public func filterIgnoredFiles(_ files: [FileDiff], at directory: String) -> [FileDiff] {
        guard !files.isEmpty else { return [] }
        let paths = files.map(\.displayPath)
        let ignoredPaths = self.ignoredPaths(paths: paths, at: directory)
        guard !ignoredPaths.isEmpty else { return files }
        return files.filter {
            !ignoredPaths.contains($0.displayPath) &&
            !ignoredPaths.contains($0.newPath) &&
            !ignoredPaths.contains($0.oldPath)
        }
    }

    public func ignoredPaths(paths: [String], at directory: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var result = Set<String>()
        let batchSize = 250
        for i in stride(from: 0, to: paths.count, by: batchSize) {
            let batch = Array(paths[i..<min(i + batchSize, paths.count)])
            var args = ["-C", directory, "check-ignore", "--no-index", "--"]
            args.append(contentsOf: batch)
            if let output = run(arguments: args), !output.isEmpty {
                let ignored = output.components(separatedBy: "\n")
                    .map { unescapeGitPath($0[...]) }
                    .filter { !$0.isEmpty }
                result.formUnion(ignored)
            }
        }
        return result
    }

    public func untrackedFiles(at path: String, pathFilter: Set<String>? = nil) -> [FileDiff] {
        var args = ["-C", path, "ls-files", "--others", "--exclude-standard"]
        if let pathFilter, !pathFilter.isEmpty {
            args += ["--"] + pathFilter.sorted()
        }
        guard let output = run(arguments: args), !output.isEmpty else {
            return []
        }
        let filePaths = output.components(separatedBy: "\n")
            .map { unescapeGitPath($0[...]) }
            .filter { !$0.isEmpty && (pathFilter == nil || pathFilter!.contains($0)) }
        var result: [FileDiff] = []
        for relPath in filePaths {
            let fullPath = URL(fileURLWithPath: path).appendingPathComponent(relPath).path
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")
            let diffLines = lines.enumerated().map { (idx, text) in
                DiffLine(kind: .added, text: text, oldLineNumber: nil, newLineNumber: idx + 1)
            }
            let hunk = DiffHunk(
                oldRange: 0..<0,
                newRange: 1..<(lines.count + 1),
                header: "",
                lines: diffLines,
                addedLineCount: lines.count,
                deletedLineCount: 0
            )
            let fileDiff = FileDiff(
                oldPath: relPath,
                newPath: relPath,
                status: .added,
                hunks: [hunk]
            )
            result.append(fileDiff)
        }
        return result
    }

    public func renamedPaths(at directory: String, relatedTo path: String) -> Set<String> {
        guard let output = run(arguments: ["-C", directory, "diff", "HEAD", "--name-status", "-M"]) else { return [] }
        var paths = Set<String>()
        for line in output.split(whereSeparator: { $0 == "\n" }) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescapeGitPath($0[...]) }
            guard fields.count >= 3, fields[0].hasPrefix("R") else { continue }
            if fields[1] == path || fields[2] == path {
                paths.insert(fields[1])
                paths.insert(fields[2])
            }
        }
        return paths
    }

    /// Computes aggregate uncommitted additions/deletions (tracked + untracked) for a working tree
    /// using `git diff --numstat -z` and direct byte line counting without parsing full patch hunks.
    public func workingTreeDiffStats(at path: String) -> GitDiffStats {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return .zero
        }

        let headResult = runWithStatus(arguments: ["-C", path, "diff", "--numstat", "-z", "HEAD"])
        let trackedStats: GitDiffStats
        if headResult.exitCode == 0 {
            trackedStats = Self.parseNumstatZ(headResult.stdout)
        } else {
            let stagedResult = runWithStatus(arguments: ["-C", path, "diff", "--numstat", "-z", "--staged"])
            if stagedResult.exitCode == 0 {
                trackedStats = Self.parseNumstatZ(stagedResult.stdout)
            } else {
                let unstagedResult = runWithStatus(arguments: ["-C", path, "diff", "--numstat", "-z"])
                trackedStats = Self.parseNumstatZ(unstagedResult.stdout)
            }
        }

        var untrackedAdditions = 0
        let untrackedResult = runWithStatus(arguments: ["-C", path, "ls-files", "--others", "--exclude-standard", "-z"])
        if untrackedResult.exitCode == 0, !untrackedResult.stdout.isEmpty {
            let baseURL = URL(fileURLWithPath: path, isDirectory: true)
            untrackedResult.stdout.withUnsafeBytes { rawBuffer in
                var start = 0
                let count = rawBuffer.count
                while start < count {
                    var end = start
                    while end < count && rawBuffer[end] != 0 {
                        end += 1
                    }
                    if end > start,
                       let relPath = String(bytes: rawBuffer[start..<end], encoding: .utf8) {
                        let fileURL = baseURL.appendingPathComponent(relPath, isDirectory: false)
                        if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                           values.isRegularFile == true,
                           let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
                            untrackedAdditions += Self.countTextLines(in: fileData)
                        }
                    }
                    start = end + 1
                }
            }
        }

        return GitDiffStats(
            additions: trackedStats.additions + untrackedAdditions,
            deletions: trackedStats.deletions
        )
    }

    public static func parseNumstatZ(_ data: Data) -> GitDiffStats {
        guard !data.isEmpty else { return .zero }
        var additions = 0
        var deletions = 0

        data.withUnsafeBytes { rawBuffer in
            let count = rawBuffer.count
            var index = 0
            var skipChunks = 0

            while index < count {
                var end = index
                while end < count && rawBuffer[end] != 0 {
                    end += 1
                }

                if skipChunks > 0 {
                    skipChunks -= 1
                    index = end + 1
                    continue
                }

                if end > index {
                    var firstTab = -1
                    var secondTab = -1
                    var cursor = index
                    while cursor < end {
                        if rawBuffer[cursor] == 0x09 {
                            if firstTab < 0 {
                                firstTab = cursor
                            } else {
                                secondTab = cursor
                                break
                            }
                        }
                        cursor += 1
                    }

                    if firstTab > index, secondTab > firstTab {
                        additions += parseASCIIInt(rawBuffer, from: index, to: firstTab)
                        deletions += parseASCIIInt(rawBuffer, from: firstTab + 1, to: secondTab)
                        // Rename/copy entries have an empty path after the second tab,
                        // followed by two NUL-terminated paths (oldPath\0newPath\0).
                        if secondTab + 1 == end {
                            skipChunks = 2
                        }
                    }
                }

                index = end + 1
            }
        }

        return GitDiffStats(additions: additions, deletions: deletions)
    }

    private static func parseASCIIInt(_ buffer: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Int {
        var value = 0
        for idx in start..<end {
            let byte = buffer[idx]
            guard byte >= 0x30 && byte <= 0x39 else { return 0 }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func countTextLines(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let sampleCount = min(rawBuffer.count, 4096)
            for idx in 0..<sampleCount {
                if rawBuffer[idx] == 0 {
                    return 0
                }
            }
            var lines = 0
            for idx in 0..<rawBuffer.count {
                if rawBuffer[idx] == 0x0A {
                    lines += 1
                }
            }
            if rawBuffer[rawBuffer.count - 1] != 0x0A {
                lines += 1
            }
            return lines
        }
    }
}
