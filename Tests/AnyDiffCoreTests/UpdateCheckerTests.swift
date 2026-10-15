import XCTest
@testable import AnyDiffCore

final class UpdateCheckerTests: XCTestCase {
    private static let endpoint = URL(string: "https://example.com/releases/latest")!
    private let current = SemanticVersion(major: 1, minor: 6, patch: 0)

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeChecker(statusCode: Int = 200, json: String) -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(json.utf8))
        }
        return UpdateChecker(session: URLSession(configuration: config), endpoint: Self.endpoint)
    }

    private func releaseJSON(tag: String, assets: String? = nil) -> String {
        """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/vipmax/anydiff/releases/tag/\(tag)",
          "body": "Release notes"\(assets.map { ",\n  \"assets\": \($0)" } ?? "")
        }
        """
    }

    private static let assetsJSON = """
    [
      {"name": "AnyDiff-macOS-arm64.zip", "browser_download_url": "https://example.com/AnyDiff-macOS-arm64.zip", "digest": "sha256:abc123"},
      {"name": "AnyDiff-macOS-x86_64.zip", "browser_download_url": "https://example.com/AnyDiff-macOS-x86_64.zip", "digest": "sha256:def456"},
      {"name": "AnyDiff.dmg", "browser_download_url": "https://example.com/AnyDiff.dmg", "digest": "sha256:999999"}
    ]
    """

    func testReturnsUpdateWhenReleaseIsNewer() async throws {
        let checker = makeChecker(json: releaseJSON(tag: "v1.7.0"))

        let update = try await checker.latestUpdate(newerThan: current)

        XCTAssertEqual(update?.version, SemanticVersion(major: 1, minor: 7, patch: 0))
        XCTAssertEqual(update?.releaseURL, URL(string: "https://github.com/vipmax/anydiff/releases/tag/v1.7.0"))
        XCTAssertEqual(update?.notes, "Release notes")
    }

    func testReturnsNilWhenReleaseIsSameVersion() async throws {
        let checker = makeChecker(json: releaseJSON(tag: "1.6.0"))

        let update = try await checker.latestUpdate(newerThan: current)

        XCTAssertNil(update)
    }

    func testReturnsNilWhenReleaseIsOlder() async throws {
        let checker = makeChecker(json: releaseJSON(tag: "1.5.9"))

        let update = try await checker.latestUpdate(newerThan: current)

        XCTAssertNil(update)
    }

    func testPicksArchiveForThisArchitectureWithItsChecksum() async throws {
        let checker = makeChecker(json: releaseJSON(tag: "v1.7.0", assets: Self.assetsJSON))

        let update = try await checker.latestUpdate(newerThan: current)

        #if arch(arm64)
        let expectedChecksum = "abc123"
        #else
        let expectedChecksum = "def456"
        #endif
        XCTAssertEqual(update?.downloadURL?.lastPathComponent, UpdateChecker.appArchiveName)
        XCTAssertEqual(update?.sha256, expectedChecksum)
    }

    func testLeavesDownloadNilWhenReleaseHasNoArchiveForThisMac() async throws {
        let assets = #"[{"name": "AnyDiff.dmg", "browser_download_url": "https://example.com/AnyDiff.dmg", "digest": "sha256:999999"}]"#
        let checker = makeChecker(json: releaseJSON(tag: "v1.7.0", assets: assets))

        let update = try await checker.latestUpdate(newerThan: current)

        XCTAssertNotNil(update)
        XCTAssertNil(update?.downloadURL)
        XCTAssertNil(update?.sha256)
    }

    func testLeavesChecksumNilWhenGitHubOmitsDigest() async throws {
        let assets = #"[{"name": "AnyDiff-macOS-arm64.zip", "browser_download_url": "https://example.com/a.zip", "digest": null}]"#
        let checker = makeChecker(json: releaseJSON(tag: "v1.7.0", assets: assets))

        let update = try await checker.latestUpdate(newerThan: current)

        XCTAssertNotNil(update?.downloadURL)
        XCTAssertNil(update?.sha256)
    }

    func testThrowsBadResponseForNon200Status() async {
        let checker = makeChecker(statusCode: 404, json: "{}")

        do {
            _ = try await checker.latestUpdate(newerThan: current)
            XCTFail("Expected UpdateCheckError.badResponse")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .badResponse)
        }
    }

    func testThrowsUnrecognizedVersionForNonSemverTag() async {
        let checker = makeChecker(json: releaseJSON(tag: "nightly"))

        do {
            _ = try await checker.latestUpdate(newerThan: current)
            XCTFail("Expected UpdateCheckError.unrecognizedVersion")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .unrecognizedVersion("nightly"))
        }
    }
}
