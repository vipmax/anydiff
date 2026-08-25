import Foundation

public final class AgentImageStore: @unchecked Sendable {
    public static let shared = AgentImageStore()

    public let cacheDirectory: URL
    public let maxCacheSizeBytes: Int
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.anydiff.image-store", attributes: .concurrent)

    public init(
        customCacheDirectory: URL? = nil,
        maxCacheSizeBytes: Int = 500 * 1024 * 1024 // 500 MB default max limit
    ) {
        self.maxCacheSizeBytes = maxCacheSizeBytes
        if let custom = customCacheDirectory {
            self.cacheDirectory = custom
        } else if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.cacheDirectory = cachesURL.appendingPathComponent("anydiff/attachments", isDirectory: true)
        } else {
            self.cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anydiff_attachments", isDirectory: true)
        }

        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        enforceCacheLimitAsync()
    }

    /// Saves image data to disk cache and returns an AgentImageAttachment backed by disk.
    /// Automatically performs background cleanup if total cache size exceeds `maxCacheSizeBytes`.
    @discardableResult
    public func save(
        data: Data,
        mimeType: String = "image/png",
        filename: String? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) -> AgentImageAttachment {
        let id = UUID()
        let ext = fileExtension(for: mimeType)
        let fileURL = cacheDirectory.appendingPathComponent("\(id.uuidString).\(ext)")

        try? data.write(to: fileURL, options: .atomic)

        enforceCacheLimitAsync()

        return AgentImageAttachment(
            id: id,
            data: data,
            filePath: fileURL.path,
            mimeType: mimeType,
            filename: filename,
            width: width,
            height: height,
            fileSize: data.count
        )
    }

    /// Loads image data from disk by file path.
    public func loadData(at path: String) -> Data? {
        queue.sync {
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    /// Removes a specific cached attachment file from disk.
    public func delete(at path: String) {
        queue.async(flags: .barrier) {
            try? self.fileManager.removeItem(atPath: path)
        }
    }

    /// Calculates total size in bytes of all cached attachment files.
    public func currentCacheSize() -> Int {
        queue.sync {
            calculateCurrentCacheSizeSync()
        }
    }

    /// Enforces disk cache limit synchronously (useful in unit tests or explicit maintenance).
    public func enforceCacheLimitSync(limit: Int? = nil) {
        let targetMax = limit ?? maxCacheSizeBytes
        guard targetMax > 0 else { return }

        queue.sync(flags: .barrier) {
            performCacheEviction(targetLimit: targetMax)
        }
    }

    /// Cleans up older files or clears entire cache.
    public func clearAll() {
        queue.async(flags: .barrier) {
            try? self.fileManager.removeItem(at: self.cacheDirectory)
            try? self.fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        }
    }

    private func enforceCacheLimitAsync() {
        queue.async(flags: .barrier) {
            self.performCacheEviction(targetLimit: self.maxCacheSizeBytes)
        }
    }

    private func calculateCurrentCacheSizeSync() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return 0
        }

        var total = 0
        for file in files {
            if let resources = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = resources.fileSize {
                total += size
            }
        }
        return total
    }

    private func performCacheEviction(targetLimit: Int) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return
        }

        struct FileMeta {
            let url: URL
            let size: Int
            let date: Date
        }

        var fileMetas: [FileMeta] = []
        var totalSize = 0

        for file in files {
            guard let resources = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]),
                  let size = resources.fileSize else {
                continue
            }
            let date = resources.contentModificationDate ?? resources.creationDate ?? Date.distantPast
            fileMetas.append(FileMeta(url: file, size: size, date: date))
            totalSize += size
        }

        guard totalSize > targetLimit else { return }

        // Sort by date ascending: oldest files first
        fileMetas.sort { $0.date < $1.date }

        // Evict oldest files until we are within target limit (down to 80% of limit for headroom)
        let targetEvictionCeiling = Int(Double(targetLimit) * 0.8)

        for meta in fileMetas {
            guard totalSize > targetEvictionCeiling else { break }
            try? fileManager.removeItem(at: meta.url)
            totalSize -= meta.size
        }
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/tiff": return "tiff"
        case "image/svg+xml": return "svg"
        default: return "png"
        }
    }
}
