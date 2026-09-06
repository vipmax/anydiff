import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Lightweight metadata snapshot tracking mtime (with nanosecond precision) and file size
/// for zero-allocation, sub-microsecond self-save detection without reading file text into memory.
public struct FileDiskState: Equatable, Sendable {
    public let mtimeSec: Int
    public let mtimeNsec: Int
    public let size: Int64

    public init(mtimeSec: Int, mtimeNsec: Int, size: Int64) {
        self.mtimeSec = mtimeSec
        self.mtimeNsec = mtimeNsec
        self.size = size
    }

    /// Queries the filesystem directly via POSIX `stat()` syscall.
    /// This performs no memory allocations and executes in ~1 microsecond.
    public static func query(path: String) -> FileDiskState? {
        var sb = Darwin.stat()
        let result = path.withCString { stat($0, &sb) }
        guard result == 0 else { return nil }
        return FileDiskState(
            mtimeSec: Int(sb.st_mtimespec.tv_sec),
            mtimeNsec: Int(sb.st_mtimespec.tv_nsec),
            size: Int64(sb.st_size)
        )
    }
}
