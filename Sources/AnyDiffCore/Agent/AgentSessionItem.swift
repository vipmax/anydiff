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
        self.title = title ?? (isMock ? "Mock Session" : "New Session")
        self.lastSeenMessageCount = manager.messages.count

        manager.$isNotificationsEnabled
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
                if let firstUserMsg = messages.first(where: { $0.role == .user }) {
                    let firstLine = firstUserMsg.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines)
                        .first ?? firstUserMsg.content
                    let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        let truncated = clean.count > 32 ? String(clean.prefix(32)) + "…" : clean
                        if self.title.starts(with: "New Session") || self.title.starts(with: "Session ") || self.title.contains("Session ") || self.title == "Mock Session" {
                            self.title = truncated
                        }
                    }
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

    public func markAsRead() {
        self.lastSeenMessageCount = manager.messages.count
        self.hasUnreadUpdates = false
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
