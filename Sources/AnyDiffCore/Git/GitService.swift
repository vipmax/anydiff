import Foundation

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
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch {
            return nil
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
}
