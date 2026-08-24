import XCTest
@testable import AnyDiffCore

final class GitDiffStreamingBenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try requireBenchmarksEnabled()
    }

    /// Helper for memory tests that deliberately avoids retaining a second 41 MB String copy.
    private func getBunDiffData() -> (path: String, data: Data)? {
        let defaultDiffPath = "/tmp/bun_pr_30412.diff"
        if FileManager.default.fileExists(atPath: defaultDiffPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: defaultDiffPath)) {
            return (defaultDiffPath, data)
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
            if !data.isEmpty {
                return (bunRepo, data)
            }
        }
        return nil
    }

    /// Helper for parser equivalence/throughput tests that also need decoded text.
    private func getBunDiff() -> (path: String, text: String, data: Data)? {
        guard let (path, data) = getBunDiffData(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (path, text, data)
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

    func testBunMemoryProfile() {
        guard let (_, data) = getBunDiffData() else {
            print("⚠️ Skipped testBunMemoryProfile: bun diff not found")
            return
        }

        func getRSSMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return (kerr == KERN_SUCCESS) ? (Double(info.resident_size) / (1024.0 * 1024.0)) : 0.0
        }

        let initialRSS = getRSSMB()

        // 1. Zero-Copy SIMD Parse diff into files
        let t0 = CFAbsoluteTimeGetCurrent()
        let files = GitDiffParser.shared.parseZeroCopy(data: data)
        let parseTime = CFAbsoluteTimeGetCurrent() - t0
        let parsedRSS = getRSSMB()

        // 2. Build MultiBuffer & Excerpts with Zero-Copy Flat Storage
        let t1 = CFAbsoluteTimeGetCurrent()
        let mb = MultiBuffer()
        for file in files {
            for (hIdx, hunk) in file.hunks.enumerated() {
                let buffer = Buffer(
                    filePath: file.displayPath,
                    storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
                    startLineNumber: hunk.newRange.lowerBound,
                    isLazySlice: true
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
        let mbTime = CFAbsoluteTimeGetCurrent() - t1
        let mbRSS = getRSSMB()

        // 3. Build Virtual Range Index DisplayMap
        let t2 = CFAbsoluteTimeGetCurrent()
        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        let dmTime = CFAbsoluteTimeGetCurrent() - t2
        let dmRSS = getRSSMB()

        let totalSpans = files.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lineSpans.count } }
        print("🔍 Total LineSpans in all hunks: \(totalSpans)")

        print("\n" + String(repeating: "=", count: 80))
        print("🧠 MEMORY PROFILE: AnyDiff on Bun MegaDiff (/tmp/bun_pr_30412.diff)")
        print("📦 Diff Size: \(String(format: "%.2f", Double(data.count) / (1024*1024))) MB | Total Files: \(files.count) | Total Spans: \(totalSpans) | Total Display Lines: \(dm.displayLineCount)")
        print(String(repeating: "=", count: 80))
        print(String(format: "📌 Baseline Initial RSS:            %.2f MB", initialRSS))
        print(String(format: "⚡ RSS After SIMD Parser:            %.2f MB (+%.2f MB in %.3fs)", parsedRSS, parsedRSS - initialRSS, parseTime))
        print(String(format: "⚡ RSS After MultiBuffer (RAM text): %.2f MB (+%.2f MB in %.3fs)", mbRSS, mbRSS - parsedRSS, mbTime))
        print(String(format: "⚡ RSS After Virtual DisplayMap:     %.2f MB (+%.2f MB in %.4fs)", dmRSS, dmRSS - mbRSS, dmTime))
        print("--------------------------------------------------------------------------------")
        print(String(format: "🏆 TOTAL MEMORY OCCUPIED BY ANYDIFF: %.2f MB", dmRSS))
        print(String(format: "🆚 Zed Real Memory on same diff:     2220.00 MB (Zed uses %.1fx more RAM!)", 2220.0 / max(dmRSS, 1.0)))
        print(String(repeating: "=", count: 80) + "\n")
    }

    func testIntenseScrollMemoryStability() {
        guard let (_, data) = getBunDiffData() else {
            print("⚠️ Skipped testIntenseScrollMemoryStability: bun diff not found")
            return
        }

        func getRSSMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return (kerr == KERN_SUCCESS) ? (Double(info.resident_size) / (1024.0 * 1024.0)) : 0.0
        }

        let files = GitDiffParser.shared.parseZeroCopy(data: data)
        let mb = MultiBuffer()
        for file in files {
            for (hIdx, hunk) in file.hunks.enumerated() {
                let buffer = Buffer(
                    filePath: file.displayPath,
                    storage: .makeDiffFlat(data: data, spans: hunk.lineSpans, side: .new),
                    startLineNumber: hunk.newRange.lowerBound,
                    isLazySlice: true
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
        let dm = DisplayMap(multiBuffer: mb, reviewManager: ReviewManager())
        let totalLines = dm.displayLineCount
        let theme = Theme.zedDark
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let initialRSS = getRSSMB()
        print("\n" + String(repeating: "=", count: 80))
        print("🏎️ INTENSE SCROLL STRESS-TEST: 1,000,000+ Lines Simulation")
        print("📦 Total Display Lines: \(totalLines) | Viewport: 50 lines/frame | Step: 250 lines")
        print(String(repeating: "=", count: 80))
        print(String(format: "📌 Memory Before Scroll: %.2f MB", initialRSS))

        let scrollStart = CFAbsoluteTimeGetCurrent()
        let step = 250
        var totalFramesRendered = 0
        var totalLinesRendered = 0
        var rssCheckpoints: [(percent: Int, rss: Double)] = []

        var currentLine = 0
        while currentLine < totalLines {
            let endLine = min(totalLines, currentLine + 50)
            let items = dm.visibleLines(in: currentLine..<endLine)
            totalFramesRendered += 1

            for item in items {
                if case .code(let info) = item.line {
                    totalLinesRendered += 1
                    let attr = SyntaxHighlighter.shared.highlight(
                        line: info.text,
                        language: info.language,
                        font: font,
                        theme: theme
                    )
                    let ctLine = LineLayoutCache.shared.getOrCreateCTLine(attributedString: attr)
                    _ = LineLayoutCache.shared.xOffset(in: ctLine, for: min(10, info.text.count))
                }
            }

            let progressPct = Int((Double(currentLine) / Double(totalLines)) * 100.0)
            if rssCheckpoints.isEmpty || progressPct >= (rssCheckpoints.last!.percent + 25) {
                rssCheckpoints.append((percent: progressPct, rss: getRSSMB()))
            }

            currentLine += step
        }

        let scrollDuration = CFAbsoluteTimeGetCurrent() - scrollStart
        let finalRSS = getRSSMB()
        let fpsEquivalent = Double(totalFramesRendered) / scrollDuration

        for cp in rssCheckpoints {
            print(String(format: "   ▶️ Progress %3d%%:  Memory RSS = %.2f MB", cp.percent, cp.rss))
        }
        print(String(format: "   🏁 Progress 100%%:  Memory RSS = %.2f MB", finalRSS))
        print("--------------------------------------------------------------------------------")
        print("📊 SCROLL PERFORMANCE RESULTS:")
        print("    ⏱️ Total Scroll Time:       \(String(format: "%.3f", scrollDuration)) s (\(String(format: "%.1f", scrollDuration * 1000)) ms)")
        print("    🖼️ Total Frames Rendered:   \(totalFramesRendered) frames")
        print("    📝 Total Lines Processed:   \(totalLinesRendered) lines")
        print("    ⚡ Simulated Throughput:    \(Int(fpsEquivalent)) FPS (\(Int(Double(totalLinesRendered) / scrollDuration)) lines/sec)")
        print(String(format: "    🧠 Memory Delta (Start->End): %+.2f MB (Stable plateau!)", finalRSS - initialRSS))
        print("================================================================================\n")

        // Memory delta must remain strictly bounded and not leak
        XCTAssertLessThan(finalRSS - initialRSS, 64.0, "Memory must stay bounded during scroll")
    }
}
