import XCTest
@testable import AnyDiffCore

final class GitServiceTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDiffGitServiceTests_\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    func testNotGitRepository() {
        let isGit = GitService.shared.isRepository(at: tempDirectory.path)
        XCTAssertFalse(isGit)
    }

    func testGitRepositoryLifecycle() async throws {
        let path = tempDirectory.path
        // git init
        let initOut = GitService.shared.run(arguments: ["-C", path, "init"])
        XCTAssertNotNil(initOut)
        XCTAssertTrue(GitService.shared.isRepository(at: path))

        // Create a file
        let fileURL = tempDirectory.appendingPathComponent("test.txt")
        try "hello world\n".write(to: fileURL, atomically: true, encoding: .utf8)

        // Untracked files
        let untracked = GitService.shared.untrackedFiles(at: path)
        XCTAssertEqual(untracked.count, 1)
        XCTAssertEqual(untracked.first?.displayPath, "test.txt")

        // diffFiles for working tree
        let (files, _) = GitService.shared.diffFiles(at: path, target: .workingTree)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.displayPath, "test.txt")
        XCTAssertEqual(files.first?.status, .added)

        // streamDiffFiles
        var streamedFiles: [FileDiff] = []
        for try await f in GitService.shared.streamDiffFiles(at: path, target: .workingTree) {
            streamedFiles.append(f)
        }
        XCTAssertEqual(streamedFiles.count, 1)
        XCTAssertEqual(streamedFiles.first?.displayPath, "test.txt")
    }

    func testParseWorktreesPorcelainZ() {
        let records = [
            "worktree /Users/dev/repo",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /Users/dev/repo.worktrees/feat space",
            "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/feat/test",
            "locked reason with spaces",
            "",
            "worktree /Users/dev/repo.worktrees/detached-wt",
            "HEAD 3333333333333333333333333333333333333333",
            "detached",
            "prunable gitdir file points to non-existent location",
            ""
        ]
        let raw = Data(records.joined(separator: "\0").utf8)
        let parsed = GitService.parseWorktreesPorcelainZ(raw)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].path, "/Users/dev/repo")
        XCTAssertEqual(parsed[0].branch, "main")
        XCTAssertTrue(parsed[0].isMain)
        XCTAssertFalse(parsed[0].isLocked)

        XCTAssertEqual(parsed[1].path, "/Users/dev/repo.worktrees/feat space")
        XCTAssertEqual(parsed[1].branch, "feat/test")
        XCTAssertFalse(parsed[1].isMain)
        XCTAssertTrue(parsed[1].isLocked)
        XCTAssertEqual(parsed[1].lockReason, "reason with spaces")

        XCTAssertEqual(parsed[2].path, "/Users/dev/repo.worktrees/detached-wt")
        XCTAssertNil(parsed[2].branch)
        XCTAssertTrue(parsed[2].isDetached)
        XCTAssertTrue(parsed[2].isPrunable)
        XCTAssertEqual(parsed[2].displayTitle, "detached (3333333)")
    }

    func testGitWorktreeLifecycle() throws {
        let repoURL = tempDirectory.appendingPathComponent("main-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let repoPath = repoURL.path

        XCTAssertNotNil(GitService.shared.run(arguments: ["-C", repoPath, "init", "-b", "main"]))
        _ = GitService.shared.run(arguments: ["-C", repoPath, "config", "user.email", "test@example.com"])
        _ = GitService.shared.run(arguments: ["-C", repoPath, "config", "user.name", "Test User"])

        let readmeURL = repoURL.appendingPathComponent("README.md")
        try "hello\n".write(to: readmeURL, atomically: true, encoding: .utf8)
        _ = GitService.shared.run(arguments: ["-C", repoPath, "add", "README.md"])
        _ = GitService.shared.run(arguments: ["-C", repoPath, "commit", "-m", "initial"])

        let mainPaths = GitService.shared.resolveGitPaths(at: repoPath)
        XCTAssertNotNil(mainPaths)
        XCTAssertFalse(mainPaths!.isLinkedWorktree)
        XCTAssertEqual(mainPaths?.gitDir, mainPaths?.commonDir)
        XCTAssertEqual(mainPaths?.repositoryName, "main-repo")

        let defaultDest = GitService.shared.defaultWorktreePath(at: repoPath, branch: "feat/wt-test")
        XCTAssertTrue(defaultDest.hasSuffix("/.anydiff/worktrees/main-repo/feat-wt-test"))

        let testWorktreesBase = tempDirectory.appendingPathComponent("managed-worktrees", isDirectory: true)
        let scopedDest = GitService.shared.defaultWorktreePath(
            at: repoPath,
            branch: "feat/wt-test",
            worktreesBaseDirectory: testWorktreesBase
        )
        XCTAssertTrue(scopedDest.hasSuffix("/managed-worktrees/main-repo/feat-wt-test"))

        let addResult = GitService.shared.addWorktree(
            at: repoPath,
            destinationPath: scopedDest,
            branch: "feat/wt-test",
            baseRef: "main",
            createBranch: true
        )
        guard case .success(let worktreePath) = addResult else {
            return XCTFail("Expected addWorktree to succeed, got: \(addResult)")
        }

        let wtPaths = GitService.shared.resolveGitPaths(at: worktreePath)
        XCTAssertNotNil(wtPaths)
        XCTAssertTrue(wtPaths!.isLinkedWorktree)
        XCTAssertEqual(wtPaths?.commonDir, mainPaths?.gitDir)
        XCTAssertNotEqual(wtPaths?.gitDir, mainPaths?.gitDir)
        XCTAssertEqual(wtPaths?.repositoryName, "main-repo")

        // Subdirectory resolution inside a linked worktree
        let subDir = URL(fileURLWithPath: worktreePath).appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subPaths = GitService.shared.resolveGitPaths(at: subDir.path)
        XCTAssertEqual(subPaths, wtPaths)
        XCTAssertEqual(subPaths?.repositoryName, "main-repo")

        let listed = GitService.shared.worktrees(at: worktreePath)
        XCTAssertEqual(listed.count, 2)
        XCTAssertTrue(listed[0].isMain)
        XCTAssertFalse(listed[1].isMain)
        XCTAssertEqual(listed[1].branch, "feat/wt-test")

        // Display title for agent header: nil for main, branch name for linked worktree (and subdirectory)
        XCTAssertNil(GitService.shared.nonMainWorktreeDisplayTitle(at: repoPath, worktrees: listed))
        XCTAssertNil(GitService.shared.nonMainWorktreeDisplayTitle(at: repoPath, worktrees: []))
        XCTAssertEqual(GitService.shared.nonMainWorktreeDisplayTitle(at: worktreePath, worktrees: listed), "feat/wt-test")
        XCTAssertEqual(GitService.shared.nonMainWorktreeDisplayTitle(at: subDir.path, worktrees: listed), "feat/wt-test")
        XCTAssertEqual(GitService.shared.nonMainWorktreeDisplayTitle(at: worktreePath, worktrees: []), "feat/wt-test")
        XCTAssertNil(GitService.shared.nonMainWorktreeDisplayTitle(at: tempDirectory.path, worktrees: listed))

        // Diff detection inside linked worktree
        let wtFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "hello\nworld\n".write(to: wtFile, atomically: true, encoding: .utf8)
        let (diffs, _) = GitService.shared.diffFiles(at: worktreePath, target: .workingTree)
        XCTAssertEqual(diffs.map(\.displayPath), ["README.md"])

        // Clean removal
        let removeResult = GitService.shared.removeWorktree(at: repoPath, worktreePath: worktreePath, force: true)
        if case .failure(let err) = removeResult {
            XCTFail("Expected removeWorktree to succeed, got: \(err)")
        }
        XCTAssertEqual(GitService.shared.worktrees(at: repoPath).count, 1)
    }

    func testWorktreeSlugAndSuggestion() throws {
        let english = GitService.worktreeSlug(from: "Fix missing connection status in ACP transport")
        XCTAssertEqual(english, "fix-missing-connection-status-in")

        let russian = GitService.worktreeSlug(from: "Почини тест в парсере @diff\n\n[Diff Context]:\nfoo.swift")
        XCTAssertFalse(russian.isEmpty)
        XCTAssertFalse(russian.contains("Diff"))
        XCTAssertTrue(russian.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })

        let emojiFallback = GitService.worktreeSlug(from: "🚀🔥")
        XCTAssertTrue(emojiFallback.hasPrefix("task-"))

        let repoURL = tempDirectory.appendingPathComponent("demo-app", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let baseURL = tempDirectory.appendingPathComponent("wt-store", isDirectory: true)
        let existingDir = baseURL.appendingPathComponent("demo-app/fix-bug-2", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        let suggestion = GitService.shared.suggestedWorktreeBranchAndPath(
            at: repoURL.path,
            prompt: "Fix bug",
            existingBranches: ["main", "fix-bug"],
            worktreesBaseDirectory: baseURL
        )
        XCTAssertEqual(suggestion.branch, "fix-bug-3")
        XCTAssertTrue(suggestion.path.hasSuffix("/wt-store/demo-app/fix-bug-3"))
    }
}
