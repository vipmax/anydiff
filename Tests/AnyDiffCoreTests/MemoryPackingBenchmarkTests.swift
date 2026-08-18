import XCTest
@testable import AnyDiffCore

final class MemoryPackingBenchmarkTests: XCTestCase {

    func testStructMemoryLayouts() {
        let mbpSize = MemoryLayout<MultiBufferPoint>.size
        let mbpStride = MemoryLayout<MultiBufferPoint>.stride
        let bpSize = MemoryLayout<BufferPoint>.size
        let bpStride = MemoryLayout<BufferPoint>.stride
        let rangeSize = MemoryLayout<DisplayMap.ExcerptSliceRange>.size
        let rangeStride = MemoryLayout<DisplayMap.ExcerptSliceRange>.stride

        print("""
        ================================================================================
        📦 MEMORY LAYOUT BENCHMARK: Core Struct Sizes
        ================================================================================
        1️⃣  MultiBufferPoint:
            📏 Size:   \(mbpSize) bytes (expected: 8 bytes)
            📐 Stride: \(mbpStride) bytes (passes in single 64-bit register x0)
        --------------------------------------------------------------------------------
        2️⃣  BufferPoint:
            📏 Size:   \(bpSize) bytes (expected: 8 bytes)
            📐 Stride: \(bpStride) bytes (passes in single 64-bit register x0)
        --------------------------------------------------------------------------------
        3️⃣  DisplayMap.ExcerptSliceRange:
            📏 Size:   \(rangeSize) bytes (expected: <= 36 bytes vs 96 bytes legacy)
            📐 Stride: \(rangeStride) bytes (fits in half a 64-byte Cache Line!)
        ================================================================================
        """)

        XCTAssertEqual(mbpSize, 8, "MultiBufferPoint must be packed to 8 bytes")
        XCTAssertEqual(mbpStride, 8, "MultiBufferPoint stride must be 8 bytes")
        XCTAssertEqual(bpSize, 8, "BufferPoint must be packed to 8 bytes")
        XCTAssertEqual(bpStride, 8, "BufferPoint stride must be 8 bytes")
        XCTAssertLessThanOrEqual(rangeSize, 36, "ExcerptSliceRange must be packed to <= 36 bytes")
    }

    func testWordDiffEngineThroughput() {
        let lineA = "    func processBufferData(chunk: UnsafeBufferPointer<UInt8>, offset: Int, count: Int) -> Bool {"
        let lineB = "    public func processBufferChunk(chunk: UnsafeBufferPointer<UInt8>, rawOffset: UInt32, byteCount: Int) -> Result<Bool, Error> {"

        let iterations = 20_000

        // Warmup
        for _ in 0..<500 {
            _ = WordDiffEngine.shared.diffWords(oldText: lineA, newText: lineB)
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WordDiffEngine.shared.diffWords(oldText: lineA, newText: lineB)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let opsPerSec = Double(iterations) / elapsed

        print("""
        ================================================================================
        ⚡ WORD-DIFF ENGINE (ZERO-ALLOCATION & L1-CACHE LCS) BENCHMARK
        ================================================================================
        📝 Old Line: "\(lineA)"
        📝 New Line: "\(lineB)"
        🔄 Iterations: \(iterations)
        ⏱️ Elapsed:    \(String(format: "%.3f", elapsed * 1000)) ms (\(String(format: "%.4f", elapsed)) s)
        🚀 Throughput: \(Int(opsPerSec)) word-diffs / sec (\(String(format: "%.2f", (elapsed / Double(iterations)) * 1_000_000)) µs per diff)
        ================================================================================
        """)

        XCTAssertGreaterThan(opsPerSec, 2_000, "WordDiffEngine must process at least 2k line pairs/sec in Debug mode")
    }

    func testDisplayMapCoordinateLookupThroughput() {
        let multiBuffer = MultiBuffer()
        let reviewManager = ReviewManager()

        // Construct a MultiBuffer with 1,000 excerpts (mimicking large multi-file diff)
        for i in 0..<1_000 {
            let hunk = DiffHunk(
                oldRange: (i * 20 + 1)..<(i * 20 + 21),
                newRange: (i * 25 + 1)..<(i * 25 + 26),
                header: "@@ -\(i * 20 + 1),20 +\(i * 25 + 1),25 @@",
                lines: (0..<25).map { r in
                    DiffLine(kind: (r % 3 == 0) ? .added : .unchanged, text: "let variable_\(i)_\(r) = \(r * 100)", oldLineNumber: i * 20 + r, newLineNumber: i * 25 + r)
                }
            )
            let buffer = Buffer(
                filePath: "File_\(i / 5).swift",
                text: hunk.lines.map(\.text).joined(separator: "\n"),
                startLineNumber: i * 25 + 1
            )
            multiBuffer.addBuffer(buffer)
            multiBuffer.addExcerpt(Excerpt(
                bufferId: buffer.id,
                filePath: "File_\(i / 5).swift",
                fileStatus: .modified,
                bufferRange: 0..<buffer.lineCount,
                hunk: hunk,
                isFileStart: (i % 5 == 0)
            ))
        }

        let displayMap = DisplayMap(multiBuffer: multiBuffer, reviewManager: reviewManager)
        let totalCodeRows = displayMap.codeLineCount

        let lookupIterations = 50_000

        // Benchmark binary-search coordinate translation: MultiBufferPoint -> BufferLocation
        let t0 = CFAbsoluteTimeGetCurrent()
        var validLookups = 0
        for k in 0..<lookupIterations {
            let row = (k * 73) % totalCodeRows
            let pt = MultiBufferPoint(row: row, column: 15)
            if let loc = displayMap.bufferLocation(for: pt) {
                validLookups += loc.point.row >= 0 ? 1 : 0
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let opsPerSec = Double(lookupIterations) / elapsed

        print("""
        ================================================================================
        🎯 DISPLAY MAP BINARY SEARCH COORDINATE MAPPING BENCHMARK
        ================================================================================
        📦 Total Excerpts:  \(displayMap.excerptLocations.count)
        📝 Total Code Rows: \(totalCodeRows)
        🔄 Lookups:         \(lookupIterations)
        ⏱️ Elapsed:         \(String(format: "%.3f", elapsed * 1000)) ms (\(String(format: "%.4f", elapsed)) s)
        🚀 Throughput:      \(Int(opsPerSec)) lookups / sec (\(String(format: "%.3f", (elapsed / Double(lookupIterations)) * 1_000_000)) µs per lookup)
        ================================================================================
        """)

        XCTAssertEqual(validLookups, lookupIterations)
        XCTAssertGreaterThan(opsPerSec, 50_000, "DisplayMap binary lookups must exceed 50k lookups/sec in Debug mode")
    }
}
