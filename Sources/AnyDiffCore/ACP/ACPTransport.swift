import Foundation

public protocol ACPTransportDelegate: AnyObject, Sendable {
    func transport(_ transport: ACPTransport, didReceiveLine data: Data)
    func transport(_ transport: ACPTransport, didLogStderr text: String)
    func transport(_ transport: ACPTransport, didTerminateWith exitCode: Int32)
}

public final class ACPTransport: @unchecked Sendable {
    public weak var delegate: ACPTransportDelegate?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let readQueue = DispatchQueue(label: "com.anydiff.acp.transport.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.anydiff.acp.transport.write", qos: .userInitiated)
    private var stdoutBuffer = Data()
    private var isRunningInternal = false

    public var isRunning: Bool {
        isRunningInternal && process?.isRunning == true
    }

    public init() {}

    deinit {
        terminate()
    }

    public func launch(command: String, workingDirectory: String, environment: [String: String]? = nil) throws {
        terminate()

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Enhance PATH environment variable for macOS GUI environments to find node/npx/homebrew
        var mergedEnv = ProcessInfo.processInfo.environment
        if let customEnv = environment {
            mergedEnv.merge(customEnv) { _, new in new }
        }

        let existingPath = mergedEnv["PATH"] ?? ""
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo/bin").path
        ]
        var pathComponents = existingPath.components(separatedBy: ":")
        for extra in extraPaths {
            if !pathComponents.contains(extra) && FileManager.default.fileExists(atPath: extra) {
                pathComponents.insert(extra, at: 0)
            }
        }
        mergedEnv["PATH"] = pathComponents.joined(separator: ":")
        proc.environment = mergedEnv

        // Launch shell command via login shell to evaluate environment & PATH correctly
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", command]

        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            self.isRunningInternal = false
            self.delegate?.transport(self, didTerminateWith: p.terminationStatus)
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.isRunningInternal = true
        self.stdoutBuffer.removeAll()

        startReadingOutput(pipe: outPipe)
        startReadingStderr(pipe: errPipe)
    }

    public func sendLine(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self = self, self.isRunning, let handle = self.stdinPipe?.fileHandleForWriting else { return }
            var lineData = data
            if lineData.last != UInt8(ascii: "\n") {
                lineData.append(UInt8(ascii: "\n"))
            }
            do {
                try handle.write(contentsOf: lineData)
            } catch {
                self.delegate?.transport(self, didLogStderr: "Failed to write to stdin: \(error.localizedDescription)\n")
            }
        }
    }

    public func terminate() {
        isRunningInternal = false
        if let inPipe = stdinPipe {
            try? inPipe.fileHandleForWriting.close()
        }
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll()
    }

    private func startReadingOutput(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }

            self.readQueue.async {
                self.stdoutBuffer.append(data)
                self.processBufferedLines()
            }
        }
    }

    private func processBufferedLines() {
        let newline = UInt8(ascii: "\n")
        while let index = stdoutBuffer.firstIndex(of: newline) {
            let lineData = stdoutBuffer.subdata(in: 0..<index)
            stdoutBuffer.removeSubrange(0...index)

            // Strip optional trailing \r
            var cleanLine = lineData
            if cleanLine.last == UInt8(ascii: "\r") {
                cleanLine.removeLast()
            }

            guard !cleanLine.isEmpty else { continue }
            self.delegate?.transport(self, didReceiveLine: cleanLine)
        }
    }

    private func startReadingStderr(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.delegate?.transport(self, didLogStderr: text)
        }
    }
}
