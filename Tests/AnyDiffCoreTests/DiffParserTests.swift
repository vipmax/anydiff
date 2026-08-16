import XCTest
@testable import AnyDiffCore

final class DiffParserTests: XCTestCase {
    func testUnifiedDiffParsing() {
        let diff = """
diff --git a/App.swift b/App.swift
index 1111111..2222222 100644
--- a/App.swift
+++ b/App.swift
@@ -10,4 +10,5 @@ struct App {
     var count: Int
-    func run() {
+    func runAsync() async {
+        print("running")
     }
 }
"""
        let files = GitDiffParser.shared.parse(diffText: diff)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.displayPath, "App.swift")
        XCTAssertEqual(file.hunks.count, 1)

        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.oldRange, 10..<14)
        XCTAssertEqual(hunk.newRange, 10..<15)
        XCTAssertEqual(hunk.addedLineCount, 2)
        XCTAssertEqual(hunk.deletedLineCount, 1)
    }

    func testDeletedFileParsingAndDisplayMap() {
        let diff = """
diff --git a/OldFile.swift b/OldFile.swift
deleted file mode 100644
index 1111111..0000000
--- a/OldFile.swift
+++ /dev/null
@@ -1,5 +0,0 @@
-import SwiftUI
-import AnyDiffCore
-
-public struct OldFile {
-}
"""
        let files = GitDiffParser.shared.parse(diffText: diff)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.status, .deleted)
        XCTAssertEqual(file.displayPath, "OldFile.swift")
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].lines.count, 5)

        // Test DisplayMap generation for this deleted file
        let multiBuffer = MultiBuffer()
        let oldLines = file.hunks.flatMap { $0.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text) }
        let buffer = Buffer(
            filePath: file.displayPath,
            text: "",
            language: Buffer.detectLanguage(for: file.displayPath),
            baselineText: oldLines.joined(separator: "\n"),
            totalAdditions: 0,
            totalDeletions: 5,
            startLineNumber: 1,
            fullDiskPath: nil,
            diskFileLineCount: 0
        )
        multiBuffer.addBuffer(buffer)

        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: file.displayPath,
            fileStatus: .deleted,
            bufferRange: 0..<0,
            hunk: file.hunks.first,
            isCollapsed: false,
            isFileStart: true
        )
        multiBuffer.addExcerpt(excerpt)

        let reviewManager = ReviewManager()
        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)

        // Must have: 1 header + 5 code lines = 6 display lines (no fold gaps)
        XCTAssertEqual(displayMap.displayLines.count, 6)

        if case .excerptHeader(let header) = displayMap.displayLines[0] {
            XCTAssertEqual(header.fileStatus, .deleted)
            XCTAssertEqual(header.deletions, 5)
            XCTAssertEqual(header.additions, 0)
        } else {
            XCTFail("First line must be excerpt header")
        }

        for i in 1...5 {
            if case .code(let code) = displayMap.displayLines[i] {
                XCTAssertEqual(code.diffKind, DiffLineKind.deleted)
                XCTAssertEqual(code.oldLineNumber, i)
                XCTAssertNil(code.newLineNumber)
                XCTAssertNil(code.expandInfo)
            } else {
                XCTFail("Line \(i) must be deleted code line")
            }
        }
    }

    func testComparisonTargetEnum() {
        let workingTree = ComparisonTarget.workingTree
        XCTAssertEqual(workingTree.title, "Uncommitted Changes")
        XCTAssertEqual(workingTree.shortDescription, "Working Tree")

        let baseBranch = ComparisonTarget.baseBranch("main")
        XCTAssertEqual(baseBranch.title, "vs main (Base)")
        XCTAssertEqual(baseBranch.shortDescription, "main...")

        let directBranch = ComparisonTarget.directBranch("origin/feature")
        XCTAssertEqual(directBranch.title, "vs origin/feature")
        XCTAssertEqual(directBranch.shortDescription, "→ origin/feature")
    }

    func testLargeFileListFilteringPerformance() {
        var files: [FileDiff] = []
        for i in 0..<10_000 {
            files.append(FileDiff(
                oldPath: "Sources/Module\(i % 100)/File\(i).swift",
                newPath: "Sources/Module\(i % 100)/File\(i).swift",
                status: (i % 3 == 0) ? .added : ((i % 3 == 1) ? .modified : .deleted),
                hunks: []
            ))
        }

        XCTAssertEqual(files.count, 10_000)
        let filtered = files.filter { $0.displayPath.localizedCaseInsensitiveContains("File999.swift") }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.displayPath, "Sources/Module99/File999.swift")
    }

    func testLargeBunDiffParsing() throws {
        let diffPath = "/tmp/bun_pr_30412.diff"
        guard FileManager.default.fileExists(atPath: diffPath) else { return }
        let diffText = try String(contentsOfFile: diffPath, encoding: .utf8)
        let t0 = Date()
        let files = GitDiffParser.shared.parse(diffText: diffText)
        let elapsed = Date().timeIntervalSince(t0)
        print("Parsed \(files.count) files in \(elapsed)s")
        XCTAssertGreaterThan(files.count, 2000)

        let mb = MultiBuffer()
        for file in files {
            for (hIdx, hunk) in file.hunks.enumerated() {
                let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                let linesText = newFileLines.joined(separator: "\n")
                let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                let baselineText = oldBaselineLines.joined(separator: "\n")

                let buffer = Buffer(
                    filePath: file.displayPath,
                    text: linesText,
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineText: baselineText,
                    totalAdditions: file.additions,
                    totalDeletions: file.deletions,
                    startLineNumber: hunk.newRange.lowerBound,
                    fullDiskPath: nil,
                    diskFileLineCount: nil
                )
                mb.addBuffer(buffer)
                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: file.displayPath,
                    fileStatus: file.status,
                    bufferRange: 0..<buffer.lineCount,
                    hunk: hunk,
                    isCollapsed: false,
                    isFileStart: (hIdx == 0)
                )
                mb.addExcerpt(excerpt)
            }
        }
        let t1 = Date()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        let dmElapsed = Date().timeIntervalSince(t1)
        print("Built DisplayMap with \(dm.displayLines.count) display lines in \(dmElapsed)s")
    }
}
