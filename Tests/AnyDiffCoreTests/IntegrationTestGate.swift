import XCTest

func requireIntegrationTestsEnabled() throws {
    guard ProcessInfo.processInfo.environment["ANYDIFF_RUN_INTEGRATION_TESTS"] == "1" else {
        throw XCTSkip("Integration test skipped. Run with ANYDIFF_RUN_INTEGRATION_TESTS=1 to enable it.")
    }
}
