import Foundation
import Darwin

/// Manages a background pseudo-terminal (PTY) child process using macOS POSIX / forkpty APIs.
public final class TerminalProcess: @unchecked Sendable {
    public private(set) var pid: pid_t = 0
    public private(set) var masterFd: Int32 = -1
    public private(set) var isRunning: Bool = false
    public let workingDirectory: String
    public let environment: [String: String]?
    public let disableEcho: Bool

    private let readQueue = DispatchQueue(label: "com.anydiff.terminal.read", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?

    public var onOutput: ((Data) -> Void)?
    public var onTerminated: ((Int32) -> Void)?

    public init(
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        environment: [String: String]? = nil,
        disableEcho: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.disableEcho = disableEcho
    }

    deinit {
        terminate()
    }

    /// Spawns the interactive login shell or a specific command attached to a newly created PTY master/slave pair.
    public func start(command: String? = nil, cols: Int = 80, rows: Int = 24) throws {
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

            if disableEcho {
                var attrs = termios()
                if tcgetattr(STDIN_FILENO, &attrs) == 0 {
                    attrs.c_lflag &= ~tcflag_t(ECHO)
                    tcsetattr(STDIN_FILENO, TCSANOW, &attrs)
                }
            }

            if let customEnv = environment {
                var ptr = environ
                var toUnset: [String] = []
                while let cstr = ptr.pointee {
                    let entry = String(cString: cstr)
                    if let eq = entry.firstIndex(of: "=") {
                        let k = String(entry[..<eq])
                        if customEnv[k] == nil && k != "PWD" && k != "OLDPWD" && k != "SHLVL" && k != "_" {
                            toUnset.append(k)
                        }
                    }
                    ptr = ptr.advanced(by: 1)
                }
                for k in toUnset {
                    unsetenv(k)
                }
                for (k, v) in customEnv {
                    setenv(k, v, 1)
                }
            }

            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("PWD", targetDir, 1)
            if getenv("PAGER") == nil {
                setenv("PAGER", "cat", 1)
            }
            if getenv("GIT_PAGER") == nil {
                setenv("GIT_PAGER", "cat", 1)
            }
            if getenv("LANG") == nil {
                setenv("LANG", "en_US.UTF-8", 1)
            }

            if let currentPath = getenv("PATH") {
                let pathStr = String(cString: currentPath)
                if !pathStr.contains("/opt/homebrew/bin") && FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
                    setenv("PATH", "/opt/homebrew/bin:/opt/homebrew/sbin:" + pathStr, 1)
                }
            }

            if let cmd = command {
                let cShell = strdup(shellPath)
                let cArg1 = strdup("-i")
                let cArg2 = strdup("-c")
                let cArg3 = strdup(cmd)
                var argv: [UnsafeMutablePointer<CChar>?] = [cShell, cArg1, cArg2, cArg3, nil]
                execv(shellPath, &argv)
            } else if disableEcho {
                let cShell = strdup(shellPath)
                let cArg1 = strdup("-i")
                let cArg2 = strdup("+Z")
                var argv: [UnsafeMutablePointer<CChar>?] = [cShell, cArg1, cArg2, nil]
                execv(shellPath, &argv)
            } else {
                let cShell = strdup(shellPath)
                let cArg1 = strdup("-i")
                var argv: [UnsafeMutablePointer<CChar>?] = [cShell, cArg1, nil]
                execv(shellPath, &argv)
            }
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

    /// Sends a POSIX signal (such as SIGINT or SIGTERM) to the child process group.
    public func sendSignal(_ signal: Int32) {
        guard isRunning, pid > 0 else { return }
        Darwin.kill(pid, signal)
        Darwin.kill(-pid, signal)
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
