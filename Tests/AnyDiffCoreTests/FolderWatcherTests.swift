import XCTest
@testable import AnyDiffCore

final class FolderWatcherTests: XCTestCase {
    var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDiffWatcherTests_\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }

    func testShouldIgnoreFilter() {
        // OS & editor noise & atomic save temp files
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/.DS_Store"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/._test.txt"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/file.swift.swp"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/file.swift~"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/file.tmp"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/file.bak"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/main.swift.sb-38ab716b-w7Jd8k"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/main.swift.sbt-12345"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/path/to/.#main.swift"))

        // Git internals vs branch refs
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.git/index.lock"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.git/objects/1a/2b3c"))
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/.git/HEAD"))
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/.git/refs/heads/main"))

        // Rust / Cargo
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/target/debug/app"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/target/release/build/foo.o"))

        // Swift / Xcode
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.build/debug/app"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/DerivedData/Module/Build/Products"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.swiftpm/xcode/package.xcworkspace"))

        // Web / Node / Next.js
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/node_modules/lodash/index.js"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.next/server/pages/index.js"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.turbo/cache/123"))

        // Python
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/__pycache__/app.cpython-311.pyc"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.venv/lib/python3.11/site-packages"))

        // Java / Kotlin / Gradle
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/.gradle/caches/modules-2"))

        // C / C++ / CMake
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/cmake-build-debug/CMakeFiles/rules.ninja"))
        XCTAssertTrue(FolderWatcher.shouldIgnore(path: "/project/main.o"))

        // Real code files must NOT be ignored
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/Sources/main.swift"))
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/src/main.rs"))
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/README.md"))
        XCTAssertFalse(FolderWatcher.shouldIgnore(path: "/project/new_file.txt"))
    }

    private final class SafeEventsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [FileSystemChangeEvent] = []

        func append(_ events: [FileSystemChangeEvent]) {
            lock.lock()
            defer { lock.unlock() }
            _events.append(contentsOf: events)
        }

        var events: [FileSystemChangeEvent] {
            lock.lock()
            defer { lock.unlock() }
            return _events
        }
    }

    func testFolderWatcherDetectsFileCreationAndModification() throws {
        try requireIntegrationTestsEnabled()

        let expectation = XCTestExpectation(description: "Detects file creation")
        let box = SafeEventsBox()

        let watcher = FolderWatcher(url: tempDirectory, latency: 0.05) { events in
            box.append(events)
            if events.contains(where: { $0.path.contains("created_file.txt") }) {
                expectation.fulfill()
            }
        }

        watcher.start()
        XCTAssertTrue(watcher.isActive)

        // Allow FSEvents stream to initialize
        Thread.sleep(forTimeInterval: 0.1)

        // Create a new file
        let newFile = tempDirectory.appendingPathComponent("created_file.txt")
        try "initial content".write(to: newFile, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5.0)

        let received = box.events
        XCTAssertFalse(received.isEmpty)
        let matching = received.first { $0.path.contains("created_file.txt") }
        XCTAssertNotNil(matching)

        watcher.stop()
        XCTAssertFalse(watcher.isActive)
    }

    func testFolderWatcherDetectsFileDeletion() throws {
        try requireIntegrationTestsEnabled()

        let file = tempDirectory.appendingPathComponent("to_delete.txt")
        try "will delete".write(to: file, atomically: true, encoding: .utf8)

        let expectation = XCTestExpectation(description: "Detects file deletion")
        let box = SafeEventsBox()

        let watcher = FolderWatcher(url: tempDirectory, latency: 0.05) { events in
            box.append(events)
            if events.contains(where: { $0.path.contains("to_delete.txt") }) {
                expectation.fulfill()
            }
        }

        watcher.start()
        Thread.sleep(forTimeInterval: 0.1)

        try FileManager.default.removeItem(at: file)

        wait(for: [expectation], timeout: 5.0)
        XCTAssertFalse(box.events.isEmpty)

        watcher.stop()
    }

    func testFolderWatcherAsyncStream() async throws {
        try requireIntegrationTestsEnabled()

        let file = tempDirectory.appendingPathComponent("async_test.txt")
        let stream = FolderWatcher.events(for: tempDirectory, latency: 0.05)

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? "async content".write(to: file, atomically: true, encoding: .utf8)
        }

        var detected = false
        for await events in stream {
            if events.contains(where: { $0.path.contains("async_test.txt") }) {
                detected = true
                break
            }
        }

        XCTAssertTrue(detected)
    }
}
