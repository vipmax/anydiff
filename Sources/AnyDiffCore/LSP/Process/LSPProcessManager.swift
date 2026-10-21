import Foundation

public struct LSPProcessSession: Identifiable, Sendable {
    public let id: String
    public let packageId: String
    public let executablePath: String
    public let pid: Int32
    public let startDate: Date

    public init(id: String, packageId: String, executablePath: String, pid: Int32, startDate: Date) {
        self.id = id
        self.packageId = packageId
        self.executablePath = executablePath
        self.pid = pid
        self.startDate = startDate
    }
}

public actor LSPProcessManager {
    public static let shared = LSPProcessManager()

    private var activeProcesses: [String: Process] = [:]
    private var activeSessions: [String: LSPProcessSession] = [:]

    public init() {}

    /// Launches an LSP server process connected to standard I/O pipes.
    public func launchServer(
        for package: LSPRegistryPackage,
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> LSPProcessSession {
        // Terminate existing session for this package if any
        if let existing = activeProcesses[package.id] {
            existing.terminate()
            activeProcesses.removeValue(forKey: package.id)
            activeSessions.removeValue(forKey: package.id)
        }

        guard let (command, args) = LSPRegistryService.shared.launchCommand(for: package) else {
            throw LSPDownloadError.executableNotFound("No executable command configured for \(package.name)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let session = LSPProcessSession(
            id: UUID().uuidString,
            packageId: package.id,
            executablePath: command,
            pid: process.processIdentifier,
            startDate: Date()
        )

        activeProcesses[package.id] = process
        activeSessions[package.id] = session

        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in
                await self?.handleTermination(packageId: package.id)
            }
        }

        return session
    }

    /// Verifies that the installed server can execute by running it with `--version` or checking execution.
    public func testRun(package: LSPRegistryPackage) async throws -> String {
        guard let (command, _) = LSPRegistryService.shared.launchCommand(for: package) else {
            throw LSPDownloadError.executableNotFound("Executable not found for \(package.name)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["--version"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !outText.isEmpty {
                return outText
            } else if !errText.isEmpty {
                return errText
            } else {
                return "\(package.name) process started and verified (exit code \(process.terminationStatus))."
            }
        } catch {
            throw LSPDownloadError.executionFailed("Failed to launch \(command): \(error.localizedDescription)")
        }
    }

    /// Terminates an active server process.
    public func terminateServer(packageId: String) {
        if let process = activeProcesses[packageId] {
            process.terminate()
            activeProcesses.removeValue(forKey: packageId)
            activeSessions.removeValue(forKey: packageId)
        }
    }

    /// Terminates all active server processes.
    public func terminateAll() {
        for (_, process) in activeProcesses {
            process.terminate()
        }
        activeProcesses.removeAll()
        activeSessions.removeAll()
    }

    /// Checks if a server is currently running.
    public func isRunning(packageId: String) -> Bool {
        activeProcesses[packageId]?.isRunning ?? false
    }

    private func handleTermination(packageId: String) {
        activeProcesses.removeValue(forKey: packageId)
        activeSessions.removeValue(forKey: packageId)
    }
}
