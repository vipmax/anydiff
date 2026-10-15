import XCTest
@testable import AnyDiffCore

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainAndVPrefixedVersions() {
        XCTAssertEqual(SemanticVersion("1.6.0"), SemanticVersion(major: 1, minor: 6, patch: 0))
        XCTAssertEqual(SemanticVersion("v2.0.11"), SemanticVersion(major: 2, minor: 0, patch: 11))
    }

    func testRejectsMalformedVersions() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("1.6"))
        XCTAssertNil(SemanticVersion("1.6.0.1"))
        XCTAssertNil(SemanticVersion("1.6.x"))
        XCTAssertNil(SemanticVersion("nightly"))
    }

    func testComparesNumericallyNotLexically() throws {
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.9.0")), try XCTUnwrap(SemanticVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.6.9")), try XCTUnwrap(SemanticVersion("1.7.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.6.0")), try XCTUnwrap(SemanticVersion("2.0.0")))
        let same = try XCTUnwrap(SemanticVersion("1.6.0"))
        XCTAssertFalse(same < same)
    }

    func testDescriptionOmitsVPrefix() {
        XCTAssertEqual(SemanticVersion("v1.6.0")?.description, "1.6.0")
    }
}
