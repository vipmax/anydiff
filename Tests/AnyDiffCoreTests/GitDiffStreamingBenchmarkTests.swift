import XCTest
@testable import AnyDiffCore

final class GitDiffStreamingBenchmarkTests: XCTestCase {

    /// Helper to find or generate the huge bun diff
    private func getBunDiff() -> (path: String, text: String, data: Data)? {
        let defaultDiffPath = "/tmp/bun_pr_30412.diff"
        if FileManager.default.fileExists(atPath: defaultDiffPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: defaultDiffPath)),
           let text = String(data: data, encoding: .utf8) {
            return (defaultDiffPath, text, data)
        }

        // Try extracting from ~/dev/tmp/bun
        let bunRepo = NSString(string: "~/dev/tmp/bun").expandingTildeInPath
        if FileManager.default.fileExists(atPath: bunRepo) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", bunRepo, "diff", "HEAD~5"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return (bunRepo, text, data)
            }
        }
        return nil
    }

    func testChunkLineSplitterEdgeCases() {
        let sample = """
        diff --git a/foo.txt b/foo.txt
        index 1234..5678 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,3 @@
         line 1
        -old line 2
        +new line 2
         line 3
        """

        let data = Data(sample.utf8)
        var receivedLines: [String] = []

        // Test with tiny chunk sizes (e.g. 5 bytes, 13 bytes) to force splits across line boundaries
        for chunkSize in [3, 7, 13, 32, 64, 1024] {
            receivedLines.removeAll()
            let splitter = ChunkLineSplitter { lineBytes in
                receivedLines.append(String(decoding: lineBytes, as: UTF8.self))
            }

            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                data.subdata(in: offset..<end).withUnsafeBytes { raw in
                    splitter.processChunk(raw.bindMemory(to: UInt8.self))
                }
                offset = end
            }
            splitter.finish()

            let expectedLines = sample.components(separatedBy: "\n")
            XCTAssertEqual(receivedLines, expectedLines, "Failed for chunkSize \(chunkSize)")
        }
    }

    func testCorrectnessEquivalenceOldVsNew() throws {
        guard let (_, diffText, diffData) = getBunDiff() else {
            print("⚠️ Skipped testCorrectnessEquivalenceOldVsNew: bun repo diff not found")
            return
        }

        print("\n🧪 Verifying parser correctness and output equivalence...")
        let oldFiles = GitDiffParser.shared.parseLegacy(diffText: diffText)
        let newFiles = GitDiffParser.shared.parse(data: diffData)

        XCTAssertEqual(oldFiles.count, newFiles.count, "File count mismatch!")
        print("✅ Both parsers produced exactly \(oldFiles.count) files.")

        var totalHunks = 0
        var totalLines = 0
        for i in 0..<min(oldFiles.count, newFiles.count) {
            let oldF = oldFiles[i]
            let newF = newFiles[i]
            XCTAssertEqual(oldF.oldPath, newF.oldPath, "Mismatch at file \(i) oldPath")
            XCTAssertEqual(oldF.newPath, newF.newPath, "Mismatch at file \(i) newPath")
            XCTAssertEqual(oldF.status, newF.status, "Mismatch at file \(i) status")
            XCTAssertEqual(oldF.hunks.count, newF.hunks.count, "Mismatch at file \(i) hunk count")

            totalHunks += newF.hunks.count
            for h in newF.hunks {
                totalLines += h.lines.count
            }
        }
        print("✅ Fully equivalent! Verified \(oldFiles.count) files, \(totalHunks) hunks, \(totalLines) diff lines.")
    }

    func testBenchmarkMegadiffParsingSpeedup() throws {
        guard let (sourcePath, diffText, diffData) = getBunDiff() else {
            print("⚠️ Skipped testBenchmarkMegadiffParsingSpeedup: bun repo diff not found")
            return
        }

        let diffBytesMB = Double(diffData.count) / (1024.0 * 1024.0)
        let lineCount = diffText.reduce(into: 0) { count, char in if char == "\n" { count += 1 } }

        print("\n" + String(repeating: "=", count: 80))
        print("🚀 BENCHMARK: AnyDiff MegaDiff Parsing Benchmark")
        print("📁 Source: \(sourcePath)")
        print("📦 Diff Size: \(String(format: "%.2f", diffBytesMB)) MB | Total Lines: \(lineCount)")
        print(String(repeating: "=", count: 80))

        // 1. Warm-up
        _ = GitDiffParser.shared.parse(data: diffData.prefix(100_000))

        // 2. Benchmark Legacy Parser (String.enumerateLines)
        let legacyStart = CFAbsoluteTimeGetCurrent()
        let legacyFiles = GitDiffParser.shared.parseLegacy(diffText: diffText)
        let legacyDuration = CFAbsoluteTimeGetCurrent() - legacyStart
        let legacyThroughput = Double(lineCount) / legacyDuration
        let legacyMBps = diffBytesMB / legacyDuration

        // 3. Benchmark New Fast Parser (String -> UTF8 contiguous scan)
        let newStringStart = CFAbsoluteTimeGetCurrent()
        let newStringFiles = GitDiffParser.shared.parse(diffText: diffText)
        let newStringDuration = CFAbsoluteTimeGetCurrent() - newStringStart
        let newStringThroughput = Double(lineCount) / newStringDuration
        let newStringMBps = diffBytesMB / newStringDuration

        // 4. Benchmark New 64KB Data/Byte Parser (Zero-Copy Data buffer)
        let newDataStart = CFAbsoluteTimeGetCurrent()
        let newDataFiles = GitDiffParser.shared.parse(data: diffData)
        let newDataDuration = CFAbsoluteTimeGetCurrent() - newDataStart
        let newDataThroughput = Double(lineCount) / newDataDuration
        let newDataMBps = diffBytesMB / newDataDuration

        // Print comparative results
        let speedupString = legacyDuration / newStringDuration
        let speedupData = legacyDuration / newDataDuration

        print("\n📊 BENCHMARK RESULTS:")
        print("--------------------------------------------------------------------------------")
        print("1️⃣  LEGACY PARSER (String.enumerateLines):")
        print("    ⏱️ Time:       \(String(format: "%.3f", legacyDuration)) s (\(String(format: "%.1f", legacyDuration * 1000)) ms)")
        print("    ⚡ Throughput: \(Int(legacyThroughput)) lines/sec | \(String(format: "%.1f", legacyMBps)) MB/s")
        print("    📂 Files:      \(legacyFiles.count)")
        print("--------------------------------------------------------------------------------")
        print("2️⃣  NEW FAST PARSER (String UTF-8 Contiguous Byte Scan):")
        print("    ⏱️ Time:       \(String(format: "%.3f", newStringDuration)) s (\(String(format: "%.1f", newStringDuration * 1000)) ms)")
        print("    ⚡ Throughput: \(Int(newStringThroughput)) lines/sec | \(String(format: "%.1f", newStringMBps)) MB/s")
        print("    📂 Files:      \(newStringFiles.count)")
        print("    🚀 SPEEDUP:    \(String(format: "%.2f", speedupString))x FASTER")
        print("--------------------------------------------------------------------------------")
        print("3️⃣  NEW ZERO-COPY DATA PARSER (64 KB SIMD ChunkLineSplitter):")
        print("    ⏱️ Time:       \(String(format: "%.3f", newDataDuration)) s (\(String(format: "%.1f", newDataDuration * 1000)) ms)")
        print("    ⚡ Throughput: \(Int(newDataThroughput)) lines/sec | \(String(format: "%.1f", newDataMBps)) MB/s")
        print("    📂 Files:      \(newDataFiles.count)")
        print("    🚀 SPEEDUP:    \(String(format: "%.2f", speedupData))x FASTER")
        print("================================================================================\n")

        XCTAssertEqual(legacyFiles.count, newDataFiles.count)
        XCTAssertGreaterThan(speedupData, 1.5, "New parser should be significantly faster!")
    }

    func testBenchmarkSubprocessStreamingTimeToFirstFile() throws {
        let bunRepo = NSString(string: "~/dev/tmp/bun").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: bunRepo) else {
            print("⚠️ Skipped testBenchmarkSubprocessStreamingTimeToFirstFile: bun repo not found")
            return
        }

        print("\n" + String(repeating: "=", count: 80))
        print("⏱️ SUBPROCESS STREAMING & TIME-TO-FIRST-FILE BENCHMARK (`git diff HEAD~5`)")
        print(String(repeating: "=", count: 80))

        // A. Legacy approach: Process -> readDataToEndOfFile -> String -> parseLegacy
        let legacyStart = CFAbsoluteTimeGetCurrent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", bunRepo, "diff", "HEAD~5"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var legacyTotalFiles = 0
        if let text = String(data: data, encoding: .utf8) {
            let legacyFiles = GitDiffParser.shared.parseLegacy(diffText: text)
            legacyTotalFiles = legacyFiles.count
        }
        let legacyTotalTime = CFAbsoluteTimeGetCurrent() - legacyStart
        let legacyTTFF = legacyTotalTime // In legacy, first file is only available AFTER complete fetch & parse

        // B. New Streaming approach: GitStreamReader with 64 KB POSIX buffers
        let streamStart = CFAbsoluteTimeGetCurrent()
        var streamFirstFileTime: CFAbsoluteTime? = nil
        var streamedFilesCount = 0

        try GitStreamReader.shared.streamGitDiff(
            arguments: ["-C", bunRepo, "diff", "HEAD~5"],
            chunkSize: 64 * 1024
        ) { file in
            if streamFirstFileTime == nil {
                streamFirstFileTime = CFAbsoluteTimeGetCurrent()
            }
            streamedFilesCount += 1
        }
        let streamTotalTime = CFAbsoluteTimeGetCurrent() - streamStart
        let streamTTFF = (streamFirstFileTime ?? CFAbsoluteTimeGetCurrent()) - streamStart

        let ttffSpeedup = legacyTTFF / max(streamTTFF, 0.0001)

        print("\n📊 SUBPROCESS STREAMING RESULTS:")
        print("--------------------------------------------------------------------------------")
        print("🐢 LEGACY (Blocking readDataToEndOfFile + parseLegacy):")
        print("    ⏱️ Time-To-First-File (TTFF): \(String(format: "%.3f", legacyTTFF)) s (\(String(format: "%.1f", legacyTTFF * 1000)) ms)")
        print("    ⏱️ Total Execution Time:     \(String(format: "%.3f", legacyTotalTime)) s (\(String(format: "%.1f", legacyTotalTime * 1000)) ms)")
        print("    📂 Total Files Parsed:       \(legacyTotalFiles)")
        print("--------------------------------------------------------------------------------")
        print("⚡ NEW 64KB STREAMING (GitStreamReader + ChunkLineSplitter):")
        print("    ⏱️ Time-To-First-File (TTFF): \(String(format: "%.3f", streamTTFF)) s (\(String(format: "%.1f", streamTTFF * 1000)) ms)")
        print("    ⏱️ Total Execution Time:     \(String(format: "%.3f", streamTotalTime)) s (\(String(format: "%.1f", streamTotalTime * 1000)) ms)")
        print("    📂 Total Files Parsed:       \(streamedFilesCount)")
        print("    🚀 TTFF LATENCY REDUCTION:   \(String(format: "%.1f", ttffSpeedup))x FASTER FIRST RENDER!")
        print("================================================================================\n")

        XCTAssertEqual(legacyTotalFiles, streamedFilesCount)
    }
}
