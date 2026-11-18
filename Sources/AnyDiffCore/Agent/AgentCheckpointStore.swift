import CryptoKit
import Foundation

public struct PersistedMessageCheckpoint: Codable, Equatable, Sendable {
    public let userIndex: Int
    public let contentHash: String
    public let snapshot: PreTurnGitSnapshot

    public init(userIndex: Int, contentHash: String, snapshot: PreTurnGitSnapshot) {
        self.userIndex = userIndex
        self.contentHash = contentHash
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case userIndex
        case contentHash
        case content
        case snapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.userIndex = try container.decode(Int.self, forKey: .userIndex)
        self.snapshot = try container.decode(PreTurnGitSnapshot.self, forKey: .snapshot)
        if let hash = try container.decodeIfPresent(String.self, forKey: .contentHash) {
            self.contentHash = hash
        } else if let legacyContent = try container.decodeIfPresent(String.self, forKey: .content) {
            self.contentHash = AgentCheckpointStore.contentHash(legacyContent)
        } else {
            self.contentHash = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userIndex, forKey: .userIndex)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(snapshot, forKey: .snapshot)
    }
}

public struct PersistedEditedFilesSummary: Codable, Equatable, Sendable {
    public let assistantIndex: Int
    public let contentHash: String
    public let summary: AgentEditedFilesSummary

    public init(assistantIndex: Int, contentHash: String, summary: AgentEditedFilesSummary) {
        self.assistantIndex = assistantIndex
        self.contentHash = contentHash
        self.summary = summary
    }
}

public struct PersistedSessionCheckpoints: Codable, Equatable, Sendable {
    public let userCheckpoints: [PersistedMessageCheckpoint]
    public let editedSummaries: [PersistedEditedFilesSummary]

    public init(
        userCheckpoints: [PersistedMessageCheckpoint] = [],
        editedSummaries: [PersistedEditedFilesSummary] = []
    ) {
        self.userCheckpoints = userCheckpoints
        self.editedSummaries = editedSummaries
    }
}

/// Persists user-message git checkpoints and assistant edited-files cards keyed by ACP session ID
/// so resumed sessions retain "Restore Checkpoint" and "Edited X files" cards across reconnects
/// and app restarts.
public final class AgentCheckpointStore: @unchecked Sendable {
    public static let shared = AgentCheckpointStore()

    public let directory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.anydiff.checkpoint-store", attributes: .concurrent)
    private var memoryCache: [String: PersistedSessionCheckpoints] = [:]

    public init(customDirectory: URL? = nil) {
        if let customDirectory {
            self.directory = customDirectory
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".anydiff", isDirectory: true)
                .appendingPathComponent("checkpoints", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func normalizedContent(_ text: String) -> String {
        AgentImageAttachment
            .removingInlineTextMarkers(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func contentHash(_ text: String) -> String {
        let normalized = normalizedContent(text)
        guard !normalized.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func save(messages: [AgentMessage], forSessionId sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var userEntries: [PersistedMessageCheckpoint] = []
        var assistantEntries: [PersistedEditedFilesSummary] = []
        var userIndex = 0
        var assistantIndex = 0

        for message in messages {
            if message.role == .user && !message.isQueued {
                if let snapshot = message.checkpointSnapshot, snapshot.isGitRepository {
                    userEntries.append(PersistedMessageCheckpoint(
                        userIndex: userIndex,
                        contentHash: Self.contentHash(message.content),
                        snapshot: snapshot
                    ))
                }
                userIndex += 1
            } else if message.role == .assistant {
                if let summary = message.editedFilesSummary {
                    assistantEntries.append(PersistedEditedFilesSummary(
                        assistantIndex: assistantIndex,
                        contentHash: Self.contentHash(message.content),
                        summary: summary
                    ))
                }
                assistantIndex += 1
            }
        }

        guard !userEntries.isEmpty || !assistantEntries.isEmpty else { return }
        let payload = PersistedSessionCheckpoints(
            userCheckpoints: userEntries,
            editedSummaries: assistantEntries
        )
        let fileURL = fileURL(forSessionId: sessionId)
        queue.async(flags: .barrier) {
            if self.memoryCache[sessionId] == payload {
                return
            }
            self.memoryCache[sessionId] = payload
            try? self.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func load(forSessionId sessionId: String) -> [PersistedMessageCheckpoint] {
        loadSessionData(forSessionId: sessionId).userCheckpoints
    }

    public func loadSessionData(forSessionId sessionId: String) -> PersistedSessionCheckpoints {
        guard !sessionId.isEmpty else { return PersistedSessionCheckpoints() }
        if let cached = queue.sync(execute: { memoryCache[sessionId] }) {
            return cached
        }
        let fileURL = fileURL(forSessionId: sessionId)
        return queue.sync(flags: .barrier) {
            if let cached = self.memoryCache[sessionId] {
                return cached
            }
            let decoded: PersistedSessionCheckpoints
            if let data = try? Data(contentsOf: fileURL) {
                if let sessionData = try? JSONDecoder().decode(PersistedSessionCheckpoints.self, from: data) {
                    decoded = sessionData
                } else if let legacy = try? JSONDecoder().decode([PersistedMessageCheckpoint].self, from: data) {
                    decoded = PersistedSessionCheckpoints(userCheckpoints: legacy)
                } else {
                    decoded = PersistedSessionCheckpoints()
                }
            } else {
                decoded = PersistedSessionCheckpoints()
            }
            self.memoryCache[sessionId] = decoded
            return decoded
        }
    }

    public func restore(into messages: inout [AgentMessage], forSessionId sessionId: String) {
        let saved = loadSessionData(forSessionId: sessionId)
        guard !saved.userCheckpoints.isEmpty || !saved.editedSummaries.isEmpty else { return }
        if !saved.userCheckpoints.isEmpty {
            restoreUserCheckpoints(saved.userCheckpoints, into: &messages)
        }
        if !saved.editedSummaries.isEmpty {
            restoreEditedSummaries(saved.editedSummaries, into: &messages)
        }
    }

    private func restoreUserCheckpoints(_ saved: [PersistedMessageCheckpoint], into messages: inout [AgentMessage]) {
        var userItems: [(msgIndex: Int, userIndex: Int, contentHash: String)] = []
        var userIdx = 0
        for (idx, msg) in messages.enumerated() where msg.role == .user && !msg.isQueued {
            userItems.append((msgIndex: idx, userIndex: userIdx, contentHash: Self.contentHash(msg.content)))
            userIdx += 1
        }
        guard !userItems.isEmpty else { return }

        var usedSavedIndices = Set<Int>()
        for item in userItems {
            if let existing = messages[item.msgIndex].checkpointSnapshot,
               let sIdx = saved.firstIndex(where: { $0.userIndex == item.userIndex && $0.snapshot == existing }) {
                usedSavedIndices.insert(sIdx)
            }
        }

        // Pass 1: Exact (userIndex, contentHash) match
        for item in userItems where messages[item.msgIndex].checkpointSnapshot == nil {
            if let sIdx = saved.firstIndex(where: {
                $0.userIndex == item.userIndex && $0.contentHash == item.contentHash
            }), !usedSavedIndices.contains(sIdx) {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].checkpointSnapshot = saved[sIdx].snapshot
            }
        }

        // Pass 2: Fallback by exact non-empty contentHash or userIndex
        for item in userItems where messages[item.msgIndex].checkpointSnapshot == nil {
            if !item.contentHash.isEmpty,
               let sIdx = saved.enumerated().first(where: { !usedSavedIndices.contains($0.offset) && $0.element.contentHash == item.contentHash })?.offset {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].checkpointSnapshot = saved[sIdx].snapshot
            } else if let sIdx = saved.enumerated().first(where: { !usedSavedIndices.contains($0.offset) && $0.element.userIndex == item.userIndex })?.offset {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].checkpointSnapshot = saved[sIdx].snapshot
            }
        }
    }

    private func restoreEditedSummaries(_ saved: [PersistedEditedFilesSummary], into messages: inout [AgentMessage]) {
        var assistantItems: [(msgIndex: Int, assistantIndex: Int, contentHash: String)] = []
        var assistantIdx = 0
        for (idx, msg) in messages.enumerated() where msg.role == .assistant {
            assistantItems.append((msgIndex: idx, assistantIndex: assistantIdx, contentHash: Self.contentHash(msg.content)))
            assistantIdx += 1
        }
        guard !assistantItems.isEmpty else { return }

        var usedSavedIndices = Set<Int>()
        for item in assistantItems {
            if let existing = messages[item.msgIndex].editedFilesSummary,
               let sIdx = saved.firstIndex(where: { $0.assistantIndex == item.assistantIndex && $0.summary == existing }) {
                usedSavedIndices.insert(sIdx)
            }
        }

        // Pass 1: Exact (assistantIndex, contentHash) match
        for item in assistantItems where messages[item.msgIndex].editedFilesSummary == nil {
            if let sIdx = saved.firstIndex(where: {
                $0.assistantIndex == item.assistantIndex && $0.contentHash == item.contentHash
            }), !usedSavedIndices.contains(sIdx) {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].editedFilesSummary = saved[sIdx].summary
            }
        }

        // Pass 2: Fallback by exact non-empty contentHash or assistantIndex
        for item in assistantItems where messages[item.msgIndex].editedFilesSummary == nil {
            if !item.contentHash.isEmpty,
               let sIdx = saved.enumerated().first(where: { !usedSavedIndices.contains($0.offset) && $0.element.contentHash == item.contentHash })?.offset {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].editedFilesSummary = saved[sIdx].summary
            } else if let sIdx = saved.enumerated().first(where: { !usedSavedIndices.contains($0.offset) && $0.element.assistantIndex == item.assistantIndex })?.offset {
                usedSavedIndices.insert(sIdx)
                messages[item.msgIndex].editedFilesSummary = saved[sIdx].summary
            }
        }
    }

    /// Synchronously flushes pending async writes (useful in unit tests).
    public func flushSync() {
        queue.sync(flags: .barrier) {}
    }

    private func fileURL(forSessionId sessionId: String) -> URL {
        let encoded = Data(sessionId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(encoded).json")
    }
}
