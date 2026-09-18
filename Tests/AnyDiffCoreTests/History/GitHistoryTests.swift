import XCTest
@testable import AnyDiffCore

final class GitHistoryTests: XCTestCase {

    func testParseLogDataWithDelimiters() {
        let fieldSep = String(UnicodeScalar(GitLogReader.fieldSeparator))
        let recSep = String(UnicodeScalar(GitLogReader.recordSeparator))

        let rawString = [
            "commit1hash", "c1h", "parent1hash parent2hash", "John Doe", "john@example.com", "1700000000", "feat: first feature", "Detailed description line 1\nline 2"
        ].joined(separator: fieldSep) + recSep + [
            "commit2hash", "c2h", "", "Jane Smith", "jane@example.com", "1700000100", "fix: initial commit", ""
        ].joined(separator: fieldSep) + recSep

        let data = Data(rawString.utf8)
        let refs: [String: [GitRef]] = [
            "commit1hash": [GitRef(name: "refs/heads/main", shortName: "main", type: .head)]
        ]

        let commits = GitLogReader.shared.parseLogData(data, refsByHash: refs)

        XCTAssertEqual(commits.count, 2)

        let first = commits[0]
        XCTAssertEqual(first.hash, "commit1hash")
        XCTAssertEqual(first.shortHash, "c1h")
        XCTAssertEqual(first.parentHashes, ["parent1hash", "parent2hash"])
        XCTAssertTrue(first.isMergeCommit)
        XCTAssertFalse(first.isRootCommit)
        XCTAssertEqual(first.authorName, "John Doe")
        XCTAssertEqual(first.authorEmail, "john@example.com")
        XCTAssertEqual(first.summary, "feat: first feature")
        XCTAssertEqual(first.body, "Detailed description line 1\nline 2")
        XCTAssertEqual(first.refs.count, 1)
        XCTAssertEqual(first.refs[0].shortName, "main")

        let second = commits[1]
        XCTAssertEqual(second.hash, "commit2hash")
        XCTAssertEqual(second.shortHash, "c2h")
        XCTAssertEqual(second.parentHashes, [])
        XCTAssertFalse(second.isMergeCommit)
        XCTAssertTrue(second.isRootCommit)
        XCTAssertEqual(second.summary, "fix: initial commit")
        XCTAssertEqual(second.body, "")
    }

    func testParseLogDataWithShortstat() {
        let fieldSep = String(UnicodeScalar(GitLogReader.fieldSeparator))
        let recSep = String(UnicodeScalar(GitLogReader.recordSeparator))

        let rawString = [
            "commit1hash", "c1h", "", "Author", "author@test.com", "1700000000", "feat: add feature", "body text", " 3 files changed, 45 insertions(+), 12 deletions(-)"
        ].joined(separator: fieldSep) + recSep

        let data = Data(rawString.utf8)
        let commits = GitLogReader.shared.parseLogData(data)

        XCTAssertEqual(commits.count, 1)
        let commit = commits[0]
        XCTAssertEqual(commit.filesChanged, 3)
        XCTAssertEqual(commit.additions, 45)
        XCTAssertEqual(commit.deletions, 12)
    }

    func testGraphLayoutLinearCommits() {
        let commit3 = GitCommit(
            hash: "c3", shortHash: "c3", parentHashes: ["c2"],
            authorName: "A", authorEmail: "a@a.com", date: Date(), summary: "3"
        )
        let commit2 = GitCommit(
            hash: "c2", shortHash: "c2", parentHashes: ["c1"],
            authorName: "A", authorEmail: "a@a.com", date: Date(), summary: "2"
        )
        let commit1 = GitCommit(
            hash: "c1", shortHash: "c1", parentHashes: [],
            authorName: "A", authorEmail: "a@a.com", date: Date(), summary: "1"
        )

        let rows = GitGraphLayoutEngine.shared.buildLayout(commits: [commit3, commit2, commit1], includeWorkingChanges: true)

        XCTAssertEqual(rows.count, 4) // working changes + 3 commits

        // Row 0: Working changes
        XCTAssertTrue(rows[0].isWorkingChanges)
        XCTAssertEqual(rows[0].nodeLane, 0)
        XCTAssertTrue(rows[0].outboundSegments.contains { $0.isDashed })

        // Row 1: c3
        XCTAssertEqual(rows[1].commit?.hash, "c3")
        XCTAssertEqual(rows[1].nodeLane, 0)
        XCTAssertEqual(rows[1].outboundSegments.first?.toLane, 0)

        // Row 2: c2
        XCTAssertEqual(rows[2].commit?.hash, "c2")
        XCTAssertEqual(rows[2].nodeLane, 0)
        XCTAssertEqual(rows[2].outboundSegments.first?.toLane, 0)

        // Row 3: c1 (root)
        XCTAssertEqual(rows[3].commit?.hash, "c1")
        XCTAssertEqual(rows[3].nodeLane, 0)
        XCTAssertTrue(rows[3].outboundSegments.isEmpty) // root commit ends lane
    }

    func testGraphLayoutBranchAndMerge() {
        // Topology:
        // c4 (merge c3 and c2) -> parents: ["c3", "c2"]
        // c3 (on branch)       -> parents: ["c1"]
        // c2 (on main)         -> parents: ["c1"]
        // c1 (root)            -> parents: []
        let c4 = GitCommit(hash: "c4", shortHash: "c4", parentHashes: ["c3", "c2"], authorName: "A", authorEmail: "", date: Date(), summary: "merge")
        let c3 = GitCommit(hash: "c3", shortHash: "c3", parentHashes: ["c1"], authorName: "A", authorEmail: "", date: Date(), summary: "feature")
        let c2 = GitCommit(hash: "c2", shortHash: "c2", parentHashes: ["c1"], authorName: "A", authorEmail: "", date: Date(), summary: "main work")
        let c1 = GitCommit(hash: "c1", shortHash: "c1", parentHashes: [], authorName: "A", authorEmail: "", date: Date(), summary: "root")

        let rows = GitGraphLayoutEngine.shared.buildLayout(commits: [c4, c3, c2, c1], includeWorkingChanges: false)

        XCTAssertEqual(rows.count, 4)

        // c4 (merge commit) should have outbound segments branching to lane 0 and lane 1
        let row4 = rows[0]
        XCTAssertEqual(row4.commit?.hash, "c4")
        XCTAssertEqual(row4.outboundSegments.count, 2)
        XCTAssertTrue(row4.outboundSegments.contains { $0.toLane == 0 })
        XCTAssertTrue(row4.outboundSegments.contains { $0.toLane == 1 })
    }

    func testComplexMergeTopologyAndInboundConvergence() {
        // Real-world topology mimicking nested merge PRs and mainline continuity:
        // m1 (merge remote-tracking origin/main) -> parents: ["p0", "m2"]
        // m2 (merge PR #26)                     -> parents: ["p1", "b1"]
        // b1 (Skip flaky...)                    -> parents: ["b2"]
        // b2 (chore: build Windows...)          -> parents: ["p0"]
        // p0 (fix: normalize paths...)          -> parents: ["p1"]
        // p1 (Fix reverting added files)        -> parents: ["root"]
        // root                                  -> parents: []

        let m1 = GitCommit(hash: "m1", shortHash: "m1", parentHashes: ["p0", "m2"], authorName: "A", authorEmail: "", date: Date(), summary: "m1")
        let m2 = GitCommit(hash: "m2", shortHash: "m2", parentHashes: ["p1", "b1"], authorName: "A", authorEmail: "", date: Date(), summary: "m2")
        let b1 = GitCommit(hash: "b1", shortHash: "b1", parentHashes: ["b2"], authorName: "A", authorEmail: "", date: Date(), summary: "b1")
        let b2 = GitCommit(hash: "b2", shortHash: "b2", parentHashes: ["p0"], authorName: "A", authorEmail: "", date: Date(), summary: "b2")
        let p0 = GitCommit(hash: "p0", shortHash: "p0", parentHashes: ["p1"], authorName: "A", authorEmail: "", date: Date(), summary: "p0")
        let p1 = GitCommit(hash: "p1", shortHash: "p1", parentHashes: ["root"], authorName: "A", authorEmail: "", date: Date(), summary: "p1")
        let root = GitCommit(hash: "root", shortHash: "root", parentHashes: [], authorName: "A", authorEmail: "", date: Date(), summary: "root")

        let rows = GitGraphLayoutEngine.shared.buildLayout(commits: [m1, m2, b1, b2, p0, p1, root], includeWorkingChanges: false)

        XCTAssertEqual(rows.count, 7)

        // Mainline continuity: m1, p0, p1, and root must all stay on Lane 0
        XCTAssertEqual(rows[0].commit?.hash, "m1")
        XCTAssertEqual(rows[0].nodeLane, 0)
        XCTAssertEqual(rows[0].nodeColorIndex, 0)

        // m2 is on Lane 1
        XCTAssertEqual(rows[1].commit?.hash, "m2")
        XCTAssertEqual(rows[1].nodeLane, 1)

        // b1 and b2 are on Lane 2
        XCTAssertEqual(rows[2].commit?.hash, "b1")
        XCTAssertEqual(rows[2].nodeLane, 2)
        XCTAssertEqual(rows[3].commit?.hash, "b2")
        XCTAssertEqual(rows[3].nodeLane, 2)

        // p0 is on Lane 0 (mainline stays on lane 0!)
        XCTAssertEqual(rows[4].commit?.hash, "p0")
        XCTAssertEqual(rows[4].nodeLane, 0)
        // b2 curved outbound into lane 0 to join p0
        XCTAssertTrue(rows[3].outboundSegments.contains { $0.fromLane == 2 && $0.toLane == 0 })

        // p1 is on Lane 0 (mainline stays on lane 0!)
        XCTAssertEqual(rows[5].commit?.hash, "p1")
        XCTAssertEqual(rows[5].nodeLane, 0)
        XCTAssertEqual(rows[5].nodeColorIndex, 0)
        // m2 on Lane 1 converged into p1 on Lane 0
        XCTAssertTrue(rows[5].inboundSegments.contains { $0.fromLane == 1 && $0.toLane == 0 })

        // root is on Lane 0
        XCTAssertEqual(rows[6].commit?.hash, "root")
        XCTAssertEqual(rows[6].nodeLane, 0)
    }

    func testCommitFileChangeProperties() {
        let change = CommitFileChange(
            path: "Sources/AnyDiffUI/History/CommitDetailPopoverView.swift",
            additions: 42,
            deletions: 7,
            isBinary: false
        )

        XCTAssertEqual(change.fileName, "CommitDetailPopoverView.swift")
        XCTAssertEqual(change.directoryPath, "Sources/AnyDiffUI/History")
        XCTAssertEqual(change.additions, 42)
        XCTAssertEqual(change.deletions, 7)
        XCTAssertFalse(change.isBinary)

        let rootFile = CommitFileChange(path: "README.md", additions: 10, deletions: 0)
        XCTAssertEqual(rootFile.fileName, "README.md")
        XCTAssertEqual(rootFile.directoryPath, "")
    }

    func testFilteredOrDisconnectedCommitsStayOnLaneZeroWithoutLeakingLanes() {
        // Simulates search results where commits are not direct parents of each other
        let c1 = GitCommit(hash: "c1", shortHash: "c1", parentHashes: ["p1_not_in_results"], authorName: "A", authorEmail: "", date: Date(), summary: "c1")
        let c2 = GitCommit(hash: "c2", shortHash: "c2", parentHashes: ["p2_not_in_results"], authorName: "A", authorEmail: "", date: Date(), summary: "c2")
        let c3 = GitCommit(hash: "c3", shortHash: "c3", parentHashes: ["p3_not_in_results"], authorName: "A", authorEmail: "", date: Date(), summary: "c3")

        let rows = GitGraphLayoutEngine.shared.buildLayout(commits: [c1, c2, c3], includeWorkingChanges: false)

        XCTAssertEqual(rows.count, 3)

        // All commits should stay cleanly on Lane 0 without stair-stepping
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.nodeLane, 0, "Row \(i) should stay on lane 0")
            XCTAssertEqual(row.nodeColorIndex, 0, "Row \(i) should use mainline color")
            XCTAssertEqual(row.totalLanes, 1, "Row \(i) should only require 1 total lane")
            XCTAssertTrue(row.passThroughTracks.isEmpty, "Row \(i) should not have pass-through tracks")
            XCTAssertTrue(row.inboundSegments.isEmpty, "Row \(i) should not have dangling ceiling segments")
            XCTAssertTrue(row.outboundSegments.isEmpty, "Row \(i) should not have dangling floor segments")
        }
    }
}
