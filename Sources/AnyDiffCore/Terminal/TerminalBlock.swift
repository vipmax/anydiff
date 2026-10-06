import Foundation

/// Status of a terminal command block.
public enum TerminalBlockStatus: String, Codable, Sendable, Equatable {
    case running
    case success
    case failure
    case cancelled
}

/// A styled run of characters within a terminal line (supporting ANSI colors and styles).
public struct TerminalStyledSpan: Sendable, Equatable {
    public var text: String
    public var fg: TerminalColor
    public var bg: TerminalColor
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool

    public init(
        text: String,
        fg: TerminalColor = .default,
        bg: TerminalColor = .default,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

/// A single rendered line within a terminal command block output.
public struct TerminalBlockLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public var rawText: String
    public var spans: [TerminalStyledSpan]

    public init(id: Int = 0, rawText: String, spans: [TerminalStyledSpan] = []) {
        self.id = id
        self.rawText = rawText
        if spans.isEmpty && !rawText.isEmpty {
            self.spans = [TerminalStyledSpan(text: rawText)]
        } else {
            self.spans = spans
        }
    }
}

/// Represents an individual command execution block in the TerminalMultiBuffer.
public final class TerminalBlock: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: UUID
    public let command: String
    public let workingDirectory: String
    public let gitBranch: String?
    public let startTime: Date

    @Published public var endTime: Date?
    @Published public var exitCode: Int32?
    @Published public var status: TerminalBlockStatus
    @Published public var lines: [TerminalBlockLine]
    @Published public var isCollapsed: Bool
    @Published public var interactiveSession: TerminalSession?
    @Published public var isAlternateBuffer: Bool

    public init(
        id: UUID = UUID(),
        command: String,
        workingDirectory: String,
        gitBranch: String? = nil,
        startTime: Date = Date(),
        endTime: Date? = nil,
        exitCode: Int32? = nil,
        status: TerminalBlockStatus = .running,
        lines: [TerminalBlockLine] = [],
        isCollapsed: Bool = false,
        interactiveSession: TerminalSession? = nil,
        isAlternateBuffer: Bool = false
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
        self.startTime = startTime
        self.endTime = endTime
        self.exitCode = exitCode
        self.status = status
        self.lines = lines
        self.isCollapsed = isCollapsed
        self.interactiveSession = interactiveSession
        self.isAlternateBuffer = isAlternateBuffer
    }

    /// Formatted elapsed duration string (e.g. "1.4s" or "45ms").
    public var durationString: String {
        let end = endTime ?? Date()
        let elapsed = max(0, end.timeIntervalSince(startTime))
        if elapsed < 1.0 {
            return String(format: "%dms", Int(elapsed * 1000))
        } else if elapsed < 60.0 {
            return String(format: "%.1fs", elapsed)
        } else {
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            return String(format: "%dm %ds", mins, secs)
        }
    }

    /// Short display name for the working directory (e.g. folder name or "~").
    public var folderDisplayName: String {
        let home = NSHomeDirectory()
        if workingDirectory == home {
            return "~"
        }
        let folder = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return folder.isEmpty ? workingDirectory : folder
    }
}
