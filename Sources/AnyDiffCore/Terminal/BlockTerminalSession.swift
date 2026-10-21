import Foundation
import Combine

/// Coordinates execution of shell commands within a persistent shell process,
/// streams output into TerminalMultiBuffer, and manages stdin/signals without terminating the shell.
@MainActor
public final class BlockTerminalSession: ObservableObject {
    public let multiBuffer: TerminalMultiBuffer
    @Published public private(set) var currentDirectory: String
    @Published public private(set) var gitBranch: String? = nil
    @Published public private(set) var isProcessRunning: Bool = false
    @Published public private(set) var commandHistory: [String] = []
    @Published public private(set) var isAlternateBufferActive: Bool = false

    /// The persistent shell session that stays alive across commands.
    public let persistentSession: TerminalSession
    public var activeTerminalSession: TerminalSession? { persistentSession }

    private struct PendingCommand {
        let blockId: UUID
        let command: String
    }

    private let promptMarker: String
    private var isShellReady: Bool = false
    private var pendingCommands: [PendingCommand] = []
    private var activeBlockId: UUID?
    private var streamBuffer: String = ""

    public init(
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        multiBuffer: TerminalMultiBuffer = TerminalMultiBuffer()
    ) {
        self.currentDirectory = workingDirectory
        self.multiBuffer = multiBuffer
        self.promptMarker = "__ANYDIFF_PROMPT_\(UUID().uuidString.prefix(8))__"
        self.persistentSession = TerminalSession(
            workingDirectory: workingDirectory,
            disableEcho: true,
            cols: 80,
            rows: 24
        )
        updateGitBranch()
        setupPersistentShell()
    }

    isolated deinit {
        persistentSession.onOutputReceived = nil
        persistentSession.onAlternateBufferToggled = nil
        persistentSession.onTerminated = nil
        persistentSession.terminateProcess()
    }

    private func setupPersistentShell() {
        persistentSession.onAlternateBufferToggled = { [weak self] isAlt in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isAlternateBufferActive = isAlt
                if let blockId = self.activeBlockId,
                   let block = self.multiBuffer.blocks.first(where: { $0.id == blockId }) {
                    block.isAlternateBuffer = isAlt
                    if isAlt {
                        block.lines.removeAll()
                    }
                }
            }
        }

        persistentSession.onOutputReceived = { [weak self] data in
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.handleShellOutput(text)
            }
        }

        persistentSession.onTerminated = { [weak self] code in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let blockId = self.activeBlockId {
                    self.multiBuffer.completeBlock(id: blockId, exitCode: code)
                    self.activeBlockId = nil
                }
                self.isProcessRunning = false
                self.isAlternateBufferActive = false
                self.isShellReady = false
            }
        }

        persistentSession.start()

        // Configure persistent shell: precmd hook emits delimiter with exit code and physical directory.
        // Split promptMarker string literal in initScript so shell echoing the script does not trigger the marker.
        let p1 = String(promptMarker.prefix(10))
        let p2 = String(promptMarker.dropFirst(10))
        let initScript = "unsetopt prompt_cr prompt_sp; setopt chase_links; __m='\(p1)''\(p2)'; precmd() { print -n \"\\n${__m}:$?:$(pwd -P)\\n\"; }; PROMPT=\"\"; PS1=\"\"; PS2=\"\"\n"
        persistentSession.sendInput(initScript)
    }

    /// Executes a shell command within the persistent shell session.
    public func execute(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Record into history (avoid duplicate consecutive)
        if commandHistory.last != trimmed {
            commandHistory.append(trimmed)
        }

        // Handle built-in: clear
        if trimmed == "clear" {
            multiBuffer.clear()
            return
        }

        // Always create the block immediately so it exists synchronously
        let block = multiBuffer.createBlock(
            command: trimmed,
            workingDirectory: currentDirectory,
            gitBranch: gitBranch,
            interactiveSession: persistentSession
        )

        guard isShellReady else {
            pendingCommands.append(PendingCommand(blockId: block.id, command: trimmed))
            return
        }

        if isProcessRunning {
            // If already running, send as stdin input (e.g. for [y/n] or REPL)
            sendInput(trimmed + "\n")
            return
        }

        isProcessRunning = true
        self.activeBlockId = block.id
        self.streamBuffer = ""

        persistentSession.sendInput(trimmed + "\n")
    }

    private func handleShellOutput(_ text: String) {
        streamBuffer.append(text)

        while let markerRange = streamBuffer.range(of: promptMarker) {
            let outputBefore = String(streamBuffer[..<markerRange.lowerBound])
            let afterMarker = streamBuffer[markerRange.upperBound...]

            // Check if we have the end of the prompt marker line (terminated by \r or \n)
            guard let lineBreakRange = afterMarker.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) else {
                return
            }

            let metaStr = String(afterMarker[..<lineBreakRange.lowerBound])
            var rest = afterMarker[lineBreakRange.upperBound...]
            if rest.hasPrefix("\n") {
                rest.removeFirst()
            }
            streamBuffer = String(rest)

            // Parse meta: ":<exitCode>:<pwd>"
            var exitCode: Int32 = 0
            var newDirectory: String? = nil
            if metaStr.hasPrefix(":") {
                let trimmedMeta = String(metaStr.dropFirst())
                let parts = trimmedMeta.components(separatedBy: ":")
                if let codeVal = parts.first, let parsed = Int32(codeVal) {
                    exitCode = parsed
                }
                if parts.count >= 2 {
                    newDirectory = parts.dropFirst().joined(separator: ":")
                }
            }

            if !isShellReady {
                // Shell has emitted its startup prompt and is primed
                isShellReady = true
                if let newDir = newDirectory, !newDir.isEmpty {
                    self.currentDirectory = newDir
                    self.persistentSession.updateCurrentDirectory(newDir)
                    self.updateGitBranch()
                }
                self.streamBuffer = ""
                if !pendingCommands.isEmpty {
                    let next = pendingCommands.removeFirst()
                    self.isProcessRunning = true
                    self.activeBlockId = next.blockId
                    persistentSession.sendInput(next.command + "\n")
                }
                return
            }

            // Command output
            if let blockId = activeBlockId {
                var cleanOutput = outputBefore
                if cleanOutput.hasSuffix("\r\n") {
                    cleanOutput.removeLast()
                } else if cleanOutput.hasSuffix("\n") || cleanOutput.hasSuffix("\r") {
                    cleanOutput.removeLast()
                }
                if !cleanOutput.isEmpty {
                    multiBuffer.appendOutput(to: blockId, text: cleanOutput)
                }
                multiBuffer.completeBlock(id: blockId, exitCode: exitCode)
            }

            if let newDir = newDirectory, !newDir.isEmpty {
                self.currentDirectory = newDir
                self.persistentSession.updateCurrentDirectory(newDir)
                self.updateGitBranch()
            }

            self.activeBlockId = nil
            self.isProcessRunning = false
            self.isAlternateBufferActive = false

            if !pendingCommands.isEmpty {
                let next = pendingCommands.removeFirst()
                self.isProcessRunning = true
                self.activeBlockId = next.blockId
                self.streamBuffer = ""
                persistentSession.sendInput(next.command + "\n")
            }
            return
        }

        // If marker is not yet in streamBuffer and command is actively running:
        if isShellReady, let blockId = activeBlockId, !isAlternateBufferActive {
            if streamBuffer.count > promptMarker.count + 8 {
                let safeLength = streamBuffer.count - (promptMarker.count + 8)
                let safeIndex = streamBuffer.index(streamBuffer.startIndex, offsetBy: safeLength)
                let chunkToFlush = String(streamBuffer[..<safeIndex])
                streamBuffer = String(streamBuffer[safeIndex...])
                multiBuffer.appendOutput(to: blockId, text: chunkToFlush)
            }
        }
    }

    /// Sends text input to the currently running process (e.g. for [y/n], passwords, or interactive programs).
    public func sendInput(_ text: String) {
        persistentSession.sendInput(text)
    }

    /// Sends a SIGINT interrupt (Ctrl+C) to cancel the running process.
    public func sendInterrupt() {
        guard isProcessRunning else { return }
        persistentSession.sendInput("\u{03}")
        persistentSession.sendSignal(SIGINT)
    }

    public func updateGitBranch() {
        let headPath = (currentDirectory as NSString).appendingPathComponent(".git/HEAD")
        if let content = try? String(contentsOfFile: headPath, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ref: refs/heads/") {
                self.gitBranch = String(trimmed.dropFirst("ref: refs/heads/".count))
                return
            }
        }
        self.gitBranch = nil
    }
}
