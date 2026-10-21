import Foundation
import Combine

/// Container managing all terminal command blocks, streaming output decoding, and ANSI styling.
public final class TerminalMultiBuffer: ObservableObject, @unchecked Sendable {
    @Published public private(set) var blocks: [TerminalBlock] = []
    @Published public private(set) var activeBlockId: UUID? = nil
    @Published public private(set) var version: UInt64 = 0

    // Partial line buffer for streaming output
    private var pendingLineRemainder: String = ""
    private var currentFg: TerminalColor = .default
    private var currentBg: TerminalColor = .default
    private var currentBold: Bool = false
    private var currentItalic: Bool = false
    private var currentUnderline: Bool = false

    public init() {}

    /// Creates and registers a new command block, making it the active block.
    @discardableResult
    public func createBlock(
        command: String,
        workingDirectory: String,
        gitBranch: String? = nil,
        interactiveSession: TerminalSession? = nil
    ) -> TerminalBlock {
        // Reset state for new command
        pendingLineRemainder = ""
        resetStyles()

        let block = TerminalBlock(
            command: command,
            workingDirectory: workingDirectory,
            gitBranch: gitBranch,
            startTime: Date(),
            status: .running,
            interactiveSession: interactiveSession
        )
        blocks.append(block)
        activeBlockId = block.id
        version &+= 1
        return block
    }

    /// Appends incoming streaming output to the specified block (or active block).
    public func appendOutput(to blockId: UUID? = nil, text: String) {
        guard let targetId = blockId ?? activeBlockId,
              let block = blocks.first(where: { $0.id == targetId }) else { return }

        guard !text.isEmpty else { return }

        // Combine with pending remainder from previous chunk
        let combined = pendingLineRemainder + text
        pendingLineRemainder = ""

        var currentLineChars = ""
        currentLineChars.reserveCapacity(256)
        var currentSpans: [TerminalStyledSpan] = []
        var newLines: [TerminalBlockLine] = []
        var lineIndex = block.lines.count

        func flushSpan() {
            if !currentLineChars.isEmpty {
                currentSpans.append(TerminalStyledSpan(
                    text: currentLineChars,
                    fg: currentFg,
                    bg: currentBg,
                    bold: currentBold,
                    italic: currentItalic,
                    underline: currentUnderline
                ))
                currentLineChars = ""
            }
        }

        var currentLineCol = 0

        func flushLine() {
            flushSpan()
            let raw = currentSpans.map { $0.text }.joined()
            let line = TerminalBlockLine(id: lineIndex, rawText: raw, spans: currentSpans)
            lineIndex &+= 1
            newLines.append(line)
            currentSpans = []
            currentLineCol = 0
        }

        var i = combined.startIndex
        while i < combined.endIndex {
            let ch = combined[i]

            if ch == "\t" {
                // Expand tab to standard 8-column monospace tab stops
                let spaces = 8 - (currentLineCol % 8)
                currentLineChars.append(String(repeating: " ", count: spaces))
                currentLineCol += spaces
                i = combined.index(after: i)
                continue
            }

            if ch == "\r\n" || ch == "\n" {
                flushLine()
                i = combined.index(after: i)
                continue
            }

            if ch == "\r" {
                // Progress bar / spinner overwrite on the current line
                flushSpan()
                let raw = currentSpans.map { $0.text }.joined()
                if !raw.isEmpty {
                    let line = TerminalBlockLine(id: lineIndex, rawText: raw, spans: currentSpans)
                    if !newLines.isEmpty {
                        newLines[newLines.count - 1] = line
                    } else if !block.lines.isEmpty {
                        block.lines[block.lines.count - 1] = line
                    } else {
                        newLines.append(line)
                        lineIndex &+= 1
                    }
                }
                currentSpans = []
                currentLineCol = 0
                i = combined.index(after: i)
                continue
            } else if ch == "\u{1B}" {
                // Parse ANSI Escape Sequence
                let nextIdx = combined.index(after: i)
                if nextIdx < combined.endIndex && combined[nextIdx] == "[" {
                    // CSI sequence
                    var scan = combined.index(after: nextIdx)
                    var paramStr = ""
                    var terminated = false
                    while scan < combined.endIndex {
                        let c = combined[scan]
                        if (c >= "0" && c <= "9") || c == ";" || c == "?" {
                            paramStr.append(c)
                            scan = combined.index(after: scan)
                        } else {
                            // Final command byte (e.g. 'm' for SGR, 'K' for erase, etc.)
                            flushSpan()
                            if c == "m" {
                                applySGR(paramStr)
                            } else if c == "K" {
                                if paramStr == "2" {
                                    currentSpans = []
                                    currentLineChars = ""
                                    currentLineCol = 0
                                }
                            }
                            scan = combined.index(after: scan)
                            terminated = true
                            break
                        }
                    }
                    if terminated {
                        i = scan
                        continue
                    }
                }
            }

            currentLineChars.append(ch)
            currentLineCol += 1
            i = combined.index(after: i)
        }

        // Remaining un-terminated line (e.g. streaming tokens from codex)
        flushSpan()
        if !currentSpans.isEmpty {
            let raw = currentSpans.map { $0.text }.joined()
            pendingLineRemainder = raw
        }

        if !newLines.isEmpty {
            block.lines.append(contentsOf: newLines)
            if block.lines.count > 10_000 {
                block.lines.removeFirst(block.lines.count - 10_000)
            }
        }

        version &+= 1
    }

    /// Marks the active command block as completed.
    public func completeBlock(id: UUID? = nil, exitCode: Int32) {
        guard let targetId = id ?? activeBlockId,
              let block = blocks.first(where: { $0.id == targetId }) else { return }

        // Flush any remaining partial line
        if !pendingLineRemainder.isEmpty {
            let splitLines = pendingLineRemainder.components(separatedBy: "\n")
            for (idx, sub) in splitLines.enumerated() {
                let trimmed = sub.hasSuffix("\r") ? String(sub.dropLast()) : sub
                if !trimmed.isEmpty || idx < splitLines.count - 1 {
                    block.lines.append(TerminalBlockLine(id: block.lines.count, rawText: trimmed))
                }
            }
            pendingLineRemainder = ""
        }

        block.endTime = Date()
        block.exitCode = exitCode
        block.status = (exitCode == 0) ? .success : .failure

        if activeBlockId == targetId {
            activeBlockId = nil
        }
        version &+= 1
    }

    /// Cancels the specified block (e.g. on Ctrl+C).
    public func cancelBlock(id: UUID? = nil) {
        guard let targetId = id ?? activeBlockId,
              let block = blocks.first(where: { $0.id == targetId }) else { return }

        if !pendingLineRemainder.isEmpty {
            let splitLines = pendingLineRemainder.components(separatedBy: "\n")
            for (idx, sub) in splitLines.enumerated() {
                let trimmed = sub.hasSuffix("\r") ? String(sub.dropLast()) : sub
                if !trimmed.isEmpty || idx < splitLines.count - 1 {
                    block.lines.append(TerminalBlockLine(id: block.lines.count, rawText: trimmed))
                }
            }
            pendingLineRemainder = ""
        }

        block.endTime = Date()
        block.exitCode = 130
        block.status = .cancelled

        if activeBlockId == targetId {
            activeBlockId = nil
        }
        version &+= 1
    }

    /// Toggles the collapsed state of a command block.
    public func toggleCollapse(id: UUID) {
        if let block = blocks.first(where: { $0.id == id }) {
            block.isCollapsed.toggle()
            version &+= 1
        }
    }

    /// Clears all blocks from the multi-buffer.
    public func clear() {
        blocks.removeAll()
        activeBlockId = nil
        pendingLineRemainder = ""
        resetStyles()
        version &+= 1
    }

    private func resetStyles() {
        currentFg = .default
        currentBg = .default
        currentBold = false
        currentItalic = false
        currentUnderline = false
    }

    private func applySGR(_ params: String) {
        if params.isEmpty || params == "0" {
            resetStyles()
            return
        }

        let parts = params.split(separator: ";").compactMap { Int($0) }
        var idx = 0
        while idx < parts.count {
            let code = parts[idx]
            switch code {
            case 0:
                resetStyles()
            case 1:
                currentBold = true
            case 3:
                currentItalic = true
            case 4:
                currentUnderline = true
            case 22:
                currentBold = false
            case 23:
                currentItalic = false
            case 24:
                currentUnderline = false
            case 30...37:
                currentFg = .standard(UInt8(code - 30))
            case 39:
                currentFg = .default
            case 40...47:
                currentBg = .standard(UInt8(code - 40))
            case 49:
                currentBg = .default
            case 90...97:
                currentFg = .standard(UInt8(code - 90 + 8))
            case 100...107:
                currentBg = .standard(UInt8(code - 100 + 8))
            case 38:
                // Extended foreground (256 color or truecolor)
                if idx + 2 < parts.count && parts[idx + 1] == 5 {
                    currentFg = .palette256(UInt8(clamping: parts[idx + 2]))
                    idx += 2
                } else if idx + 4 < parts.count && parts[idx + 1] == 2 {
                    currentFg = .trueColor(
                        red: UInt8(clamping: parts[idx + 2]),
                        green: UInt8(clamping: parts[idx + 3]),
                        blue: UInt8(clamping: parts[idx + 4])
                    )
                    idx += 4
                }
            case 48:
                // Extended background
                if idx + 2 < parts.count && parts[idx + 1] == 5 {
                    currentBg = .palette256(UInt8(clamping: parts[idx + 2]))
                    idx += 2
                } else if idx + 4 < parts.count && parts[idx + 1] == 2 {
                    currentBg = .trueColor(
                        red: UInt8(clamping: parts[idx + 2]),
                        green: UInt8(clamping: parts[idx + 3]),
                        blue: UInt8(clamping: parts[idx + 4])
                    )
                    idx += 4
                }
            default:
                break
            }
            idx += 1
        }
    }
}
