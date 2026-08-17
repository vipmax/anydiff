import Foundation

/// High-performance streaming reader and parser for Git diffs using 64 KB POSIX chunking
public final class GitStreamReader: Sendable {
    public static let shared = GitStreamReader()

    public static let defaultChunkSize = 64 * 1024 // 64 KB

    public init() {}

    /// Runs `/usr/bin/git` with given arguments and streams parsed `FileDiff`s on the fly
    public func streamGitDiff(
        arguments: [String],
        workingDirectory: String? = nil,
        chunkSize: Int = defaultChunkSize,
        onFileParsed: @escaping (FileDiff) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let streamer = StreamingGitDiffParser()
        let splitter = ChunkLineSplitter { lineBytes in
            if let file = streamer.feed(lineBytes: lineBytes) {
                onFileParsed(file)
            }
        }

        try process.run()

        let readHandle = pipe.fileHandleForReading
        let fd = readHandle.fileDescriptor

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(fd, buffer, chunkSize)
            if bytesRead <= 0 { break }
            splitter.processChunk(UnsafeBufferPointer(start: buffer, count: bytesRead))
        }

        splitter.finish()
        if let lastFile = streamer.finish() {
            onFileParsed(lastFile)
        }

        process.waitUntilExit()
    }

    /// Streams diff from a local file path using 64 KB POSIX chunking
    public func streamFile(
        at url: URL,
        chunkSize: Int = defaultChunkSize,
        onFileParsed: @escaping (FileDiff) -> Void
    ) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOENT)
        }
        defer { close(fd) }

        let streamer = StreamingGitDiffParser()
        let splitter = ChunkLineSplitter { lineBytes in
            if let file = streamer.feed(lineBytes: lineBytes) {
                onFileParsed(file)
            }
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(fd, buffer, chunkSize)
            if bytesRead <= 0 { break }
            splitter.processChunk(UnsafeBufferPointer(start: buffer, count: bytesRead))
        }

        splitter.finish()
        if let lastFile = streamer.finish() {
            onFileParsed(lastFile)
        }
    }

    /// Reads and parses all FileDiffs from git process synchronously using streaming under the hood
    public func readGitDiff(
        arguments: [String],
        workingDirectory: String? = nil,
        chunkSize: Int = defaultChunkSize
    ) throws -> [FileDiff] {
        var results: [FileDiff] = []
        try streamGitDiff(arguments: arguments, workingDirectory: workingDirectory, chunkSize: chunkSize) { file in
            results.append(file)
        }
        return results
    }
}
