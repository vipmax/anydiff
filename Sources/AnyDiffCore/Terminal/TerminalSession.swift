import Foundation
import Combine

/// High-level terminal session coordinating the PTY process, screen buffer, and escape parser.
@MainActor
public final class TerminalSession: ObservableObject {
    @Published public private(set) var title: String = "Terminal"
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var exitCode: Int32? = nil
    @Published public private(set) var currentDirectory: String
    public private(set) var renderVersion: UInt64 = 0

    public let screen: TerminalScreen
    private let parser: TerminalEscapeParser
    private var process: TerminalProcess?

    private let outputBufferLock = NSLock()
    private var pendingOutput = Data()
    private var flushScheduled: Bool = false

    public var onScreenUpdated: (() -> Void)?
    public var onBell: (() -> Void)?
    public var onInputSent: ((Data) -> Void)?

    public init(
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        cols: Int = 80,
        rows: Int = 24
    ) {
        self.currentDirectory = workingDirectory
        let scr = TerminalScreen(cols: cols, rows: rows)
        self.screen = scr
        self.parser = TerminalEscapeParser(screen: scr)

        parser.onTitleChanged = { [weak self] newTitle in
            Task { @MainActor [weak self] in
                guard let self = self, !newTitle.isEmpty else { return }
                self.title = newTitle
            }
        }

        parser.onBell = { [weak self] in
            Task { @MainActor [weak self] in
                self?.onBell?()
            }
        }
    }

    /// Starts or restarts the interactive shell process in the target directory.
    public func start() {
        terminateProcess()

        exitCode = nil
        let proc = TerminalProcess(workingDirectory: currentDirectory)
        self.process = proc

        parser.onResponseRequired = { [weak proc] data in
            proc?.write(data: data)
        }

        proc.onOutput = { [weak self] data in
            guard let self = self else { return }
            self.outputBufferLock.lock()
            self.pendingOutput.append(data)
            let needsSchedule = !self.flushScheduled
            self.flushScheduled = true
            self.outputBufferLock.unlock()

            if needsSchedule {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.outputBufferLock.lock()
                    let chunk = self.pendingOutput
                    self.pendingOutput = Data()
                    self.flushScheduled = false
                    self.outputBufferLock.unlock()

                    guard !chunk.isEmpty else { return }
                    self.parser.feed(chunk)
                    self.renderVersion &+= 1
                    self.onScreenUpdated?()
                }
            }
        }

        proc.onTerminated = { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isRunning = false
                self.exitCode = code
                self.scheduleRedraw()
            }
        }

        do {
            try proc.start(cols: screen.cols, rows: screen.rows)
            isRunning = true
            scheduleRedraw()
        } catch {
            isRunning = false
            exitCode = -1
            let errorMsg = "\r\n[Failed to launch terminal process: \(error.localizedDescription)]\r\n"
            if let data = errorMsg.data(using: .utf8) {
                parser.feed(data)
            }
            scheduleRedraw()
        }
    }

    /// Sends user keyboard or pasted input to the terminal process.
    public func sendInput(_ string: String) {
        if let data = string.data(using: .utf8) {
            onInputSent?(data)
        }
        process?.write(string: string)
    }

    /// Sends raw byte input to the terminal process.
    public func sendData(_ data: Data) {
        onInputSent?(data)
        process?.write(data: data)
    }

    /// Resizes the terminal screen grid and sends SIGWINCH to the child process.
    public func resize(cols: Int, rows: Int) {
        screen.resize(cols: cols, rows: rows)
        process?.resize(cols: screen.cols, rows: screen.rows)
        scheduleRedraw()
    }

    /// Clears visible screen and scrollback history.
    public func clear() {
        outputBufferLock.lock()
        pendingOutput.removeAll(keepingCapacity: false)
        outputBufferLock.unlock()
        screen.eraseInDisplay(mode: 3)
        screen.setCursorPosition(col: 0, row: 0)
        scheduleRedraw()
    }

    /// Restarts the terminal session in the specified or current directory.
    public func restart(workingDirectory: String? = nil) {
        if let dir = workingDirectory, !dir.isEmpty {
            self.currentDirectory = dir
        }
        clear()
        start()
    }

    /// Terminates the running shell process.
    public func terminateProcess() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Redraw notification to update the UI on the main thread.
    private func scheduleRedraw() {
        renderVersion &+= 1
        onScreenUpdated?()
    }

    deinit {
        process?.terminate()
    }
}
