import Foundation

/// Service responsible for safely reverting and restoring changes made during an agent turn.
public enum AgentTurnRollbackService {

    /// Reverts all file additions, deletions, and modifications made during a turn.
    /// - Parameters:
    ///   - workingDirectory: Root working directory path.
    ///   - summary: The turn summary containing modified, created, and deleted files.
    /// - Returns: True if all rollback operations succeeded.
    @discardableResult
    public static func revertTurn(
        workingDirectory: String,
        summary: inout AgentEditedFilesSummary
    ) -> Bool {
        guard !workingDirectory.isEmpty, FileManager.default.fileExists(atPath: workingDirectory) else {
            return false
        }

        let resolvedWorkingDir = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path

        // 1. Capture post-turn state for tracked files before reverting so we can Redo/Restore later
        if summary.postTurnCommitHash == nil {
            let postHash = runGit(arguments: ["-C", resolvedWorkingDir, "stash", "create"])
            if let postHash, !postHash.isEmpty {
                summary.postTurnCommitHash = postHash
            }
        }

        var allSucceeded = true
        let baseRef = summary.baseCommitHash ?? "HEAD"

        var toDelete = Set(summary.createdFiles)
        var toRestore = Set(summary.modifiedFiles + summary.deletedFiles)

        if toDelete.isEmpty && toRestore.isEmpty && !summary.files.isEmpty {
            for item in summary.files {
                let checkArgs = ["-C", resolvedWorkingDir, "ls-tree", baseRef, item.path]
                if let output = runGit(arguments: checkArgs), !output.isEmpty {
                    toRestore.insert(item.path)
                } else {
                    toDelete.insert(item.path)
                }
            }
        }

        // 2. Cache created files content before deleting them so we can Restore (Redo) later
        var savedCreated = summary.savedCreatedFiles ?? [:]
        for relativePath in toDelete {
            let fullURL = URL(fileURLWithPath: resolvedWorkingDir).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: fullURL.path),
               let contents = try? String(contentsOf: fullURL, encoding: .utf8) {
                savedCreated[relativePath] = contents
            }
        }
        summary.savedCreatedFiles = savedCreated

        // 3. Delete newly created files
        for relativePath in toDelete {
            let fullURL = URL(fileURLWithPath: resolvedWorkingDir).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: fullURL.path) {
                do {
                    try FileManager.default.removeItem(at: fullURL)
                    removeEmptyParentDirectories(for: fullURL, upTo: URL(fileURLWithPath: resolvedWorkingDir))
                } catch {
                    allSucceeded = false
                }
            }
        }

        // 4. Restore modified and deleted files from baseRef
        if !toRestore.isEmpty {
            let sortedRestore = Array(toRestore).sorted()
            var args = ["-C", resolvedWorkingDir, "checkout", baseRef, "--"]
            args.append(contentsOf: sortedRestore)

            if runGit(arguments: args) == nil {
                for file in sortedRestore {
                    let fileArgs = ["-C", resolvedWorkingDir, "checkout", baseRef, "--", file]
                    if runGit(arguments: fileArgs) == nil {
                        allSucceeded = false
                    }
                }
            }
        }

        return allSucceeded
    }

    /// Restores (Redo) changes that were previously reverted for a turn.
    /// - Parameters:
    ///   - workingDirectory: Root working directory path.
    ///   - summary: The turn summary containing modified, created, and deleted files.
    /// - Returns: True if all restore operations succeeded.
    @discardableResult
    public static func restoreTurn(
        workingDirectory: String,
        summary: AgentEditedFilesSummary
    ) -> Bool {
        guard !workingDirectory.isEmpty, FileManager.default.fileExists(atPath: workingDirectory) else {
            return false
        }

        let resolvedWorkingDir = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path

        // 1. Restore created files from saved content
        if let savedFiles = summary.savedCreatedFiles {
            for (relativePath, content) in savedFiles {
                let fileURL = URL(fileURLWithPath: resolvedWorkingDir).appendingPathComponent(relativePath)
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }

        // 2. Checkout modified files from postTurnCommitHash
        if let postHash = summary.postTurnCommitHash, !postHash.isEmpty {
            let modifiedFiles = summary.modifiedFiles.filter { !summary.createdFiles.contains($0) }
            if !modifiedFiles.isEmpty {
                var args = ["-C", resolvedWorkingDir, "checkout", postHash, "--"]
                args.append(contentsOf: modifiedFiles)
                _ = runGit(arguments: args)
            }
            for del in summary.deletedFiles {
                let fullPath = URL(fileURLWithPath: resolvedWorkingDir).appendingPathComponent(del).path
                try? FileManager.default.removeItem(atPath: fullPath)
            }
            return true
        }

        // 3. Fallback: apply rawDiffData
        if let rawDiff = summary.rawDiffData, !rawDiff.isEmpty {
            return applyDiffData(rawDiff, workingDirectory: resolvedWorkingDir)
        }

        return (summary.savedCreatedFiles != nil && !summary.savedCreatedFiles!.isEmpty)
    }

    private static func applyDiffData(_ data: Data, workingDirectory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", workingDirectory, "apply", "--whitespace=nowarn", "-"]
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            inPipe.fileHandleForWriting.write(data)
            inPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func removeEmptyParentDirectories(for fileURL: URL, upTo rootURL: URL) {
        var currentDir = fileURL.deletingLastPathComponent()
        let rootPath = rootURL.standardizedFileURL.path

        while currentDir.standardizedFileURL.path != rootPath && currentDir.standardizedFileURL.path.hasPrefix(rootPath) {
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: currentDir.path)
                if contents.isEmpty {
                    try FileManager.default.removeItem(at: currentDir)
                    currentDir = currentDir.deletingLastPathComponent()
                } else {
                    break
                }
            } catch {
                break
            }
        }
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
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return nil
        }
    }
}
