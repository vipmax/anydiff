import XCTest
@testable import AnyDiffCore

final class ProjectSearchTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSearchTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func createTestFile(relative: String, content: String) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    @discardableResult
    private func createTestBinaryFile(relative: String, data: Data) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        return fileURL
    }

    func testSimpleSearchAcrossMultipleFiles() throws {
        try createTestFile(relative: "src/file1.swift", content: """
        import Foundation

        struct Worker {
            func executeTask() {
                print("Task started")
            }
        }
        """)

        try createTestFile(relative: "src/file2.swift", content: """
        class TaskManager {
            var activeTasks: [String] = []
        }
        """)

        let mb = MultiBuffer()
        let query = ProjectSearchQuery(query: "Task", isCaseSensitive: true, contextLines: 1)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)

        XCTAssertEqual(result.totalMatchesCount, 4)
        XCTAssertEqual(result.totalMatchingFilesCount, 2)
        XCTAssertEqual(mb.contentMode, .text)
        XCTAssertFalse(mb.excerpts.isEmpty)

        // Verify MultiBuffer row coordinates are resolved
        for match in result.matches {
            XCTAssertNotNil(match.multiBufferRow)
            let row = match.multiBufferRow!
            let line = mb.line(at: row)
            XCTAssertTrue(line.contains("Task"), "Line at MB row \(row) should contain match: '\(line)'")
        }
    }

    func testCaseSensitivityAndWholeWord() throws {
        try createTestFile(relative: "test.txt", content: """
        task
        Task
        TASK
        tasks
        SubTask
        """)

        // Case-insensitive, not whole word
        let q1 = ProjectSearchQuery(query: "task", isCaseSensitive: false, isWholeWord: false)
        let r1 = ProjectSearchEngine.shared.search(query: q1, in: tempDirectory.path)
        XCTAssertEqual(r1.totalMatchesCount, 5)

        // Case-sensitive, not whole word
        let q2 = ProjectSearchQuery(query: "Task", isCaseSensitive: true, isWholeWord: false)
        let r2 = ProjectSearchEngine.shared.search(query: q2, in: tempDirectory.path)
        XCTAssertEqual(r2.totalMatchesCount, 2) // "Task" and "SubTask"

        // Case-sensitive, whole word
        let q3 = ProjectSearchQuery(query: "Task", isCaseSensitive: true, isWholeWord: true)
        let r3 = ProjectSearchEngine.shared.search(query: q3, in: tempDirectory.path)
        XCTAssertEqual(r3.totalMatchesCount, 1) // Only "Task"
    }

    func testRegexSearch() throws {
        try createTestFile(relative: "models.swift", content: """
        let value1 = 100
        let value2 = 200
        let itemA = "text"
        let value99 = 99
        """)

        let query = ProjectSearchQuery(query: "value\\d+", isRegex: true)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path)
        XCTAssertEqual(result.totalMatchesCount, 3)
    }

    func testRegexSearchWithUnicodeAndEmojis() throws {
        // Line with emojis (surrogate pairs) before the match
        let line = "🔥🚀 party = 42 // 🎉"
        try createTestFile(relative: "unicode.swift", content: line)

        let query = ProjectSearchQuery(query: "party", isRegex: true)
        let mb = MultiBuffer()
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)
        XCTAssertEqual(result.totalMatchesCount, 1)

        guard let match = result.matches.first else {
            XCTFail("Match not found")
            return
        }

        // 1. Verify columnRange correctly slices the Swift Character string
        let startIdx = line.index(line.startIndex, offsetBy: match.columnRange.lowerBound)
        let endIdx = line.index(line.startIndex, offsetBy: match.columnRange.upperBound)
        let matchedText = String(line[startIdx..<endIdx])
        XCTAssertEqual(matchedText, "party")

        // 2. Verify recalculateMatches also produces correct character indices
        let liveMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(liveMatches.count, 1)
        if let liveMatch = liveMatches.first {
            let lStart = line.index(line.startIndex, offsetBy: liveMatch.columnRange.lowerBound)
            let lEnd = line.index(line.startIndex, offsetBy: liveMatch.columnRange.upperBound)
            XCTAssertEqual(String(line[lStart..<lEnd]), "party")
        }

        // 3. Verify whole-word search (which uses regex internally) with emojis
        let wwQuery = ProjectSearchQuery(query: "party", isWholeWord: true)
        let wwResult = ProjectSearchEngine.shared.search(query: wwQuery, in: tempDirectory.path)
        XCTAssertEqual(wwResult.totalMatchesCount, 1)
        if let wwMatch = wwResult.matches.first {
            let wStart = line.index(line.startIndex, offsetBy: wwMatch.columnRange.lowerBound)
            let wEnd = line.index(line.startIndex, offsetBy: wwMatch.columnRange.upperBound)
            XCTAssertEqual(String(line[wStart..<wEnd]), "party")
        }
    }

    func testContextClusteringAndLazyBufferSlicing() throws {
        // 100 lines file with matches far apart (line 10 and line 90)
        var lines: [String] = []
        for i in 1...100 {
            if i == 10 {
                lines.append("MARK: Match Alpha")
            } else if i == 90 {
                lines.append("MARK: Match Beta")
            } else {
                lines.append("Line \(i) - standard placeholder content")
            }
        }
        try createTestFile(relative: "long_file.swift", content: lines.joined(separator: "\n"))

        let mb = MultiBuffer()
        let query = ProjectSearchQuery(query: "Match", contextLines: 2)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)

        XCTAssertEqual(result.totalMatchesCount, 2)
        // Two separate clusters should result in 2 excerpts
        XCTAssertEqual(mb.excerpts.count, 2)

        // Verify buffer 1 only has lines 8...12 (5 lines)
        let buf1 = mb.buffer(for: mb.excerpts[0].bufferId)!
        XCTAssertEqual(buf1.startLineNumber, 8)
        XCTAssertEqual(buf1.lineCount, 5)
        XCTAssertEqual(buf1.diskFileLineCount, 100)

        // Verify buffer 2 only has lines 88...92 (5 lines)
        let buf2 = mb.buffer(for: mb.excerpts[1].bufferId)!
        XCTAssertEqual(buf2.startLineNumber, 88)
        XCTAssertEqual(buf2.lineCount, 5)
        XCTAssertEqual(buf2.diskFileLineCount, 100)

        // Verify memory efficiency: total lines in multibuffer is 10 (not 100!)
        XCTAssertEqual(mb.lineCount, 10)
    }

    func testAdjacentMatchesMergeIntoSingleCluster() throws {
        // Matches at line 5 and line 7 with context 2 -> [3...7] and [5...9] -> should merge to [3...9] (7 lines)
        var lines: [String] = []
        for i in 1...20 {
            if i == 5 || i == 7 {
                lines.append("Target occurrence \(i)")
            } else {
                lines.append("Line \(i)")
            }
        }
        try createTestFile(relative: "merged.swift", content: lines.joined(separator: "\n"))

        let mb = MultiBuffer()
        let query = ProjectSearchQuery(query: "Target", contextLines: 2)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)

        XCTAssertEqual(result.totalMatchesCount, 2)
        XCTAssertEqual(mb.excerpts.count, 1)

        let buf = mb.buffer(for: mb.excerpts[0].bufferId)!
        XCTAssertEqual(buf.startLineNumber, 3)
        XCTAssertEqual(buf.lineCount, 7) // lines 3..9
    }

    func testIncludeAndExcludeGlobFilters() throws {
        try createTestFile(relative: "Sources/Core.swift", content: "let target = 1")
        try createTestFile(relative: "Tests/CoreTests.swift", content: "let target = 2")
        try createTestFile(relative: "Docs/README.md", content: "target description")

        // Include only *.swift or .swift shorthand
        let q1 = ProjectSearchQuery(query: "target", includePattern: ".swift")
        let r1 = ProjectSearchEngine.shared.search(query: q1, in: tempDirectory.path)
        XCTAssertEqual(r1.totalMatchesCount, 2)

        // Exclude Tests/* or Tests/
        let q2 = ProjectSearchQuery(query: "target", includePattern: ".swift", excludePattern: "Tests/")
        let r2 = ProjectSearchEngine.shared.search(query: q2, in: tempDirectory.path)
        XCTAssertEqual(r2.totalMatchesCount, 1)
        XCTAssertEqual(r2.matches.first?.filePath, "Sources/Core.swift")

        // Include only Docs/ folder
        let q3 = ProjectSearchQuery(query: "target", includePattern: "Docs/")
        let r3 = ProjectSearchEngine.shared.search(query: q3, in: tempDirectory.path)
        XCTAssertEqual(r3.totalMatchesCount, 1)
        XCTAssertEqual(r3.matches.first?.filePath, "Docs/README.md")
    }

    func testIgnoresDefaultDirectories() throws {
        try createTestFile(relative: ".git/HEAD", content: "search target")
        try createTestFile(relative: "node_modules/package/index.js", content: "search target")
        try createTestFile(relative: ".build/debug/output.txt", content: "search target")
        try createTestFile(relative: "app.swift", content: "search target")

        let query = ProjectSearchQuery(query: "search target")
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path)
        XCTAssertEqual(result.totalMatchesCount, 1)
        XCTAssertEqual(result.matches.first?.filePath, "app.swift")
    }

    func testSearchMultiBufferLiveEditingAndFilePromotion() throws {
        let fileURL = try createTestFile(relative: "editable.swift", content: """
        func calculate() -> Int {
            let initial = 42
            return initial
        }
        """)

        let query = ProjectSearchQuery(query: "initial")
        let mb = MultiBuffer()
        mb.baseDirectory = tempDirectory.path

        _ = ProjectSearchEngine.shared.search(
            query: query,
            in: tempDirectory.path,
            populating: mb
        )

        XCTAssertEqual(mb.contentMode, .text)
        XCTAssertEqual(mb.excerpts.count, 1)

        // Find the line with "let initial = 42"
        let line0 = mb.line(at: 1)
        XCTAssertTrue(line0.contains("let initial = 42"))

        // Edit "42" to "100" in search MultiBuffer
        let startPt = MultiBufferPoint(row: 1, column: 18)
        let endPt = MultiBufferPoint(row: 1, column: 20)
        mb.replace(range: startPt..<endPt, with: "100")

        XCTAssertEqual(mb.line(at: 1), "    let initial = 100")

        // Flush immediate save
        _ = mb.flushImmediateSave()

        let savedContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(savedContent.contains("let initial = 100"))
    }

    func testRecalculateMatchesLiveInMemory() throws {
        _ = try createTestFile(relative: "search_live.swift", content: """
        let alpha = 10
        let beta = 20
        let gamma = 30
        """)

        let query = ProjectSearchQuery(query: "beta")
        let mb = MultiBuffer()
        mb.baseDirectory = tempDirectory.path

        _ = ProjectSearchEngine.shared.search(
            query: query,
            in: tempDirectory.path,
            populating: mb
        )

        let initialMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(initialMatches.count, 1)
        XCTAssertEqual(initialMatches.first?.lineText, "let beta = 20")

        // Edit "beta" -> "delta" (match disappears)
        let loc = mb.location(for: MultiBufferPoint(row: 1, column: 4))
        XCTAssertNotNil(loc)
        mb.replace(
            range: MultiBufferPoint(row: 1, column: 4)..<MultiBufferPoint(row: 1, column: 8),
            with: "delta"
        )

        let afterEditMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(afterEditMatches.count, 0)

        // Add "beta" into line 0
        mb.replace(
            range: MultiBufferPoint(row: 0, column: 4)..<MultiBufferPoint(row: 0, column: 9),
            with: "beta"
        )

        let newMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(newMatches.count, 1)
        XCTAssertEqual(newMatches.first?.lineNumber, 1)
        XCTAssertEqual(newMatches.first?.lineText, "let beta = 10")
    }

    func testSearchCancellationAbortsEarly() throws {
        for i in 1...20 {
            try createTestFile(relative: "batch/file_\(i).swift", content: "let token = \(i)")
        }

        let query = ProjectSearchQuery(query: "token")
        let mb = MultiBuffer()

        // 1. Pre-cancelled
        let resultPreCancelled = ProjectSearchEngine.shared.search(
            query: query,
            in: tempDirectory.path,
            populating: mb,
            isCancelled: { true }
        )
        XCTAssertEqual(resultPreCancelled.totalMatchesCount, 0)
        XCTAssertEqual(resultPreCancelled.totalFilesSearched, 0)

        // 2. Cancelled mid-way via atomic counter
        final class SafeCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let counter = SafeCounter()
        let resultMidCancelled = ProjectSearchEngine.shared.search(
            query: query,
            in: tempDirectory.path,
            populating: mb,
            isCancelled: {
                counter.next() > 3
            }
        )
        XCTAssertTrue(resultMidCancelled.totalFilesSearched <= 5)
    }

    func testSkipsBinaryFilesWithNullBytes() throws {
        // Binary file (e.g. compiled binary without extension) containing null bytes and text
        var bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0x00, 0x01, 0x01]
        let targetText = "secret_keyword_inside_binary"
        bytes.append(contentsOf: Array(targetText.utf8))
        let binaryData = Data(bytes)

        try createTestBinaryFile(relative: "bin/compiled_tool", data: binaryData)

        let query = ProjectSearchQuery(query: "secret_keyword_inside_binary")
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path)
        XCTAssertEqual(result.totalMatchesCount, 0, "Should skip files containing null bytes")
    }

    func testSkipsOversizedFiles() throws {
        let smallContent = "find_me_in_small_file\n"
        let bigContent = String(repeating: "find_me_in_big_file\n", count: 200)

        try createTestFile(relative: "small.txt", content: smallContent)
        try createTestFile(relative: "oversized.txt", content: bigContent)

        // Set maxFileSize to 2000 bytes (big file will exceed it, small file will not)
        let query = ProjectSearchQuery(query: "find_me", maxFileSize: 2000)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path)

        XCTAssertEqual(result.totalMatchesCount, 1)
        XCTAssertEqual(result.matches.first?.filePath, "small.txt")
    }

    func testMaxMatchesTruncation() throws {
        let defaultQuery = ProjectSearchQuery(query: "test")
        XCTAssertEqual(defaultQuery.maxMatches, 10000)

        let content = (1...10).map { "match_token line \($0)" }.joined(separator: "\n")
        try createTestFile(relative: "matches.txt", content: content)

        let query = ProjectSearchQuery(query: "match_token", maxMatches: 5)
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path)

        XCTAssertEqual(result.totalMatchesCount, 5)
        XCTAssertTrue(result.isTruncated)
    }

    final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [ProjectSearchBatch] = []
        func append(_ batch: ProjectSearchBatch) {
            lock.lock()
            defer { lock.unlock() }
            batches.append(batch)
        }
    }

    func testSearchStreamingProgressiveDelivery() async throws {
        for i in 1...10 {
            try createTestFile(relative: "stream/file_\(i).swift", content: "let stream_target = \(i)\n")
        }

        let query = ProjectSearchQuery(query: "stream_target")
        let collector = BatchCollector()

        let result = await ProjectSearchEngine.shared.searchStreaming(
            query: query,
            in: tempDirectory.path,
            onBatch: { batch in
                collector.append(batch)
            }
        )

        XCTAssertEqual(result.totalMatchesCount, 10)
        XCTAssertFalse(collector.batches.isEmpty)
        XCTAssertTrue(collector.batches.last?.isFinished == true)
        let totalMatchesAcrossBatches = collector.batches.reduce(0) { $0 + $1.newMatches.count }
        XCTAssertEqual(totalMatchesAcrossBatches, 10)
    }

    func testSearchStreamingEarlyExitOnMaxMatches() async throws {
        for i in 1...20 {
            try createTestFile(relative: "limit/file_\(i).swift", content: "let limit_target = \(i)\n")
        }

        let query = ProjectSearchQuery(query: "limit_target", maxMatches: 5)
        let collector = BatchCollector()

        let result = await ProjectSearchEngine.shared.searchStreaming(
            query: query,
            in: tempDirectory.path,
            onBatch: { batch in
                collector.append(batch)
            }
        )

        XCTAssertEqual(result.totalMatchesCount, 5)
        XCTAssertTrue(result.isTruncated)
        XCTAssertTrue(collector.batches.contains { $0.isTruncated })
    }

    func testSearchStreamingCancellation() async throws {
        for i in 1...30 {
            try createTestFile(relative: "cancel/file_\(i).swift", content: "let cancel_target = \(i)\n")
        }

        let query = ProjectSearchQuery(query: "cancel_target")

        let resultPreCancelled = await ProjectSearchEngine.shared.searchStreaming(
            query: query,
            in: tempDirectory.path,
            onBatch: { _ in },
            isCancelled: { true }
        )

        XCTAssertEqual(resultPreCancelled.totalMatchesCount, 0)
    }

    func testRescanFileUpdatesBuffersWhenFileContentChanges() throws {
        let fileURL = try createTestFile(
            relative: "WatcherSync.swift",
            content: "func alpha() {\n    let find_target = 1\n}\n"
        )

        let query = ProjectSearchQuery(query: "find_target")
        let mb = MultiBuffer()
        mb.baseDirectory = tempDirectory.path
        let initialResult = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)
        XCTAssertEqual(initialResult.totalMatchesCount, 1)

        // Now simulate external edit: write updated content with 2 occurrences
        let updatedContent = "func alpha() {\n    let find_target = 1\n    let find_target = 2\n}\n"
        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let rescanned = ProjectSearchEngine.shared.rescanFile(
            filePath: "WatcherSync.swift",
            fullDiskPath: fileURL.path,
            query: query
        )
        XCTAssertFalse(rescanned.buffers.isEmpty)
        XCTAssertFalse(rescanned.excerpts.isEmpty)

        mb.replaceFile(
            filePath: "WatcherSync.swift",
            buffers: rescanned.buffers,
            excerpts: rescanned.excerpts
        )

        let updatedMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(updatedMatches.count, 2)
        XCTAssertEqual(updatedMatches[0].lineNumber, 2)
        XCTAssertEqual(updatedMatches[1].lineNumber, 3)
    }

    func testRescanFileRemovesBufferWhenMatchesDeleted() throws {
        let fileURL = try createTestFile(
            relative: "DeleteMatch.swift",
            content: "func alpha() {\n    let remove_me_target = 1\n}\n"
        )

        let query = ProjectSearchQuery(query: "remove_me_target")
        let mb = MultiBuffer()
        mb.baseDirectory = tempDirectory.path
        let initialResult = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)
        XCTAssertEqual(initialResult.totalMatchesCount, 1)

        // Simulate external edit: remove the target keyword entirely
        let updatedContent = "func alpha() {\n    let replaced = 1\n}\n"
        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let rescanned = ProjectSearchEngine.shared.rescanFile(
            filePath: "DeleteMatch.swift",
            fullDiskPath: fileURL.path,
            query: query
        )
        XCTAssertTrue(rescanned.buffers.isEmpty)
        XCTAssertTrue(rescanned.excerpts.isEmpty)

        mb.replaceFile(
            filePath: "DeleteMatch.swift",
            buffers: rescanned.buffers,
            excerpts: rescanned.excerpts
        )

        let updatedMatches = ProjectSearchEngine.shared.recalculateMatches(query: query, in: mb)
        XCTAssertEqual(updatedMatches.count, 0)
        XCTAssertTrue(mb.excerpts.isEmpty)
    }

    func testSearchStreamingWithWholeWord() async throws {
        try createTestFile(
            relative: "WordMatch.swift",
            content: """
            let task = 1
            let taskManager = 2
            let subtask = 3
            let task_id = 4
            print(task)
            """
        )

        let query = ProjectSearchQuery(query: "task", isWholeWord: true)

        let result = await ProjectSearchEngine.shared.searchStreaming(
            query: query,
            in: tempDirectory.path,
            onBatch: { _ in }
        )

        XCTAssertEqual(result.totalMatchesCount, 2)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.matches[0].lineNumber, 1)
        XCTAssertEqual(result.matches[1].lineNumber, 5)
    }

    func testSearchAndSliceWithLatin1Encoding() throws {
        // Construct Latin-1 bytes with 0xE9 (é) which is invalid UTF-8 on its own
        let latin1Data = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x73, 0x70, 0x65, 0x63, 0x69, 0x61, 0x6C, 0x0A]) // "café special\n"
        _ = try createTestBinaryFile(relative: "latin1.txt", data: latin1Data)

        let query = ProjectSearchQuery(query: "special")
        let mb = MultiBuffer()
        let result = ProjectSearchEngine.shared.search(query: query, in: tempDirectory.path, populating: mb)

        XCTAssertEqual(result.totalMatchesCount, 1)
        XCTAssertEqual(mb.excerpts.count, 1)
        XCTAssertEqual(mb.buffers.count, 1)
        XCTAssertTrue(mb.buffers.values.first?.lines.first?.contains("special") == true)
        XCTAssertTrue(mb.line(at: 0).contains("special"))
    }
}

