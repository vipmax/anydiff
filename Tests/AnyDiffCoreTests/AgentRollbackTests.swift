import XCTest
@testable import AnyDiffCore

final class AgentRollbackTests: XCTestCase {

    private func createTempGitRepo() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydiff_test_repo_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let processInit = Process()
        processInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        processInit.arguments = ["-C", tempDir.path, "init"]
        try processInit.run()
        processInit.waitUntilExit()

        // Configure dummy user for commits
        let configName = Process()
        configName.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configName.arguments = ["-C", tempDir.path, "config", "user.name", "TestUser"]
        try configName.run()
        configName.waitUntilExit()

        let configEmail = Process()
        configEmail.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        configEmail.arguments = ["-C", tempDir.path, "config", "user.email", "test@example.com"]
        try configEmail.run()
        configEmail.waitUntilExit()

        return tempDir
    }

    private func commitFile(repoDir: URL, relativePath: String, content: String) throws {
        let fileURL = repoDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["-C", repoDir.path, "add", relativePath]
        try add.run()
        add.waitUntilExit()

        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        commit.arguments = ["-C", repoDir.path, "commit", "-m", "Commit \(relativePath)"]
        try commit.run()
        commit.waitUntilExit()
    }

    func testRevertModifiedFile() throws {
        let repo = try createTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        try commitFile(repoDir: repo, relativePath: "hello.txt", content: "Line 1\nLine 2\n")

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

        try commitFile(repoDir: repo, relativePath: "initial.txt", content: "Initial\n")

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

        try commitFile(repoDir: repo, relativePath: "to_delete.txt", content: "Delete me\n")

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

        try commitFile(repoDir: repo, relativePath: "existing.txt", content: "Original existing\n")
        try commitFile(repoDir: repo, relativePath: "deleted.txt", content: "Original deleted\n")

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

        try commitFile(repoDir: repo, relativePath: "file.txt", content: "Original\n")

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

        try commitFile(repoDir: repo, relativePath: "existing.txt", content: "Original existing\n")

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
