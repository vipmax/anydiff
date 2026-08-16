import XCTest
@testable import AnyDiffCore

final class GitHubDiffServiceTests: XCTestCase {
    func testParseGitHubPullRequestURL() {
        let input = "https://github.com/oven-sh/bun/pull/30412"
        let result = GitHubDiffService.shared.parseReference(from: input)
        guard case .success(let ref) = result else {
            XCTFail("Failed to parse PR URL: \(result)")
            return
        }

        XCTAssertEqual(ref.owner, "oven-sh")
        XCTAssertEqual(ref.repo, "bun")
        XCTAssertEqual(ref.kind, .pullRequest(30412))
        XCTAssertEqual(ref.diffURL.absoluteString, "https://github.com/oven-sh/bun/pull/30412.diff")
        XCTAssertEqual(ref.webURL?.absoluteString, "https://github.com/oven-sh/bun/pull/30412")
        XCTAssertEqual(ref.displayTitle, "oven-sh/bun #30412")
    }

    func testParseDiffsHubURL() {
        let input = "https://diffshub.com/oven-sh/bun/pull/30412"
        let result = GitHubDiffService.shared.parseReference(from: input)
        guard case .success(let ref) = result else {
            XCTFail("Failed to parse DiffsHub URL: \(result)")
            return
        }

        XCTAssertEqual(ref.owner, "oven-sh")
        XCTAssertEqual(ref.repo, "bun")
        XCTAssertEqual(ref.kind, .pullRequest(30412))
        XCTAssertEqual(ref.diffURL.absoluteString, "https://github.com/oven-sh/bun/pull/30412.diff")
        XCTAssertEqual(ref.displayTitle, "oven-sh/bun #30412")
    }

    func testParseShorthandPR() {
        let input = "oven-sh/bun#30412"
        let result = GitHubDiffService.shared.parseReference(from: input)
        guard case .success(let ref) = result else {
            XCTFail("Failed to parse shorthand: \(result)")
            return
        }

        XCTAssertEqual(ref.owner, "oven-sh")
        XCTAssertEqual(ref.repo, "bun")
        XCTAssertEqual(ref.kind, .pullRequest(30412))
        XCTAssertEqual(ref.diffURL.absoluteString, "https://github.com/oven-sh/bun/pull/30412.diff")
        XCTAssertEqual(ref.displayTitle, "oven-sh/bun #30412")
    }

    func testParseCommitURL() {
        let input = "https://github.com/torvalds/linux/commit/89765db5a9a93331e158ec54f86d72fd0988"
        let result = GitHubDiffService.shared.parseReference(from: input)
        guard case .success(let ref) = result else {
            XCTFail("Failed to parse commit URL: \(result)")
            return
        }

        XCTAssertEqual(ref.owner, "torvalds")
        XCTAssertEqual(ref.repo, "linux")
        XCTAssertEqual(ref.displayTitle, "torvalds/linux @ 89765db")
        XCTAssertEqual(ref.diffURL.absoluteString, "https://github.com/torvalds/linux/commit/89765db5a9a93331e158ec54f86d72fd0988.diff")
    }

    func testParseCompareURL() {
        let input = "https://github.com/torvalds/linux/compare/v6.0...v7.0"
        let result = GitHubDiffService.shared.parseReference(from: input)
        guard case .success(let ref) = result else {
            XCTFail("Failed to parse compare URL: \(result)")
            return
        }

        XCTAssertEqual(ref.owner, "torvalds")
        XCTAssertEqual(ref.repo, "linux")
        XCTAssertEqual(ref.kind, .compare(base: "v6.0", head: "v7.0"))
        XCTAssertEqual(ref.diffURL.absoluteString, "https://github.com/torvalds/linux/compare/v6.0...v7.0.diff")
        XCTAssertEqual(ref.displayTitle, "torvalds/linux: v6.0...v7.0")
    }

    func testComparisonTargetRemoteEnum() {
        let ref = GitHubDiffReference(
            owner: "oven-sh",
            repo: "bun",
            kind: .pullRequest(30412),
            diffURL: URL(string: "https://github.com/oven-sh/bun/pull/30412.diff")!,
            webURL: URL(string: "https://github.com/oven-sh/bun/pull/30412")!,
            displayTitle: "oven-sh/bun #30412"
        )
        let target = ComparisonTarget.remote(ref)
        XCTAssertEqual(target.title, "oven-sh/bun #30412")
        XCTAssertEqual(target.shortDescription, "oven-sh/bun #30412")
    }

    func testLiveFetchGitHubDiff() async throws {
        let input = "https://github.com/ghostty-org/ghostty/pull/12291"
        let (ref, diffText) = try await GitHubDiffService.shared.fetchDiff(from: input)
        XCTAssertEqual(ref.displayTitle, "ghostty-org/ghostty #12291")
        XCTAssertFalse(diffText.isEmpty)
        XCTAssertTrue(diffText.contains("diff --git"))

        let parsedFiles = GitDiffParser.shared.parse(diffText: diffText)
        XCTAssertGreaterThan(parsedFiles.count, 0)
    }
}
