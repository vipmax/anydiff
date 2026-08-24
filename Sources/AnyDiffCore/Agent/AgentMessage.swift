import Foundation

public enum AgentRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public enum ToolCallStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
}

/// The order in which visible assistant output arrived.
///
/// Tool-call details are updated in place by their identifier, so a result
/// never moves the tool card from the position where the call first arrived.
public enum AgentMessagePart: Sendable, Equatable {
    case text(String)
    case thought(String)
    case toolCall(String)
}

public struct ToolCallItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var toolName: String
    public var path: String?
    public var title: String?
    public var descriptionText: String?
    public var startLine: Int?
    public var endLine: Int?
    public var oldContent: String?
    public var newContent: String?
    public var command: String?
    public var output: String?
    public var summary: String?
    public var status: ToolCallStatus
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        toolName: String,
        path: String? = nil,
        title: String? = nil,
        descriptionText: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        command: String? = nil,
        output: String? = nil,
        summary: String? = nil,
        status: ToolCallStatus = .running,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.path = path
        self.title = title
        self.descriptionText = descriptionText
        self.startLine = startLine
        self.endLine = endLine
        self.oldContent = oldContent
        self.newContent = newContent
        self.command = command
        self.output = output
        self.summary = summary
        self.status = status
        self.timestamp = timestamp
    }

    public var shortToolName: String {
        let lower = toolName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let commandToolNames = [
            "just", "make", "xcodebuild", "swift", "swiftc", "cargo", "npm",
            "pnpm", "yarn", "git", "rg", "grep", "find", "bash", "sh", "zsh",
            "python", "python3"
        ]
        if lower == "run_command" || lower == "bash" || lower == "terminal" || lower.starts(with: "terminal/") || lower == "command" || lower == "exec" || lower == "execute_command" || commandToolNames.contains(lower) || lower.starts(with: "git ") || lower.starts(with: "cargo ") || lower.starts(with: "swift ") || lower.starts(with: "npm ") || lower.contains("&&") || lower.contains("|") || lower.contains("--") || command != nil {
            return "Run"
        }
        if lower.contains("edit") || lower.contains("patch") || lower.contains("replace") || lower == "fs/write_text_file" {
            return "Edit"
        }
        if lower.contains("create") || lower.contains("write") {
            return "Create"
        }
        if lower.contains("read") || lower.contains("view") || lower == "fs/read_text_file" {
            return "Read"
        }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") || lower.contains("glob") {
            return "Search"
        }
        if lower == "tool" {
            if let cmd = command, !cmd.isEmpty { return "Run" }
            if let path = path, !path.isEmpty { return "File" }
            return "Run"
        }
        return toolName
    }

    public var diffStats: (additions: Int, deletions: Int)? {
        guard let new = newContent else {
            if let old = oldContent, !old.isEmpty {
                return (0, old.components(separatedBy: "\n").count)
            }
            if shortToolName == "Edit", let s = startLine, let e = endLine, e >= s {
                return (0, e - s + 1)
            }
            return nil
        }
        guard let old = oldContent else {
            return (new.components(separatedBy: "\n").count, 0)
        }
        if toolName == "fs/write_text_file" || old.count > 500 || new.count > 500 {
            let oLines = old.components(separatedBy: "\n")
            let nLines = new.components(separatedBy: "\n")
            let diff = LineDiffEngine.shared.diffLines(oldLines: oLines, newLines: nLines)
            let adds = diff.filter { $0.kind == .added }.count
            let dels = diff.filter { $0.kind == .deleted }.count
            return (adds, dels)
        }
        return (new.components(separatedBy: "\n").count, old.components(separatedBy: "\n").count)
    }

    public var additionsCount: Int? {
        diffStats?.additions
    }

    public var deletionsCount: Int? {
        diffStats?.deletions
    }

    public var displayTitle: String {
        if let cmd = command, !cmd.isEmpty {
            return cmd
        }
        if shortToolName == "Run" && (toolName.starts(with: "git ") || toolName.contains(" ") || toolName.contains("-") || ["just", "make", "xcodebuild", "swift", "swiftc", "cargo", "npm", "pnpm", "yarn", "rg", "grep", "find", "bash", "sh", "zsh", "python", "python3"].contains(toolName.lowercased())) {
            return toolName
        }
        if let p = path, !p.isEmpty {
            return (p as NSString).lastPathComponent
        }
        if let t = title,
           !t.isEmpty,
           t != toolName,
           !(shortToolName == "Run" && t.lowercased().hasPrefix("exit_code:")) {
            return t
        }
        if let desc = descriptionText, !desc.isEmpty {
            return desc
        }
        if let sum = summary, !sum.isEmpty {
            let firstLine = sum.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? sum
            return String(firstLine.prefix(160))
        }
        if shortToolName == "Run" {
            return toolName
        }
        return toolName == "tool" ? "command" : toolName
    }

    public func createEditedFilesSummary() -> AgentEditedFilesSummary? {
        guard let p = path ?? (shortToolName == "Edit" ? (displayTitle.isEmpty ? nil : displayTitle) : nil), !p.isEmpty else {
            return nil
        }
        let adds = additionsCount ?? 0
        let dels = deletionsCount ?? 0
        let item = AgentEditedFileItem(path: p, additions: adds, deletions: dels)

        var rawData: Data? = nil
        if let old = oldContent, let new = newContent {
            let oLines = old.components(separatedBy: "\n")
            let nLines = new.components(separatedBy: "\n")
            let diff = LineDiffEngine.shared.diffLines(oldLines: oLines, newLines: nLines)
            let changedDiff = diff.filter { $0.kind != .unchanged }
            if !changedDiff.isEmpty {
                var diffStr = "diff --git a/\(p) b/\(p)\n"
                diffStr += "--- a/\(p)\n"
                diffStr += "+++ b/\(p)\n"
                diffStr += "@@ -1,\(max(1, dels)) +1,\(max(1, adds)) @@\n"
                for line in changedDiff {
                    if line.kind == .deleted {
                        diffStr += "-\(line.text)\n"
                    } else if line.kind == .added {
                        diffStr += "+\(line.text)\n"
                    }
                }
                rawData = Data(diffStr.utf8)
            }
        } else if oldContent != nil || newContent != nil {
            let oldText = oldContent ?? ""
            let newText = newContent ?? ""
            let oldLines = oldText.isEmpty ? [] : oldText.components(separatedBy: "\n")
            let newLines = newText.isEmpty ? [] : newText.components(separatedBy: "\n")

            var diffStr = "diff --git a/\(p) b/\(p)\n"
            diffStr += "--- a/\(p)\n"
            diffStr += "+++ b/\(p)\n"
            diffStr += "@@ -1,\(max(1, oldLines.count)) +1,\(max(1, newLines.count)) @@\n"
            for line in oldLines {
                diffStr += "-\(line)\n"
            }
            for line in newLines {
                diffStr += "+\(line)\n"
            }
            rawData = Data(diffStr.utf8)
        }

        return AgentEditedFilesSummary(files: [item], baseCommitHash: nil, rawDiffData: rawData)
    }
}

public struct AgentMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let role: AgentRole
    public var content: String
    public var thought: String?
    public var toolCalls: [ToolCallItem]
    public private(set) var orderedParts: [AgentMessagePart]
    public var editedFilesSummary: AgentEditedFilesSummary?
    public var isStreaming: Bool
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String = "",
        thought: String? = nil,
        toolCalls: [ToolCallItem] = [],
        orderedParts: [AgentMessagePart]? = nil,
        editedFilesSummary: AgentEditedFilesSummary? = nil,
        isStreaming: Bool = false,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thought = thought
        self.toolCalls = toolCalls
        self.orderedParts = orderedParts ?? Self.defaultParts(content: content, toolCalls: toolCalls)
        self.editedFilesSummary = editedFilesSummary
        self.isStreaming = isStreaming
        self.timestamp = timestamp
    }

    /// Appends text to the current text part, or starts a new part after a
    /// tool call. This preserves arrival order without using timestamps.
    public mutating func appendText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        content += chunk

        if case .text(let previous)? = orderedParts.last {
            orderedParts[orderedParts.index(before: orderedParts.endIndex)] = .text(previous + chunk)
        } else {
            orderedParts.append(.text(chunk))
        }
    }

    /// Appends a reasoning chunk to the current thought part, or starts a new
    /// thought part after text/tool output. Keeping this in orderedParts lets
    /// the UI render reasoning in the same order in which it arrived.
    public mutating func appendThought(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        thought = (thought ?? "") + chunk

        if case .thought(let previous)? = orderedParts.last {
            orderedParts[orderedParts.index(before: orderedParts.endIndex)] = .thought(previous + chunk)
        } else {
            orderedParts.append(.thought(chunk))
        }
    }

    public mutating func appendToolCall(_ item: ToolCallItem) {
        toolCalls.append(item)
        orderedParts.append(.toolCall(item.id))
    }

    /// Replaces the current tool snapshot while keeping the original arrival
    /// position of existing tool calls and appending newly seen ones.
    public mutating func setToolCalls(_ items: [ToolCallItem]) {
        let itemIDs = Set(items.map(\.id))
        let oldParts = orderedParts
        toolCalls = items

        var nextParts = oldParts.filter { part in
            if case .toolCall(let id) = part {
                return itemIDs.contains(id)
            }
            return true
        }
        let existingIDs = Set(nextParts.compactMap { part -> String? in
            if case .toolCall(let id) = part { return id }
            return nil
        })
        for item in items where !existingIDs.contains(item.id) {
            nextParts.append(.toolCall(item.id))
        }
        orderedParts = nextParts
    }

    public mutating func updateToolCall(id: String, _ update: (inout ToolCallItem) -> Void) -> Bool {
        guard let index = toolCalls.firstIndex(where: { $0.id == id }) else { return false }
        update(&toolCalls[index])
        return true
    }

    public mutating func updateLastRunningToolCall(_ update: (inout ToolCallItem) -> Void) -> Bool {
        guard let index = toolCalls.lastIndex(where: { $0.status == .running }) else { return false }
        update(&toolCalls[index])
        return true
    }

    public mutating func completeRunningToolCalls() {
        for index in toolCalls.indices where toolCalls[index].status == .running {
            toolCalls[index].status = .completed
        }
    }

    private static func defaultParts(content: String, toolCalls: [ToolCallItem]) -> [AgentMessagePart] {
        var parts = toolCalls.map { AgentMessagePart.toolCall($0.id) }
        if !content.isEmpty {
            parts.append(.text(content))
        }
        return parts
    }
}
