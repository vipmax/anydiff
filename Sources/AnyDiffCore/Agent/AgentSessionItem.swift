import Foundation
import Combine

public final class AgentSessionItem: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: UUID
    @Published public var title: String
    public let createdAt: Date
    public let manager: AgentSessionManager
    public let isMock: Bool
    public let preset: AgentPreset
    @Published public var hasUnreadUpdates: Bool = false
    public var isCurrentlyActive: Bool = false {
        didSet {
            if isCurrentlyActive {
                markAsRead()
            }
        }
    }

    public var isNotificationsEnabled: Bool {
        get { manager.isNotificationsEnabled }
        set { manager.isNotificationsEnabled = newValue }
    }

    public var draftPrompt: String {
        get { manager.draftPrompt }
        set { manager.draftPrompt = newValue }
    }

    public var draftBlocks: [PromptBlock] {
        get { manager.draftBlocks }
        set { manager.draftBlocks = newValue }
    }

    public var draftAttachments: [AgentImageAttachment] {
        get { manager.draftAttachments }
        set { manager.draftAttachments = newValue }
    }

    private var cancellables = Set<AnyCancellable>()
    private var lastSeenMessageCount: Int = 0

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = Date(),
        manager: AgentSessionManager,
        isMock: Bool,
        preset: AgentPreset = .codex
    ) {
        self.id = id
        self.createdAt = createdAt
        self.manager = manager
        self.isMock = isMock
        self.preset = preset
        let rawTitle = title ?? (isMock ? "Mock Session" : "New Session")
        let cleanTitle = rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.title = cleanTitle.isEmpty ? (isMock ? "Mock Session" : "New Session") : cleanTitle
        self.lastSeenMessageCount = manager.messages.count

        manager.$isNotificationsEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        manager.$currentSessionId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        manager.$workingDirectory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        manager.$pendingNewWorktree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        var previousStatus = manager.status
        manager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                guard let self = self else { return }
                if previousStatus == .busy && newStatus == .idle {
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffAgentSessionTurnCompleted"),
                        object: self,
                        userInfo: ["isError": false]
                    )
                } else if case .error = newStatus, previousStatus == .busy {
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffAgentSessionTurnCompleted"),
                        object: self,
                        userInfo: ["isError": true]
                    )
                }
                previousStatus = newStatus
            }
            .store(in: &cancellables)

        var previousPermissionId: JSONRPCID? = nil
        manager.$pendingPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] permission in
                guard let self = self else { return }
                if let perm = permission, previousPermissionId != perm.requestId {
                    if !self.isCurrentlyActive {
                        self.hasUnreadUpdates = true
                    }
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffAgentPermissionRequested"),
                        object: self,
                        userInfo: ["title": perm.title]
                    )
                }
                previousPermissionId = permission?.requestId
            }
            .store(in: &cancellables)

        // Auto-update session title and unread state when messages arrive
        manager.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                guard let self = self else { return }

                // 1. Auto-update title from first user message
                if self.isPlaceholderTitle,
                   let firstUserMsg = messages.first(where: { $0.role == .user }),
                   let autoTitle = Self.autoTitle(from: firstUserMsg.content) {
                    self.title = autoTitle
                }

                // 2. Track unread updates when message comes while session is in background
                if self.isCurrentlyActive {
                    self.lastSeenMessageCount = messages.count
                    self.hasUnreadUpdates = false
                } else if messages.count > self.lastSeenMessageCount {
                    // Check if there is an assistant response with content
                    if messages.contains(where: { $0.role == .assistant && (!$0.content.isEmpty || !$0.toolCalls.isEmpty) }) {
                        self.hasUnreadUpdates = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    public static let maxAutoTitleLength = 160

    private var isPlaceholderTitle: Bool {
        title.starts(with: "New Session")
            || title.starts(with: "Session ")
            || title.contains("Session ")
            || title == "Mock Session"
    }

    private static func autoTitle(from content: String) -> String? {
        var start = content.startIndex
        let end = content.endIndex
        while start < end {
            let lineEnd = content[start...].firstIndex(where: \.isNewline) ?? end
            let line = trimWhitespace(content[start..<lineEnd])
            if !line.isEmpty {
                if line.count > maxAutoTitleLength {
                    return String(line.prefix(maxAutoTitleLength)) + "…"
                }
                return String(line)
            }
            if lineEnd == end { break }
            start = content.index(after: lineEnd)
        }
        return nil
    }

    private static func trimWhitespace(_ slice: Substring) -> Substring {
        var trimmed = slice
        while let first = trimmed.first, first.isWhitespace || first.isNewline {
            trimmed = trimmed.dropFirst()
        }
        while let last = trimmed.last, last.isWhitespace || last.isNewline {
            trimmed = trimmed.dropLast()
        }
        return trimmed
    }

    public func markAsRead() {
        self.lastSeenMessageCount = manager.messages.count
        self.hasUnreadUpdates = false
    }

    public var sessionId: String? {
        manager.currentSessionId
    }

    public var displaySessionId: String? {
        if let id = manager.currentSessionId, !id.isEmpty {
            return id
        }
        if isMock {
            return "mock-1"
        }
        return nil
    }

    public var shortSessionId: String? {
        guard let id = displaySessionId else { return nil }
        if id.count > 8 {
            return String(id.prefix(8))
        }
        return id
    }

    public func worktreeDisplayTitle(
        fallbackWorkingDirectory: String? = nil,
        worktrees: [GitWorktree] = []
    ) -> String? {
        if manager.pendingNewWorktree {
            return "New worktree"
        }
        let dir: String
        if let d = manager.workingDirectory, !d.isEmpty {
            dir = d
        } else if let fallback = fallbackWorkingDirectory, !fallback.isEmpty {
            dir = fallback
        } else {
            return nil
        }
        return GitService.shared.nonMainWorktreeDisplayTitle(
            at: dir,
            worktrees: worktrees
        )
    }

    public func worktreePath(fallbackWorkingDirectory: String? = nil) -> String? {
        if let d = manager.workingDirectory, !d.isEmpty {
            return d
        }
        return fallbackWorkingDirectory
    }

    public var statusDescription: String {
        if manager.pendingPermission != nil {
            return "Permission required"
        }
        switch manager.status {
        case .busy:
            return "Thinking…"
        case .connecting:
            return "Connecting…"
        case .error(let msg):
            return "Error: \(msg)"
        case .idle:
            return manager.messages.isEmpty ? "Empty" : "\(manager.messages.count) messages"
        case .disconnected:
            return "Disconnected"
        }
    }
}
