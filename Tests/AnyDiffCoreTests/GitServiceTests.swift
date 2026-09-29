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

    func testGitRepositoryLifecycle() throws {
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
    }
}
