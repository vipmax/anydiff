import Foundation
import CoreServices

/// Represents a detected file system change event from FSEvents.
public struct FileSystemChangeEvent: Sendable, Equatable {
    public enum ChangeType: Sendable, Equatable {
        case created
        case removed
        case modified
        case renamed
        case inodeMetaMod
        case unknown
    }

    public let path: String
    public let eventId: UInt64
    public let rawFlags: UInt32
    public let isDirectory: Bool
    public let isFile: Bool
    public let changeTypes: [ChangeType]

    public init(path: String, eventId: UInt64, rawFlags: UInt32) {
        self.path = path
        self.eventId = eventId
        self.rawFlags = rawFlags

        self.isDirectory = (rawFlags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
        self.isFile = (rawFlags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0

        var types: [ChangeType] = []
        if (rawFlags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
            types.append(.created)
        }
        if (rawFlags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
            types.append(.removed)
        }
        if (rawFlags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 {
            types.append(.modified)
        }
        if (rawFlags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
            types.append(.renamed)
        }
        if (rawFlags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0 {
            types.append(.inodeMetaMod)
        }
        if types.isEmpty {
            types.append(.unknown)
        }
        self.changeTypes = types
    }
}

/// High-performance recursive folder watcher using macOS native `FSEvents` (CoreServices).
/// Provides zero-dependency, low-latency file system change monitoring with debouncing.
public final class FolderWatcher: @unchecked Sendable {
    public let watchedURL: URL
    public let latency: TimeInterval

    private var streamRef: FSEventStreamRef?
    private let queue: DispatchQueue
    private var isRunning: Bool = false
    private let lock = NSLock()

    public var onEvents: (@Sendable ([FileSystemChangeEvent]) -> Void)?

    public init(
        url: URL,
        latency: TimeInterval = 0.25,
        queue: DispatchQueue = DispatchQueue(label: "com.anydiff.folderwatcher", qos: .utility),
        onEvents: (@Sendable ([FileSystemChangeEvent]) -> Void)? = nil
    ) {
        self.watchedURL = url.resolvingSymlinksInPath()
        self.latency = latency
        self.queue = queue
        self.onEvents = onEvents
    }

    /// Convenience initializer using a string path.
    public convenience init(
        path: String,
        latency: TimeInterval = 0.25,
        queue: DispatchQueue = DispatchQueue(label: "com.anydiff.folderwatcher", qos: .utility),
        onEvents: (@Sendable ([FileSystemChangeEvent]) -> Void)? = nil
    ) {
        self.init(url: URL(fileURLWithPath: path), latency: latency, queue: queue, onEvents: onEvents)
    }

    deinit {
        stop()
    }

    /// Starts watching the folder hierarchy.
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [watchedURL.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

            var events: [FileSystemChangeEvent] = []
            events.reserveCapacity(numEvents)

            for i in 0..<numEvents {
                let path = paths[i]
                let flag = eventFlags[i]
                let id = eventIds[i]

                // Filter out system transient noise
                if FolderWatcher.shouldIgnore(path: path) {
                    continue
                }

                let changeEvent = FileSystemChangeEvent(path: path, eventId: id, rawFlags: flag)
                events.append(changeEvent)
            }

            if !events.isEmpty {
                watcher.onEvents?(events)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if FSEventStreamStart(stream) {
            self.isRunning = true
        } else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.streamRef = nil
        }
    }

    /// Stops watching the folder and releases the underlying stream.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning, let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.streamRef = nil
        self.isRunning = false
    }

    /// Returns whether the watcher is currently active.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    /// Checks if a file path is system, editor, or build artifact noise that should not trigger watch events.
    public static func shouldIgnore(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent

        // MARK: - 1. OS Metadata, Atomic Saves & Temporary Editor Files
        // macOS metadata (.DS_Store, AppleDouble ._*), Foundation atomic saves (.sb-*, .sbt-*),
        // and Vim/Emacs/Nano/IDE swap and backup files
        if name == ".DS_Store" || name.hasPrefix("._") || name.contains(".sb-") || name.contains(".sbt-")
            || name.hasSuffix(".swp") || name.hasSuffix(".swo") || name.hasSuffix(".swx")
            || name.hasSuffix("~") || name.hasSuffix(".tmp") || name.hasSuffix(".bak") || name.hasSuffix(".orig")
            || name.hasPrefix(".#") || name.hasPrefix("#") || name.hasPrefix(".goutputstream-") {
            return true
        }

        // MARK: - 2. Git Internals
        // Ignore internal git operations (index, objects, logs, pack, locks),
        // but allow branch ref switches (.git/HEAD, .git/refs/heads/*)
        if path.contains("/.git/") || path.hasSuffix("/.git") {
            if !path.hasSuffix("/.git/HEAD") && !path.contains("/.git/refs/heads/") {
                return true
            }
        }

        // MARK: - 3. Swift / Xcode / Apple Ecosystem
        // Swift Package Manager (.build), Xcode DerivedData, SwiftPM caches, Xcode user schemes
        if path.contains("/.build/") || path.hasSuffix("/.build")
            || path.contains("/DerivedData/") || path.hasSuffix("/DerivedData")
            || path.contains("/.swiftpm/") || path.hasSuffix("/.swiftpm")
            || path.contains("/xcuserdata/") {
            return true
        }

        // MARK: - 4. Rust / Cargo
        // Cargo build artifact directory (`target/`)
        if path.contains("/target/") || path.hasSuffix("/target") {
            return true
        }

        // MARK: - 5. JavaScript / TypeScript / Web (Node, Bun, Deno, Next.js, etc.)
        // Dependencies, build bundles, and framework caches
        if path.contains("/node_modules/") || path.hasSuffix("/node_modules")
            || path.contains("/.next/") || path.hasSuffix("/.next")
            || path.contains("/.nuxt/") || path.hasSuffix("/.nuxt")
            || path.contains("/.svelte-kit/") || path.hasSuffix("/.svelte-kit")
            || path.contains("/.turbo/") || path.hasSuffix("/.turbo")
            || path.contains("/.parcel-cache/") || path.hasSuffix("/.parcel-cache")
            || path.contains("/dist/") || path.hasSuffix("/dist") {
            return true
        }

        // MARK: - 6. Python
        // Bytecode caches and virtual environments
        if path.contains("/__pycache__/") || path.hasSuffix("/__pycache__")
            || name.hasSuffix(".pyc") || name.hasSuffix(".pyo")
            || path.contains("/.venv/") || path.hasSuffix("/.venv")
            || path.contains("/venv/") || path.hasSuffix("/venv")
            || path.contains("/.pytest_cache/") || path.hasSuffix("/.pytest_cache")
            || path.contains("/.mypy_cache/") || path.hasSuffix("/.mypy_cache")
            || path.contains("/.ruff_cache/") || path.hasSuffix("/.ruff_cache") {
            return true
        }

        // MARK: - 7. Java / Kotlin / JVM / Scala (Gradle, Maven, Metals)
        // Gradle build cache, Maven target directory, Metals IDE cache
        if path.contains("/.gradle/") || path.hasSuffix("/.gradle")
            || path.contains("/.metals/") || path.hasSuffix("/.metals")
            || path.contains("/.bloop/") || path.hasSuffix("/.bloop") {
            return true
        }

        // MARK: - 8. C / C++ / CMake / Generic Build Outputs
        // CMake build directories and compiled binary object files
        if path.contains("/cmake-build-") || path.contains("/.cmake/")
            || name.hasSuffix(".o") || name.hasSuffix(".obj") || name.hasSuffix(".dylib") || name.hasSuffix(".so") || name.hasSuffix(".a") {
            return true
        }

        // MARK: - 9. Go
        // Go build cache
        if path.contains("/.cache/go-build/") {
            return true
        }

        // MARK: - 10. .NET / C#
        // Binary build outputs and intermediate objects
        if path.contains("/bin/Debug/") || path.contains("/bin/Release/")
            || path.contains("/obj/Debug/") || path.contains("/obj/Release/") {
            return true
        }

        // MARK: - 11. Elixir / Ruby / PHP
        // Mix / Bundler / Composer dependencies and build folders
        if path.contains("/_build/") || path.hasSuffix("/_build")
            || path.contains("/.elixir_ls/") || path.hasSuffix("/.elixir_ls")
            || path.contains("/.bundle/") || path.hasSuffix("/.bundle")
            || path.contains("/vendor/bundle/") {
            return true
        }

        return false
    }
}

// MARK: - Swift Concurrency AsyncStream

extension FolderWatcher {
    /// Creates an `AsyncStream` that yields file change event batches as they occur on disk.
    public static func events(
        for url: URL,
        latency: TimeInterval = 0.25
    ) -> AsyncStream<[FileSystemChangeEvent]> {
        AsyncStream { continuation in
            let watcher = FolderWatcher(url: url, latency: latency) { events in
                continuation.yield(events)
            }
            watcher.start()
            continuation.onTermination = { _ in
                watcher.stop()
            }
        }
    }

    /// Creates an `AsyncStream` that yields file change event batches for a path string.
    public static func events(
        forPath path: String,
        latency: TimeInterval = 0.25
    ) -> AsyncStream<[FileSystemChangeEvent]> {
        events(for: URL(fileURLWithPath: path), latency: latency)
    }
}
