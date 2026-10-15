import CryptoKit
import XCTest
@testable import AnyDiffCore

final class UpdateInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppBundle(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A fake Homebrew prefix with a Caskroom entry for AnyDiff and an executable `bin/brew`.
    private func makeHomebrewPrefix(withCaskroom: Bool = true, withBrew: Bool = true) throws -> URL {
        let prefix = try makeDirectory("brew-prefix")
        if withCaskroom {
            _ = try makeDirectory("brew-prefix/Caskroom/anydiff")
        }
        if withBrew {
            let brew = try makeDirectory("brew-prefix/bin").appendingPathComponent("brew")
            FileManager.default.createFile(
                atPath: brew.path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }
        return prefix
    }

    func testDetectsHomebrewWhenCaskroomBrewAndApplicationsAgree() throws {
        let prefix = try makeHomebrewPrefix()
        let applications = try makeDirectory("Applications")

        let method = InstallMethod.detect(
            bundleURL: applications.appendingPathComponent("AnyDiff.app"),
            homebrewPrefixes: [prefix],
            applicationsDirectories: [applications]
        )

        guard case .homebrewCask(let brew) = method else {
            return XCTFail("Expected Homebrew install, got \(method)")
        }
        XCTAssertEqual(brew.path, prefix.appendingPathComponent("bin/brew").path)
    }

    func testUsesDirectDownloadWithoutCaskroomEntry() throws {
        let prefix = try makeHomebrewPrefix(withCaskroom: false)
        let applications = try makeDirectory("Applications")

        let method = InstallMethod.detect(
            bundleURL: applications.appendingPathComponent("AnyDiff.app"),
            homebrewPrefixes: [prefix],
            applicationsDirectories: [applications]
        )

        XCTAssertEqual(method, .directDownload)
    }

    func testUsesDirectDownloadWithoutBrewBinary() throws {
        let prefix = try makeHomebrewPrefix(withBrew: false)
        let applications = try makeDirectory("Applications")

        let method = InstallMethod.detect(
            bundleURL: applications.appendingPathComponent("AnyDiff.app"),
            homebrewPrefixes: [prefix],
            applicationsDirectories: [applications]
        )

        XCTAssertEqual(method, .directDownload)
    }

    func testUsesDirectDownloadForCopyOutsideApplicationsFolders() throws {
        let prefix = try makeHomebrewPrefix()
        let applications = try makeDirectory("Applications")
        let downloads = try makeDirectory("Downloads")

        let method = InstallMethod.detect(
            bundleURL: downloads.appendingPathComponent("AnyDiff.app"),
            homebrewPrefixes: [prefix],
            applicationsDirectories: [applications]
        )

        XCTAssertEqual(method, .directDownload)
    }

    func testInstalledVersionReadsBundleInfoPlist() throws {
        let app = root.appendingPathComponent("AnyDiff.app")
        try makeAppBundle(at: app, version: "1.6.0")

        XCTAssertEqual(UpdateInstaller.installedVersion(of: app), SemanticVersion(major: 1, minor: 6, patch: 0))
        XCTAssertNil(UpdateInstaller.installedVersion(of: root.appendingPathComponent("Missing.app")))
    }

    func testDownloadReleaseStagesVerifiedAppAtReleaseVersion() async throws {
        let archive = try makeReleaseArchive(version: "1.6.0")
        let installed = try makeDirectory("Applications").appendingPathComponent("AnyDiff.app")
        let info = makeUpdate(sha256: sha256Hex(archive))

        let staging = try await UpdateInstaller(session: makeSession(serving: archive))
            .downloadRelease(info, replacing: installed)
        defer { try? FileManager.default.removeItem(at: staging) }

        XCTAssertEqual(
            UpdateInstaller.installedVersion(of: staging.appendingPathComponent("AnyDiff.app")),
            info.version
        )
    }

    func testDownloadReleaseRejectsChecksumMismatch() async throws {
        let archive = try makeReleaseArchive(version: "1.6.0")
        let installed = try makeDirectory("Applications").appendingPathComponent("AnyDiff.app")
        let info = makeUpdate(sha256: String(repeating: "0", count: 64))

        do {
            _ = try await UpdateInstaller(session: makeSession(serving: archive))
                .downloadRelease(info, replacing: installed)
            XCTFail("Expected checksumMismatch")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .checksumMismatch)
        }
    }

    func testDownloadReleaseRejectsArchiveWithDifferentVersion() async throws {
        let archive = try makeReleaseArchive(version: "1.5.0")
        let installed = try makeDirectory("Applications").appendingPathComponent("AnyDiff.app")
        let info = makeUpdate(sha256: sha256Hex(archive))

        do {
            _ = try await UpdateInstaller(session: makeSession(serving: archive))
                .downloadRelease(info, replacing: installed)
            XCTFail("Expected unexpectedBundle")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .unexpectedBundle)
        }
    }

    func testDownloadReleaseNeedsChecksumAndArchive() async {
        let installed = root.appendingPathComponent("Applications/AnyDiff.app")
        let info = makeUpdate(sha256: nil)

        do {
            _ = try await UpdateInstaller().downloadRelease(info, replacing: installed)
            XCTFail("Expected noDownloadForThisMac")
        } catch {
            XCTAssertEqual(error as? UpdateInstallError, .noDownloadForThisMac)
        }
    }

    private func makeUpdate(sha256: String?) -> UpdateInfo {
        UpdateInfo(
            version: SemanticVersion(major: 1, minor: 6, patch: 0),
            releaseURL: URL(string: "https://github.com/vipmax/anydiff/releases/tag/v1.6.0")!,
            notes: "",
            downloadURL: URL(string: "https://example.com/AnyDiff-macOS-arm64.zip"),
            sha256: sha256
        )
    }

    /// A zip shaped like the release asset: `AnyDiff.app` at its top level.
    private func makeReleaseArchive(version: String) throws -> Data {
        let source = try makeDirectory("source")
        try makeAppBundle(at: source.appendingPathComponent("AnyDiff.app"), version: version)
        let archive = root.appendingPathComponent("release-\(version).zip")
        try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.appendingPathComponent("AnyDiff.app").path, archive.path])
        return try Data(contentsOf: archive)
    }

    private func makeSession(serving data: Data) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        return URLSession(configuration: config)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class AppRelauncherTests: XCTestCase {
    private var root: URL!
    private var stubBin: URL!
    private var openedPath: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppRelauncherTests-\(UUID().uuidString)", isDirectory: true)
        stubBin = root.appendingPathComponent("bin", isDirectory: true)
        openedPath = root.appendingPathComponent("opened.txt")
        try FileManager.default.createDirectory(at: stubBin, withIntermediateDirectories: true)

        // Stands in for `open`: records the path it was asked to open instead of launching AnyDiff.
        let stub = stubBin.appendingPathComponent("open")
        try "#!/bin/sh\nprintf '%s' \"$1\" > '\(openedPath.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testSwapsInStagedAppAndReopensIt() throws {
        let app = root.appendingPathComponent("Applications/AnyDiff.app")
        try writeApp(at: app, marker: "old")
        let staging = root.appendingPathComponent("staging")
        try writeApp(at: staging.appendingPathComponent("AnyDiff.app"), marker: "new")

        try runHelper(replacing: app, stagingDirectory: staging)

        XCTAssertEqual(try marker(in: app), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path + ".previous"))
        XCTAssertEqual(try String(contentsOf: openedPath), app.path)
    }

    func testKeepsExistingAppWhenStagedCopyIsMissing() throws {
        let app = root.appendingPathComponent("Applications/AnyDiff.app")
        try writeApp(at: app, marker: "old")
        let emptyStaging = root.appendingPathComponent("empty-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyStaging, withIntermediateDirectories: true)

        try runHelper(replacing: app, stagingDirectory: emptyStaging)

        XCTAssertEqual(try marker(in: app), "old")
        XCTAssertEqual(try String(contentsOf: openedPath), app.path)
    }

    func testReopensWithoutSwappingWhenThereIsNoStagedApp() throws {
        let app = root.appendingPathComponent("Applications/AnyDiff.app")
        try writeApp(at: app, marker: "old")

        try runHelper(replacing: app, stagingDirectory: nil)

        XCTAssertEqual(try marker(in: app), "old")
        XCTAssertEqual(try String(contentsOf: openedPath), app.path)
    }

    /// Runs the helper as the app would after quitting: the pid it waits on has already exited.
    private func runHelper(replacing app: URL, stagingDirectory: URL?) throws {
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()

        let helper = AppRelauncher.makeHelper(
            replacing: app,
            stagingDirectory: stagingDirectory,
            afterExitOf: exited.processIdentifier
        )
        helper.environment = ["PATH": "\(stubBin.path):/usr/bin:/bin"]
        try helper.run()
        helper.waitUntilExit()
    }

    private func writeApp(at url: URL, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try marker.write(to: contents.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }
}

private func runTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed")
}
