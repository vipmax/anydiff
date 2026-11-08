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
    public let commandSubmitted = PassthroughSubject<Void, Never>()

    /// The persistent shell session that stays alive across commands.
    public let persistentSession: TerminalSession
    public var activeTerminalSession: TerminalSession? { persistentSession }

    private struct PendingCommand {
        let blockId: UUID
        let command: String
    }

    private let promptMarker: String
    private let startMarker: String
    private var hasEncounteredStartMarker: Bool = false
    private var isShellReady: Bool = false
    private var pendingCommands: [PendingCommand] = []
    private var activeBlockId: UUID?
    private var streamBuffer: String = ""
    public let shellIntegration = TerminalShellIntegration()
    private var completionTimeoutWorkItem: DispatchWorkItem?

    public init(
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        multiBuffer: TerminalMultiBuffer = TerminalMultiBuffer()
    ) {
        self.currentDirectory = workingDirectory
        self.multiBuffer = multiBuffer
        self.promptMarker = "__ANYDIFF_PROMPT_\(UUID().uuidString.prefix(8))__"
        self.startMarker = "__ANYDIFF_START_\(UUID().uuidString.prefix(8))__"
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
            guard let self = self else { return }
            if self.isAlternateBufferActive { return }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isAlternateBufferActive && !text.contains(self.promptMarker) {
                    self.streamBuffer = ""
                    return
                }
                let cleaned = self.shellIntegration.filterAndParse(output: text)
                if !cleaned.isEmpty {
                    self.handleShellOutput(cleaned)
                }
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
                self.hasEncounteredStartMarker = false
            }
        }

        persistentSession.start()

        // Configure persistent shell:
        // - preexec hook emits startMarker right before command execution starts (after ZLE line editing/echo finishes).
        // - precmd hook emits promptMarker with exit code and physical directory after command execution finishes.
        // Split marker string literals in initScript so shell echoing the script does not trigger them.
        let p1 = String(promptMarker.prefix(10))
        let p2 = String(promptMarker.dropFirst(10))
        let s1 = String(startMarker.prefix(10))
        let s2 = String(startMarker.dropFirst(10))
        let initScript = "unsetopt prompt_cr prompt_sp; setopt chase_links; __sm='\(s1)''\(s2)'; __m='\(p1)''\(p2)'; __ad_preexec() { print -n \"\\n${__sm}\\n\"; }; __ad_precmd() { print -n \"\\n${__m}:$?:$(pwd -P)\\n\"; }; typeset -ga preexec_functions; preexec_functions+=(__ad_preexec); typeset -ga precmd_functions; precmd_functions+=(__ad_precmd); PROMPT=\"\"; PS1=\"\"; PS2=\"\"; PS3=\"\"\n"
        // Wrap in a compound block { ... } so zsh executes the entire bootstrap
        // as a single unit and fires precmd promptMarker exactly once when ready.
        let fullInit = "{\n" + initScript + TerminalShellIntegration.zshBootstrapScript + "\n}\n"
        persistentSession.sendInput(fullInit)
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
            commandSubmitted.send()
            return
        }

        commandSubmitted.send()

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
        self.hasEncounteredStartMarker = false

        sendShellCommand(trimmed)
    }

    private func sendShellCommand(_ command: String) {
        if command.contains("\n") {
            // Group multiline commands in a compound block so zsh executes all lines
            // together in the current shell before triggering precmd promptMarker
            let wrapped = "{\n" + command + "\n}"
            persistentSession.sendInput(wrapped + "\n")
        } else {
            persistentSession.sendInput(command + "\n")
        }
    }

    private func handleShellOutput(_ text: String) {
        if isAlternateBufferActive && !text.contains(promptMarker) {
            streamBuffer = ""
            return
        }
        streamBuffer.append(text)

        // If a command is actively running and we haven't stripped the pre-execution echo yet,
        // search for startMarker to strip all line-editing echo and terminal noise emitted before the command starts.
        if activeBlockId != nil && !hasEncounteredStartMarker {
            if let startRange = streamBuffer.range(of: startMarker) {
                hasEncounteredStartMarker = true
                var rest = streamBuffer[startRange.upperBound...]
                if rest.hasPrefix("\r\n") || rest.hasPrefix("\n") || rest.hasPrefix("\r") {
                    rest.removeFirst()
                }
                streamBuffer = String(rest)
            }
        }

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
                self.hasEncounteredStartMarker = false
                if !pendingCommands.isEmpty {
                    let next = pendingCommands.removeFirst()
                    self.isProcessRunning = true
                    self.activeBlockId = next.blockId
                    self.hasEncounteredStartMarker = false
                    sendShellCommand(next.command)
                }
                return
            }

            // Command output
            if let blockId = activeBlockId {
                var cleanOutput = outputBefore
                if let startRange = cleanOutput.range(of: startMarker) {
                    var afterStart = cleanOutput[startRange.upperBound...]
                    if afterStart.hasPrefix("\r\n") || afterStart.hasPrefix("\n") || afterStart.hasPrefix("\r") {
                        afterStart.removeFirst()
                    }
                    cleanOutput = String(afterStart)
                }
                if cleanOutput.hasSuffix("\r\n") || cleanOutput.hasSuffix("\n") || cleanOutput.hasSuffix("\r") {
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
            self.hasEncounteredStartMarker = false

            if !pendingCommands.isEmpty {
                let next = pendingCommands.removeFirst()
                self.isProcessRunning = true
                self.activeBlockId = next.blockId
                self.hasEncounteredStartMarker = false
                self.streamBuffer = ""
                sendShellCommand(next.command)
            }
            return
        }

        // If marker is not yet in streamBuffer and command is actively running:
        if isShellReady, let blockId = activeBlockId, !isAlternateBufferActive {
            if hasEncounteredStartMarker && streamBuffer.count > promptMarker.count + 8 {
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

    /// Asynchronously requests real completions from the running shell session via ZLE compadd.
    public func requestNativeCompletions(
        commandLine: String,
        completion: @escaping ([TerminalCompletionItem]) -> Void
    ) {
        guard isShellReady && !isProcessRunning else {
            completion([])
            return
        }

        completionTimeoutWorkItem?.cancel()

        shellIntegration.onCompletionsReceived = { [weak self] matches in
            DispatchQueue.main.async {
                self?.completionTimeoutWorkItem?.cancel()
                self?.completionTimeoutWorkItem = nil
                self?.shellIntegration.onCompletionsReceived = nil

                var items: [TerminalCompletionItem] = []
                for m in matches {
                    let kind: TerminalCompletionItem.Kind
                    if m.hasPrefix("-") {
                        kind = .flag
                    } else if m.hasSuffix("/") {
                        kind = .directory
                    } else {
                        kind = .subcommand
                    }

                    let insertText = m.hasSuffix("/") ? m : (m + " ")
                    items.append(TerminalCompletionItem(
                        label: m,
                        insertText: insertText,
                        kind: kind,
                        detail: "shell"
                    ))
                    if items.count >= 5 { break }
                }
                completion(items)
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.completionTimeoutWorkItem = nil
            self?.shellIntegration.onCompletionsReceived = nil
            completion([])
        }
        completionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: timeout)

        let escaped = commandLine
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        persistentSession.sendInput("anydiff_complete \"\(escaped)\"\n")
    }
}
