import XCTest
@testable import AnyDiffCore

final class AgentPromptTemplateTests: XCTestCase {
    private var testUserDefaults: UserDefaults!
    private var testKey: String!
    private var testSuiteName: String!

    override func setUp() {
        super.setUp()
        testKey = "test_agent_prompt_templates_\(UUID().uuidString)"
        testSuiteName = "AnyDiffTestDefaults_\(UUID().uuidString)"
        testUserDefaults = UserDefaults(suiteName: testSuiteName)!
    }

    override func tearDown() {
        testUserDefaults.removePersistentDomain(forName: testSuiteName)
        testUserDefaults = nil
        super.tearDown()
    }

    func testDefaultTemplatesLoadedWhenStorageEmpty() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        XCTAssertEqual(store.templates.count, 4)
        XCTAssertEqual(store.templates[0].id, "explain-diff")
        XCTAssertEqual(store.templates[0].title, "Explain current diff")
        XCTAssertEqual(store.templates[1].id, "review-bugs")
        XCTAssertEqual(store.templates[2].id, "gen-commit")
        XCTAssertEqual(store.templates[3].id, "commit-push")
    }

    func testAddTemplate() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        let initialCount = store.templates.count

        let created = store.addTemplate(
            title: "Write unit tests",
            prompt: "Write comprehensive unit tests for these changed files."
        )

        XCTAssertNotNil(created)
        XCTAssertEqual(store.templates.count, initialCount + 1)
        XCTAssertEqual(store.templates.last?.title, "Write unit tests")
        XCTAssertEqual(store.templates.last?.prompt, "Write comprehensive unit tests for these changed files.")

        // Verify persistence by loading in new instance
        let store2 = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        XCTAssertEqual(store2.templates.count, initialCount + 1)
        XCTAssertEqual(store2.templates.last?.title, "Write unit tests")
    }

    func testAddTemplateRejectsEmptyInputs() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        let initialCount = store.templates.count

        let result1 = store.addTemplate(title: "   ", prompt: "Some prompt")
        XCTAssertNil(result1)
        XCTAssertEqual(store.templates.count, initialCount)

        let result2 = store.addTemplate(title: "Title", prompt: "   \n  ")
        XCTAssertNil(result2)
        XCTAssertEqual(store.templates.count, initialCount)
    }

    func testUpdateTemplate() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        store.updateTemplate(
            id: "explain-diff",
            title: "Explain diff in depth",
            prompt: "Provide an in-depth breakdown of the current git diff."
        )

        XCTAssertEqual(store.templates[0].title, "Explain diff in depth")
        XCTAssertEqual(store.templates[0].prompt, "Provide an in-depth breakdown of the current git diff.")

        // Verify persistence
        let store2 = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        XCTAssertEqual(store2.templates[0].title, "Explain diff in depth")
    }

    func testDeleteTemplate() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        store.deleteTemplate(id: "explain-diff")

        XCTAssertEqual(store.templates.count, 3)
        XCTAssertFalse(store.templates.contains(where: { $0.id == "explain-diff" }))

        // Verify persistence
        let store2 = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        XCTAssertEqual(store2.templates.count, 3)
        XCTAssertFalse(store2.templates.contains(where: { $0.id == "explain-diff" }))
    }

    func testMoveTemplateDirection() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        // [explain-diff, review-bugs, gen-commit, commit-push]
        // Move review-bugs up -> becomes first
        store.moveTemplate(id: "review-bugs", direction: .up)
        XCTAssertEqual(store.templates[0].id, "review-bugs")
        XCTAssertEqual(store.templates[1].id, "explain-diff")

        // Move review-bugs down -> returns to second
        store.moveTemplate(id: "review-bugs", direction: .down)
        XCTAssertEqual(store.templates[0].id, "explain-diff")
        XCTAssertEqual(store.templates[1].id, "review-bugs")
    }

    func testMoveTemplateFromOffsets() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        // [explain-diff (0), review-bugs (1), gen-commit (2), commit-push (3)]
        // Move index 2 (gen-commit) to 0 -> becomes first
        store.moveTemplate(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.templates[0].id, "gen-commit")
        XCTAssertEqual(store.templates[1].id, "explain-diff")
        XCTAssertEqual(store.templates[2].id, "review-bugs")
        XCTAssertEqual(store.templates[3].id, "commit-push")
    }

    func testResetToDefaults() {
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        store.deleteTemplate(id: "explain-diff")
        store.deleteTemplate(id: "review-bugs")
        XCTAssertEqual(store.templates.count, 2)

        store.resetToDefaults()
        XCTAssertEqual(store.templates.count, 4)
        XCTAssertEqual(store.templates[0].id, "explain-diff")
    }

    func testCorruptedStorageFallback() {
        testUserDefaults.set("invalid json".data(using: .utf8), forKey: testKey)
        let store = AgentPromptTemplateStore(userDefaults: testUserDefaults, storageKey: testKey)
        XCTAssertEqual(store.templates.count, 4)
        XCTAssertEqual(store.templates[0].id, "explain-diff")
    }
}
