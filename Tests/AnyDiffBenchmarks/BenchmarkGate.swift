import XCTest

func requireBenchmarksEnabled() throws {
    guard ProcessInfo.processInfo.environment["ANYDIFF_RUN_BENCHMARKS"] == "1" else {
        throw XCTSkip("Benchmark skipped. Run with ANYDIFF_RUN_BENCHMARKS=1 to enable it.")
    }
}
