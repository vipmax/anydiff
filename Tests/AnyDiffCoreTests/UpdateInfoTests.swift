import XCTest
@testable import AnyDiffCore

final class UpdateInfoTests: XCTestCase {
    func testUpdateInfoSurvivesJSONRoundTrip() throws {
        let info = UpdateInfo(
            version: SemanticVersion(major: 1, minor: 6, patch: 0),
            releaseURL: URL(string: "https://github.com/vipmax/anydiff/releases/tag/v1.6.0")!,
            notes: "Notes"
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(UpdateInfo.self, from: data)

        XCTAssertEqual(decoded, info)
    }
}
