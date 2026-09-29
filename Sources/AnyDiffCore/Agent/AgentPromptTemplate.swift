import Foundation
import Combine

/// A customizable message/prompt template for AI agent interactions.
public struct AgentPromptTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var prompt: String

    public init(
        id: String = UUID().uuidString,
        title: String,
        prompt: String
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

/// Direction for moving a prompt template in the ordered list.
public enum TemplateMoveDirection: Sendable {
    case up
    case down
}

/// Persistent store managing customizable agent prompt templates.
public final class AgentPromptTemplateStore: ObservableObject, @unchecked Sendable {
    public static let shared = AgentPromptTemplateStore()

    public static let defaultTemplates: [AgentPromptTemplate] = [
        AgentPromptTemplate(
            id: "explain-diff",
            title: "Explain current diff",
            prompt: "Explain the current git diff and summarize the main changes."
        ),
        AgentPromptTemplate(
            id: "review-bugs",
            title: "Review changes for bugs",
            prompt: "Review these changes carefully and highlight any potential bugs, logic issues, or edge cases."
        ),
        AgentPromptTemplate(
            id: "gen-commit",
            title: "Generate commit message",
            prompt: "Generate a concise, conventional git commit message for these changes."
        ),
        AgentPromptTemplate(
            id: "commit-push",
            title: "Commit and push",
            prompt: "Commit the current changes with an appropriate conventional commit message and push the commit to the configured remote."
        )
    ]

    private let userDefaults: UserDefaults
    private let storageKey: String

    @Published public private(set) var templates: [AgentPromptTemplate] = []

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "anydiff_agent_prompt_templates"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.templates = loadTemplates()
    }

    public func loadTemplates() -> [AgentPromptTemplate] {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return Self.defaultTemplates
        }
        do {
            let decoded = try JSONDecoder().decode([AgentPromptTemplate].self, from: data)
            return decoded
        } catch {
            return Self.defaultTemplates
        }
    }

    public func saveTemplates() {
        do {
            let data = try JSONEncoder().encode(templates)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            // Keep existing storage on encoding error
        }
    }

    @discardableResult
    public func addTemplate(
        title: String,
        prompt: String
    ) -> AgentPromptTemplate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedPrompt.isEmpty else {
            return nil
        }
        let template = AgentPromptTemplate(
            title: trimmedTitle,
            prompt: trimmedPrompt
        )
        templates.append(template)
        saveTemplates()
        return template
    }

    public func updateTemplate(
        id: String,
        title: String,
        prompt: String
    ) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedPrompt.isEmpty else { return }

        templates[index].title = trimmedTitle
        templates[index].prompt = trimmedPrompt
        saveTemplates()
    }

    public func deleteTemplate(id: String) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates.remove(at: index)
        saveTemplates()
    }

    public func moveTemplate(id: String, direction: TemplateMoveDirection) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        switch direction {
        case .up:
            guard index > 0 else { return }
            templates.swapAt(index, index - 1)
        case .down:
            guard index < templates.count - 1 else { return }
            templates.swapAt(index, index + 1)
        }
        saveTemplates()
    }

    public func moveTemplate(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty, destination >= 0, destination <= templates.count else { return }
        var result = templates
        let movingItems = source.map { result[$0] }
        for index in source.reversed() {
            result.remove(at: index)
        }
        let insertIndex = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: movingItems, at: insertIndex)
        templates = result
        saveTemplates()
    }

    public func resetToDefaults() {
        templates = Self.defaultTemplates
        saveTemplates()
    }
}
