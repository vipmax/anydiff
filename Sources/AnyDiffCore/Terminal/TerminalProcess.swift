import Foundation
import Darwin

/// Manages a background pseudo-terminal (PTY) child process using macOS POSIX / forkpty APIs.
public final class TerminalProcess: @unchecked Sendable {
    public private(set) var pid: pid_t = 0
    public private(set) var masterFd: Int32 = -1
    public private(set) var isRunning: Bool = false
    public let workingDirectory: String

    private let readQueue = DispatchQueue(label: "com.anydiff.terminal.read", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?

    public var onOutput: ((Data) -> Void)?
    public var onTerminated: ((Int32) -> Void)?

    public init(workingDirectory: String = FileManager.default.currentDirectoryPath) {
        self.workingDirectory = workingDirectory
    }

    deinit {
        terminate()
    }

    /// Spawns the interactive login shell attached to a newly created PTY master/slave pair.
    public func start(cols: Int = 80, rows: Int = 24) throws {
        guard !isRunning else { return }

        var master: Int32 = -1
        var win = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let fm = FileManager.default
        let targetDir = fm.fileExists(atPath: workingDirectory) ? workingDirectory : NSHomeDirectory()
        let envShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellPath = fm.isExecutableFile(atPath: envShell) ? envShell : "/bin/zsh"

        let childPid = forkpty(&master, nil, nil, &win)
        guard childPid >= 0 else {
            let errorNumber = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSLocalizedDescriptionKey: "forkpty failed with errno \(errorNumber)"]
            )
        }

        if childPid == 0 {
            // Child process: controlling terminal is already established by forkpty
            chdir(targetDir)

            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("PWD", targetDir, 1)
            if getenv("LANG") == nil {
                setenv("LANG", "en_US.UTF-8", 1)
            }

            let cShell = strdup(shellPath)
            let cArg1 = strdup("-l")
            var argv: [UnsafeMutablePointer<CChar>?] = [cShell, cArg1, nil]
            execv(shellPath, &argv)
            _exit(127)
        }

        self.pid = childPid
        self.masterFd = master
        self.isRunning = true

        setupDispatchSources(masterFd: master, childPid: childPid)
    }

    private func setupDispatchSources(masterFd: Int32, childPid: pid_t) {
        // Read source for PTY master output
        let readSrc = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: readQueue)
        var readBuffer = [UInt8](repeating: 0, count: 16384)

        readSrc.setEventHandler { [weak self] in
            guard let self = self else { return }
            let bytesRead = read(masterFd, &readBuffer, readBuffer.count)
            if bytesRead > 0 {
                let chunk = Data(readBuffer.prefix(bytesRead))
                self.onOutput?(chunk)
            } else if bytesRead <= 0 {
                // EOF or error
                readSrc.cancel()
            }
        }

        readSrc.setCancelHandler {
            close(masterFd)
        }

        self.readSource = readSrc
        readSrc.resume()

        // Process monitor for termination
        let procSrc = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: readQueue)
        procSrc.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(childPid, &status, WNOHANG)
            let exitCode = (status >> 8) & 0xFF
            self.isRunning = false
            self.onTerminated?(exitCode)
            procSrc.cancel()
        }

        self.processSource = procSrc
        procSrc.resume()
    }

    /// Writes raw input data (keystrokes, text, ANSI escape sequences) to the PTY master.
    public func write(data: Data) {
        guard isRunning, masterFd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = Darwin.write(masterFd, ptr, buffer.count)
        }
    }

    /// Writes a UTF-8 string to the PTY master.
    public func write(string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data: data)
    }

    /// Resizes the pseudo-terminal window dimensions, triggering SIGWINCH on the child process.
    public func resize(cols: Int, rows: Int) {
        guard masterFd >= 0 else { return }
        var win = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &win)
        if pid > 0 {
            Darwin.kill(pid, SIGWINCH)
            Darwin.kill(-pid, SIGWINCH)
        }
    }

    /// Gracefully sends SIGHUP/SIGTERM or forces SIGKILL on the child process.
    public func terminate() {
        guard isRunning, pid > 0 else { return }
        isRunning = false

        readSource?.cancel()
        readSource = nil
        processSource?.cancel()
        processSource = nil

        Darwin.kill(pid, SIGHUP)
        var status: Int32 = 0
        // Short poll wait, then fallback to SIGKILL if necessary
        usleep(50_000)
        if waitpid(pid, &status, WNOHANG) == 0 {
            Darwin.kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        masterFd = -1
        pid = 0
    }
}
