import Foundation
import CryptoKit

public enum ACPRegistryDownloadError: LocalizedError, Sendable {
    case unsupportedArchiveFormat(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case executableNotFound(String)
    case networkError(String)

    public var errorDescription: String? {
        matchDescription
    }

    private var matchDescription: String {
        switch self {
        case .unsupportedArchiveFormat(let url):
            return "Unsupported archive format for download URL: \(url)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum verification failed. Expected: \(expected), got: \(actual)"
        case .extractionFailed(let message):
            return "Failed to extract archive: \(message)"
        case .executableNotFound(let path):
            return "Downloaded binary executable was not found at path: \(path)"
        case .networkError(let message):
            return "Network download failed: \(message)"
        }
    }
}

public enum ACPRegistryBinaryDownloader {
    public static var baseBinDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AnyDiff", isDirectory: true).appendingPathComponent("bin", isDirectory: true)
    }

    public static func agentDirectory(agentId: String, version: String) -> URL {
        let sanitizedId = agentId.replacingOccurrences(of: "/", with: "_")
        let sanitizedVersion = version.replacingOccurrences(of: "/", with: "_")
        return baseBinDirectory.appendingPathComponent(sanitizedId, isDirectory: true).appendingPathComponent(sanitizedVersion, isDirectory: true)
    }

    public static func sanitizeCmd(_ cmd: String) -> String {
        var cleaned = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("./") {
            cleaned.removeFirst(2)
        }
        return cleaned
    }

    public static func expectedExecutablePath(agentId: String, version: String, cmd: String) -> String {
        let dir = agentDirectory(agentId: agentId, version: version)
        return dir.appendingPathComponent(sanitizeCmd(cmd)).path
    }

    public static func isInstalled(agentId: String, version: String, cmd: String) -> Bool {
        let path = expectedExecutablePath(agentId: agentId, version: version, cmd: cmd)
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public static func removeAgent(agentId: String) {
        let sanitizedId = agentId.replacingOccurrences(of: "/", with: "_")
        let dir = baseBinDirectory.appendingPathComponent(sanitizedId, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Downloads, verifies, extracts, and marks the binary as executable.
    /// Returns the absolute path to the ready-to-run executable.
    public static func downloadAndInstall(
        agentId: String,
        version: String,
        target: ACPRegistryBinaryTarget,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard let archiveURL = URL(string: target.archive) else {
            throw ACPRegistryDownloadError.networkError("Invalid archive URL: \(target.archive)")
        }

        let targetDir = agentDirectory(agentId: agentId, version: version)
        let fm = FileManager.default
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let tempArchiveURL = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + archiveURL.lastPathComponent)
        defer {
            try? fm.removeItem(at: tempArchiveURL)
        }

        // 1. Download with real-time progressive streaming and cancellation
        try await downloadFile(from: archiveURL, to: tempArchiveURL) { progress in
            progressHandler?(progress * 0.88)
        }
        progressHandler?(0.88)

        // 2. Verify SHA256 if provided
        if let expectedSha = target.sha256, !expectedSha.isEmpty {
            let fileData = try Data(contentsOf: tempArchiveURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: fileData)
            let actualSha = digest.map { String(format: "%02x", $0) }.joined()
            let normalizedExpected = expectedSha.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if actualSha.lowercased() != normalizedExpected {
                throw ACPRegistryDownloadError.checksumMismatch(expected: normalizedExpected, actual: actualSha)
            }
        }
        progressHandler?(0.92)

        // 3. Extract
        let archiveLower = archiveURL.path.lowercased()
        if archiveLower.hasSuffix(".tar.gz") || archiveLower.hasSuffix(".tgz") {
            try extractTarGz(archive: tempArchiveURL, destination: targetDir)
        } else if archiveLower.hasSuffix(".zip") {
            try extractZip(archive: tempArchiveURL, destination: targetDir)
        } else {
            // Raw binary
            let destBinary = targetDir.appendingPathComponent(sanitizeCmd(target.cmd))
            try? fm.removeItem(at: destBinary)
            try fm.copyItem(at: tempArchiveURL, to: destBinary)
        }

        // 4. Ensure executable permissions
        let executablePath = expectedExecutablePath(agentId: agentId, version: version, cmd: target.cmd)
        if !fm.fileExists(atPath: executablePath) {
            let cleaned = sanitizeCmd(target.cmd)
            if let subpaths = try? fm.subpathsOfDirectory(atPath: targetDir.path) {
                for element in subpaths {
                    if element.hasSuffix("/" + cleaned) || element == cleaned {
                        let fullPath = targetDir.appendingPathComponent(element).path
                        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fullPath)
                        progressHandler?(1.0)
                        return fullPath
                    }
                }
            }
            throw ACPRegistryDownloadError.executableNotFound(executablePath)
        }

        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        progressHandler?(1.0)
        return executablePath
    }

    private static func extractTarGz(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown tar error"
            throw ACPRegistryDownloadError.extractionFailed(errorMsg)
        }
    }

    private static func extractZip(archive: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", archive.path, "-d", destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown unzip error"
            throw ACPRegistryDownloadError.extractionFailed(errorMsg)
        }
    }

    private static func downloadFile(
        from url: URL,
        to destinationURL: URL,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let delegate = DownloadDelegate(destinationURL: destinationURL, progressHandler: progressHandler)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.completion = { result in
                    session.invalidateAndCancel()
                    continuation.resume(with: result)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destinationURL: URL
        let progressHandler: (@Sendable (Double) -> Void)?
        var completion: ((Result<Void, Error>) -> Void)?
        private var lastReported: Double = 0.0
        private let lock = NSLock()
        private var isCompleted = false

        init(destinationURL: URL, progressHandler: (@Sendable (Double) -> Void)?) {
            self.destinationURL = destinationURL
            self.progressHandler = progressHandler
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if progress - lastReported >= 0.005 || progress >= 0.99 {
                lastReported = progress
                progressHandler?(progress)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if Task.isCancelled {
                finish(with: .failure(CancellationError()))
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: location, to: destinationURL)
                finish(with: .success(()))
            } catch {
                finish(with: .failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                let nsError = error as NSError
                if Task.isCancelled || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                    finish(with: .failure(CancellationError()))
                } else {
                    finish(with: .failure(error))
                }
            }
        }

        private func finish(with result: Result<Void, Error>) {
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            let cb = completion
            completion = nil
            lock.unlock()
            cb?(result)
        }
    }
}
