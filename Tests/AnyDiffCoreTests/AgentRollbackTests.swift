import XCTest
@testable import AnyDiffCore

final class AgentRollbackTests: XCTestCase {
    private static var gitTemplateURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        guard environment["ANYDIFF_RUN_AGENT_ROLLBACK_TESTS"] == "1"
            || environment["ANYDIFF_RUN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Agent rollback Git tests skipped. Run with ANYDIFF_RUN_AGENT_ROLLBACK_TESTS=1 or ANYDIFF_RUN_INTEGRATION_TESTS=1 to enable them.")
        }

        if Self.gitTemplateURL == nil {
            Self.gitTemplateURL = try Self.createGitTemplate()
        }
    }

    override class func tearDown() {
        if let gitTemplateURL {
            try? FileManager.default.removeItem(at: gitTemplateURL)
        }
        gitTemplateURL = nil
        super.tearDown()
    }

    private func createTempGitRepo() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_test_repo_\(UUID().uuidString)")
        guard let gitTemplateURL = Self.gitTemplateURL else {
            throw NSError(domain: "AgentRollbackTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Git test template is not initialized"
            ])
        }
        try FileManager.default.copyItem(at: gitTemplateURL, to: tempDir)
        return tempDir
    }

    private static func createGitTemplate() throws -> URL {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_agent_rollback_template_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: templateURL, withIntermediateDirectories: true)

        let baselineFiles = [
            "hello.txt": "Line 1\nLine 2\n",
            "initial.txt": "Initial\n",
            "to_delete.txt": "Delete me\n",
            "file.txt": "Original\n",
            "existing.txt": "Original existing\n",
            "deleted.txt": "Original deleted\n"
        ]
        for (relativePath, content) in baselineFiles {
            let fileURL = templateURL.appendingPathComponent(relativePath)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try runGit(in: templateURL, arguments: ["init"])
        try runGit(in: templateURL, arguments: ["add", "."])
        try runGit(in: templateURL, arguments: [
            "-c", "user.name=TestUser",
            "-c", "user.email=test@example.com",
            "commit", "-m", "Create rollback test baseline"
        ])
        return templateURL
    }

    private static func runGit(in directory: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AgentRollbackTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git command failed: \(arguments.joined(separator: " "))"
            ])
        }
    }

    func testRevertModifiedFile() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Pre-turn snapshot
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)

        // Agent modifies hello.txt
        let fileURL = repo.appendingPathComponent("hello.txt")
        try "Line 1\nModified Line 2\nLine 3\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard let summary = summary else {
            XCTFail("Expected summary")
            return
        }

        XCTAssertFalse(summary.isReverted)
        XCTAssertTrue(summary.modifiedFiles.contains("hello.txt"))

        // Revert
        var mutSummary = summary
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: repo.path, summary: &mutSummary)
        XCTAssertTrue(success)

        let restoredContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(restoredContent, "Line 1\nLine 2\n")
    }

    func testRevertNewlyCreatedFile() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Pre-turn snapshot
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)

        // Agent creates new file
        let newFileURL = repo.appendingPathComponent("new_file.txt")
        try "Brand new file\n".write(to: newFileURL, atomically: true, encoding: .utf8)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard let summary = summary else {
            XCTFail("Expected summary")
            return
        }

        XCTAssertTrue(summary.createdFiles.contains("new_file.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFileURL.path))

        // Revert
        var mutSummary = summary
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: repo.path, summary: &mutSummary)
        XCTAssertTrue(success)

        // File should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: newFileURL.path))
    }

    func testRevertDeletedFile() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Pre-turn snapshot
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)

        // Agent deletes file
        let fileURL = repo.appendingPathComponent("to_delete.txt")
        try FileManager.default.removeItem(at: fileURL)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard let summary = summary else {
            XCTFail("Expected summary")
            return
        }

        XCTAssertTrue(summary.deletedFiles.contains("to_delete.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // Revert
        var mutSummary = summary
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: repo.path, summary: &mutSummary)
        XCTAssertTrue(success)

        // File should be restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let restoredContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(restoredContent, "Delete me\n")
    }

    func testRevertTurnWithMixedOperations() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        // Pre-turn snapshot
        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)

        // Modify existing
        let existingURL = repo.appendingPathComponent("existing.txt")
        try "Modified existing\n".write(to: existingURL, atomically: true, encoding: .utf8)

        // Delete deleted.txt
        let deletedURL = repo.appendingPathComponent("deleted.txt")
        try FileManager.default.removeItem(at: deletedURL)

        // Create new file in subdirectory
        let createdURL = repo.appendingPathComponent("nested/new.txt")
        try FileManager.default.createDirectory(at: createdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Nested new\n".write(to: createdURL, atomically: true, encoding: .utf8)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard let summary = summary else {
            XCTFail("Expected summary")
            return
        }

        XCTAssertEqual(summary.files.count, 3)

        // Revert turn
        var mutSummary = summary
        let success = AgentTurnRollbackService.revertTurn(workingDirectory: repo.path, summary: &mutSummary)
        XCTAssertTrue(success)

        // Verify all 3 files
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "Original existing\n")
        XCTAssertEqual(try String(contentsOf: deletedURL, encoding: .utf8), "Original deleted\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("nested").path))
    }

    func testAgentSessionManagerRevertAndRestoreTurn() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)
        try "Changed\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard let summary = summary else {
            XCTFail("Expected summary")
            return
        }

        let manager = AgentSessionManager()
        let msg = AgentMessage(
            role: .assistant,
            content: "I edited file.txt",
            editedFilesSummary: summary
        )
        manager.messages = [msg]

        XCTAssertFalse(manager.messages[0].editedFilesSummary!.isReverted)

        // Revert
        let revertSuccess = manager.revertTurn(messageId: msg.id, workingDirectory: repo.path)
        XCTAssertTrue(revertSuccess)
        XCTAssertTrue(manager.messages[0].editedFilesSummary!.isReverted)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "Original\n")

        // Restore (Redo)
        let restoreSuccess = manager.restoreTurn(messageId: msg.id, workingDirectory: repo.path)
        XCTAssertTrue(restoreSuccess)
        XCTAssertFalse(manager.messages[0].editedFilesSummary!.isReverted)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "Changed\n")
    }

    func testRestoreTurnWithCreatedAndDeletedFiles() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let snapshot = AgentGitChangesDetector.capturePreTurnSnapshot(workingDirectory: repo.path)

        // Agent creates new file and modifies existing
        let createdURL = repo.appendingPathComponent("brand_new.txt")
        try "New text\n".write(to: createdURL, atomically: true, encoding: .utf8)
        let existingURL = repo.appendingPathComponent("existing.txt")
        try "Updated text\n".write(to: existingURL, atomically: true, encoding: .utf8)

        let (summary, _) = AgentGitChangesDetector.computeTurnSummary(workingDirectory: repo.path, snapshot: snapshot)
        guard var summary = summary else {
            XCTFail("Expected summary")
            return
        }

        // Revert
        XCTAssertTrue(AgentTurnRollbackService.revertTurn(workingDirectory: repo.path, summary: &summary))
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "Original existing\n")

        // Restore (Redo)
        XCTAssertTrue(AgentTurnRollbackService.restoreTurn(workingDirectory: repo.path, summary: summary))
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(try String(contentsOf: createdURL, encoding: .utf8), "New text\n")
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "Updated text\n")
    }
}
