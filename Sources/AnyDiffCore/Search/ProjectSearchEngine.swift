import Foundation

/// Parameters configuring a project-wide search
public struct ProjectSearchQuery: Sendable, Equatable {
    public var query: String
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool
    public var isRegex: Bool
    public var includePattern: String
    public var excludePattern: String
    public var contextLines: Int
    public var maxMatches: Int
    public var maxFileSize: Int

    public init(
        query: String = "",
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        isRegex: Bool = false,
        includePattern: String = "",
        excludePattern: String = "",
        contextLines: Int = 2,
        maxMatches: Int = 10000,
        maxFileSize: Int = 10 * 1024 * 1024
    ) {
        self.query = query
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.isRegex = isRegex
        self.includePattern = includePattern
        self.excludePattern = excludePattern
        self.contextLines = max(0, contextLines)
        self.maxMatches = max(1, maxMatches)
        self.maxFileSize = max(1, maxFileSize)
    }

    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A single matched occurrence inside a file
public struct ProjectSearchMatch: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var filePath: String
    public var fullDiskPath: String
    public var lineNumber: Int // 1-based line number in source file
    public var columnRange: Range<Int> // 0-based character column range in line
    public var lineText: String
    public var multiBufferRow: MultiBufferRow? // continuous row in MultiBuffer

    public init(
        id: UUID = UUID(),
        filePath: String,
        fullDiskPath: String,
        lineNumber: Int,
        columnRange: Range<Int>,
        lineText: String,
        multiBufferRow: MultiBufferRow? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.fullDiskPath = fullDiskPath
        self.lineNumber = lineNumber
        self.columnRange = columnRange
        self.lineText = lineText
        self.multiBufferRow = multiBufferRow
    }
}

/// File-level search summary
public struct ProjectSearchFileResult: Sendable, Equatable {
    public var filePath: String
    public var fullDiskPath: String
    public var matches: [ProjectSearchMatch]
    public var totalFileLineCount: Int

    public init(
        filePath: String,
        fullDiskPath: String,
        matches: [ProjectSearchMatch],
        totalFileLineCount: Int
    ) {
        self.filePath = filePath
        self.fullDiskPath = fullDiskPath
        self.matches = matches
        self.totalFileLineCount = totalFileLineCount
    }
}

/// Result of executing a project-wide search
public struct ProjectSearchResult: Sendable, Equatable {
    public var query: ProjectSearchQuery
    public var matches: [ProjectSearchMatch]
    public var fileResults: [ProjectSearchFileResult]
    public var totalFilesSearched: Int
    public var isTruncated: Bool
    public var duration: TimeInterval

    public init(
        query: ProjectSearchQuery,
        matches: [ProjectSearchMatch] = [],
        fileResults: [ProjectSearchFileResult] = [],
        totalFilesSearched: Int = 0,
        isTruncated: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.query = query
        self.matches = matches
        self.fileResults = fileResults
        self.totalFilesSearched = totalFilesSearched
        self.isTruncated = isTruncated
        self.duration = duration
    }

    public var totalMatchesCount: Int {
        matches.count
    }

    public var totalMatchingFilesCount: Int {
        fileResults.count
    }
}

/// A progressive batch of search results emitted during streaming search
public struct ProjectSearchBatch: Sendable {
    public let newBuffers: [Buffer]
    public let newExcerpts: [Excerpt]
    public let newMatches: [ProjectSearchMatch]
    public let totalMatchesSoFar: Int
    public let isTruncated: Bool
    public let isFinished: Bool

    public init(
        newBuffers: [Buffer] = [],
        newExcerpts: [Excerpt] = [],
        newMatches: [ProjectSearchMatch] = [],
        totalMatchesSoFar: Int = 0,
        isTruncated: Bool = false,
        isFinished: Bool = false
    ) {
        self.newBuffers = newBuffers
        self.newExcerpts = newExcerpts
        self.newMatches = newMatches
        self.totalMatchesSoFar = totalMatchesSoFar
        self.isTruncated = isTruncated
        self.isFinished = isFinished
    }
}

/// High-performance, memory-efficient search engine that populates a MultiBuffer with lazy context excerpts
public final class ProjectSearchEngine: @unchecked Sendable {
    public static let shared = ProjectSearchEngine()

    public static let defaultIgnoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "dist", "build",
        "target", "Pods", "Carthage", "DerivedData", ".svn", ".hg",
        ".bzr", ".cache", ".idea", ".vscode", ".gemini",
        ".zig-cache", "zig-out", "zig-cache", ".turbo", ".next", ".nuxt",
        "venv", ".venv", "env", ".env", "coverage", ".nyc_output", "vendor"
    ]

    public static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "ico", "icns", "tiff", "webp",
        "pdf", "zip", "tar", "gz", "bz2", "7z", "rar", "dmg", "pkg",
        "exe", "dll", "dylib", "so", "a", "o", "obj", "class", "jar",
        "pyc", "pyo", "mp3", "mp4", "mov", "wav", "avi", "mkv", "ttf",
        "otf", "woff", "woff2", "eot", "sqlite", "db", "bin", "dat",
        "pstop", "xcassets", "car"
    ]

    public static let defaultMaxFileSize: Int = 10 * 1024 * 1024 // 10 MB

    /// Checks whether the raw data appears to be a binary file by inspecting the first 4096 bytes for null bytes.
    public static func isBinary(data: Data) -> Bool {
        let probeLength = min(data.count, 4096)
        return data.prefix(probeLength).contains(0)
    }

    public init() {}

    private enum RegexCompilationResult {
        case regex(NSRegularExpression)
        case literal
        case failed
    }

    private func compileRegex(for query: ProjectSearchQuery) -> RegexCompilationResult {
        if query.isRegex {
            var options: NSRegularExpression.Options = []
            if !query.isCaseSensitive {
                options.insert(.caseInsensitive)
            }
            guard let regex = try? NSRegularExpression(pattern: query.query, options: options) else {
                return .failed
            }
            return .regex(regex)
        } else if query.isWholeWord {
            var options: NSRegularExpression.Options = []
            if !query.isCaseSensitive {
                options.insert(.caseInsensitive)
            }
            let escaped = NSRegularExpression.escapedPattern(for: query.query)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: options) else {
                return .failed
            }
            return .regex(regex)
        } else {
            return .literal
        }
    }

    /// Performs search across `rootDirectory` and populates the given `MultiBuffer` with lazy slices.
    public func search(
        query: ProjectSearchQuery,
        in rootDirectory: String,
        populating targetMultiBuffer: MultiBuffer? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> ProjectSearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard !query.isEmpty, FileManager.default.fileExists(atPath: rootDirectory) else {
            targetMultiBuffer?.clear()
            return ProjectSearchResult(query: query)
        }

        // 1. Prepare regex matcher or string matcher
        let regex: NSRegularExpression?
        switch compileRegex(for: query) {
        case .regex(let r):
            regex = r
        case .literal:
            regex = nil
        case .failed:
            targetMultiBuffer?.clear()
            return ProjectSearchResult(query: query)
        }

        // 2. Parse include and exclude glob patterns
        let includeGlobs = parseGlobPatterns(query.includePattern)
        let excludeGlobs = parseGlobPatterns(query.excludePattern)

        // 3. Collect candidate files
        let rootURL = URL(fileURLWithPath: rootDirectory).standardizedFileURL
        let candidateFiles = collectFiles(
            in: rootURL,
            includeGlobs: includeGlobs,
            excludeGlobs: excludeGlobs,
            maxFileSize: query.maxFileSize,
            isCancelled: isCancelled
        )

        if isCancelled?() == true {
            return ProjectSearchResult(query: query)
        }

        var allMatches: [ProjectSearchMatch] = []
        var fileResults: [ProjectSearchFileResult] = []
        var isTruncated = false

        // 4. Scan files line by line (memory-efficient streaming)
        let rootPath = rootURL.path
        for fileURL in candidateFiles {
            if isCancelled?() == true || isTruncated { break }

            let filePath = fileURL.standardizedFileURL.path
            let relativePath: String
            if filePath.hasPrefix(rootPath) {
                let suffix = String(filePath.dropFirst(rootPath.count))
                relativePath = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            } else {
                relativePath = fileURL.lastPathComponent
            }

            guard let fileMatches = scanFile(
                fileURL: fileURL,
                relativePath: relativePath,
                query: query,
                regex: regex,
                maxAllowed: query.maxMatches - allMatches.count
            ) else {
                continue
            }

            if !fileMatches.matches.isEmpty {
                allMatches.append(contentsOf: fileMatches.matches)
                fileResults.append(fileMatches)
                if allMatches.count >= query.maxMatches {
                    isTruncated = true
                    break
                }
            }
        }

        // 5. Populate MultiBuffer with lazy context slices
        if let mb = targetMultiBuffer {
            populate(multiBuffer: mb, with: fileResults, query: query, matches: &allMatches)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return ProjectSearchResult(
            query: query,
            matches: allMatches,
            fileResults: fileResults,
            totalFilesSearched: candidateFiles.count,
            isTruncated: isTruncated,
            duration: duration
        )
    }

    /// Asynchronously streams search results in progressive batches as they are discovered across the project.
    public func searchStreaming(
        query: ProjectSearchQuery,
        in rootDirectory: String,
        onBatch: @Sendable @escaping (ProjectSearchBatch) -> Void,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> ProjectSearchResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard !query.isEmpty, FileManager.default.fileExists(atPath: rootDirectory) else {
            onBatch(ProjectSearchBatch(isFinished: true))
            return ProjectSearchResult(query: query)
        }

        let regex: NSRegularExpression?
        switch compileRegex(for: query) {
        case .regex(let r):
            regex = r
        case .literal:
            regex = nil
        case .failed:
            onBatch(ProjectSearchBatch(isFinished: true))
            return ProjectSearchResult(query: query)
        }

        let includeGlobs = parseGlobPatterns(query.includePattern)
        let excludeGlobs = parseGlobPatterns(query.excludePattern)

        let rootURL = URL(fileURLWithPath: rootDirectory).standardizedFileURL
        let rootPath = rootURL.path

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            onBatch(ProjectSearchBatch(isFinished: true))
            return ProjectSearchResult(query: query)
        }

        var allMatches: [ProjectSearchMatch] = []
        var allFileResults: [ProjectSearchFileResult] = []
        var totalScannedFiles = 0
        var totalMatchingFiles = 0
        var runningMBRow = 0
        var isTruncated = false
        var lastYieldTime = CFAbsoluteTimeGetCurrent()
        var pendingFileResults: [ProjectSearchFileResult] = []
        var pendingMatchesCount = 0
        var currentChunk: [(url: URL, relativePath: String)] = []
        let chunkSize = 64

        let flushPending: (Bool) -> Void = { force in
            guard !pendingFileResults.isEmpty else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let isFirstBatch = (allMatches.isEmpty)
            if force || isFirstBatch || pendingMatchesCount >= 50 || (now - lastYieldTime) >= 0.08 {
                let built = self.buildSlices(for: pendingFileResults, query: query, startingMBRow: runningMBRow)
                runningMBRow = built.nextStartingMBRow
                allMatches.append(contentsOf: built.matches)
                onBatch(ProjectSearchBatch(
                    newBuffers: built.buffers,
                    newExcerpts: built.excerpts,
                    newMatches: built.matches,
                    totalMatchesSoFar: allMatches.count,
                    isTruncated: isTruncated,
                    isFinished: false
                ))
                pendingFileResults.removeAll(keepingCapacity: true)
                pendingMatchesCount = 0
                lastYieldTime = now
            }
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if isCancelled?() == true || isTruncated { break }

            let lastComponent = fileURL.lastPathComponent

            // Fast skip of ignored directories
            if Self.defaultIgnoredDirectories.contains(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }

            if resourceValues.isDirectory == true {
                if lastComponent.hasPrefix(".") && lastComponent != "." {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues.isRegularFile == true else { continue }

            if let size = resourceValues.fileSize, size > query.maxFileSize {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            if Self.binaryExtensions.contains(ext) {
                continue
            }

            let path = fileURL.standardizedFileURL.path
            let relativePath: String
            if path.hasPrefix(rootPath) {
                let suffix = String(path.dropFirst(rootPath.count))
                relativePath = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            } else {
                relativePath = lastComponent
            }

            if !includeGlobs.isEmpty {
                let matchedInclude = includeGlobs.contains { matchGlob($0, string: relativePath) || matchGlob($0, string: lastComponent) }
                if !matchedInclude { continue }
            }

            if !excludeGlobs.isEmpty {
                let matchedExclude = excludeGlobs.contains { matchGlob($0, string: relativePath) || matchGlob($0, string: lastComponent) }
                if matchedExclude { continue }
            }

            currentChunk.append((url: fileURL, relativePath: relativePath))
            if currentChunk.count >= chunkSize {
                let chunkToProcess = currentChunk
                currentChunk.removeAll(keepingCapacity: true)
                totalScannedFiles += chunkToProcess.count

                let remainingAllowed = query.maxMatches - (allMatches.count + pendingMatchesCount)
                if remainingAllowed <= 0 {
                    isTruncated = true
                    break
                }

                var chunkResults: [ProjectSearchFileResult] = []
                await withTaskGroup(of: ProjectSearchFileResult?.self) { group in
                    for item in chunkToProcess {
                        group.addTask {
                            if isCancelled?() == true { return nil }
                            return self.scanFile(
                                fileURL: item.url,
                                relativePath: item.relativePath,
                                query: query,
                                regex: regex,
                                maxAllowed: remainingAllowed
                            )
                        }
                    }
                    for await res in group {
                        if let res = res, !res.matches.isEmpty {
                            chunkResults.append(res)
                        }
                    }
                }

                if !chunkResults.isEmpty {
                    chunkResults.sort { $0.filePath < $1.filePath }
                    for res in chunkResults {
                        pendingFileResults.append(res)
                        allFileResults.append(res)
                        pendingMatchesCount += res.matches.count
                        totalMatchingFiles += 1
                        if (allMatches.count + pendingMatchesCount) >= query.maxMatches {
                            isTruncated = true
                            break
                        }
                    }
                    flushPending(false)
                }
            }
        }

        if !currentChunk.isEmpty && !isTruncated && isCancelled?() != true {
            let chunkToProcess = currentChunk
            totalScannedFiles += chunkToProcess.count
            let remainingAllowed = query.maxMatches - (allMatches.count + pendingMatchesCount)
            if remainingAllowed > 0 {
                var chunkResults: [ProjectSearchFileResult] = []
                await withTaskGroup(of: ProjectSearchFileResult?.self) { group in
                    for item in chunkToProcess {
                        group.addTask {
                            if isCancelled?() == true { return nil }
                            return self.scanFile(
                                fileURL: item.url,
                                relativePath: item.relativePath,
                                query: query,
                                regex: regex,
                                maxAllowed: remainingAllowed
                            )
                        }
                    }
                    for await res in group {
                        if let res = res, !res.matches.isEmpty {
                            chunkResults.append(res)
                        }
                    }
                }
                if !chunkResults.isEmpty {
                    chunkResults.sort { $0.filePath < $1.filePath }
                    for res in chunkResults {
                        pendingFileResults.append(res)
                        allFileResults.append(res)
                        pendingMatchesCount += res.matches.count
                        totalMatchingFiles += 1
                        if (allMatches.count + pendingMatchesCount) >= query.maxMatches {
                            isTruncated = true
                            break
                        }
                    }
                }
            }
        }

        flushPending(true)

        onBatch(ProjectSearchBatch(
            newBuffers: [],
            newExcerpts: [],
            newMatches: [],
            totalMatchesSoFar: allMatches.count,
            isTruncated: isTruncated,
            isFinished: true
        ))

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return ProjectSearchResult(
            query: query,
            matches: allMatches,
            fileResults: allFileResults,
            totalFilesSearched: totalScannedFiles,
            isTruncated: isTruncated,
            duration: duration
        )
    }

    // MARK: - Scanning & Context Clustering

    private func scanFile(
        fileURL: URL,
        relativePath: String,
        query: ProjectSearchQuery,
        regex: NSRegularExpression?,
        maxAllowed: Int
    ) -> ProjectSearchFileResult? {
        guard maxAllowed > 0 else { return nil }

        // Read file contents safely with size limit and binary null-byte check
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= query.maxFileSize,
              !Self.isBinary(data: data),
              let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")
        let totalLines = lines.count
        var matches: [ProjectSearchMatch] = []

        for (lineIdx, line) in lines.enumerated() {
            if matches.count >= maxAllowed { break }
            let lineNumber = lineIdx + 1

            if let regex = regex {
                let nsString = line as NSString
                let fullRange = NSRange(location: 0, length: nsString.length)
                let results = regex.matches(in: line, options: [], range: fullRange)
                for res in results {
                    if matches.count >= maxAllowed { break }
                    guard let strRange = Range(res.range, in: line) else { continue }
                    let startCol = line.distance(from: line.startIndex, to: strRange.lowerBound)
                    let endCol = line.distance(from: line.startIndex, to: strRange.upperBound)
                    matches.append(
                        ProjectSearchMatch(
                            filePath: relativePath,
                            fullDiskPath: fileURL.path,
                            lineNumber: lineNumber,
                            columnRange: startCol..<endCol,
                            lineText: line
                        )
                    )
                }
            } else {
                let searchStr = query.query
                var searchStart = line.startIndex
                let compareOptions: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]

                while searchStart < line.endIndex,
                      let foundRange = line.range(of: searchStr, options: compareOptions, range: searchStart..<line.endIndex) {
                    if matches.count >= maxAllowed { break }
                    let startCol = line.distance(from: line.startIndex, to: foundRange.lowerBound)
                    let endCol = line.distance(from: line.startIndex, to: foundRange.upperBound)
                    matches.append(
                        ProjectSearchMatch(
                            filePath: relativePath,
                            fullDiskPath: fileURL.path,
                            lineNumber: lineNumber,
                            columnRange: startCol..<endCol,
                            lineText: line
                        )
                    )
                    if foundRange.lowerBound == foundRange.upperBound {
                        break
                    }
                    searchStart = foundRange.upperBound
                }
            }
        }

        guard !matches.isEmpty else { return nil }

        return ProjectSearchFileResult(
            filePath: relativePath,
            fullDiskPath: fileURL.path,
            matches: matches,
            totalFileLineCount: totalLines
        )
    }

    public struct BuiltSlices: Sendable {
        public let buffers: [Buffer]
        public let excerpts: [Excerpt]
        public let matches: [ProjectSearchMatch]
        public let nextStartingMBRow: Int
    }

    /// Converts file search results into MultiBuffer slices and updates match row positions
    public func buildSlices(
        for fileResults: [ProjectSearchFileResult],
        query: ProjectSearchQuery,
        startingMBRow: Int
    ) -> BuiltSlices {
        var buffers: [Buffer] = []
        var excerpts: [Excerpt] = []
        var matchIdToMBRow: [UUID: MultiBufferRow] = [:]
        var runningMBRow = startingMBRow

        for fileResult in fileResults {
            let fullPath = fileResult.fullDiskPath
            let totalLines = fileResult.totalFileLineCount
            let ctx = query.contextLines

            var lineMatchesMap: [Int: [ProjectSearchMatch]] = [:]
            for m in fileResult.matches {
                lineMatchesMap[m.lineNumber, default: []].append(m)
            }

            let sortedLineNumbers = Array(lineMatchesMap.keys).sorted()
            guard !sortedLineNumbers.isEmpty else { continue }

            var clusters: [(start: Int, end: Int)] = []
            for lineNum in sortedLineNumbers {
                let start = max(1, lineNum - ctx)
                let end = min(totalLines, lineNum + ctx)

                if let last = clusters.last {
                    if start <= last.end + 3 {
                        clusters[clusters.count - 1] = (last.start, max(last.end, end))
                    } else {
                        clusters.append((start, end))
                    }
                } else {
                    clusters.append((start, end))
                }
            }

            guard let fileContent = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ??
                                    (try? String(contentsOfFile: fullPath, encoding: .isoLatin1)) else {
                continue
            }
            let fileLines = fileContent.components(separatedBy: "\n")

            for (clusterIdx, cluster) in clusters.enumerated() {
                let startIdx = max(0, cluster.start - 1)
                let endIdx = min(fileLines.count, cluster.end)
                guard startIdx < endIdx else { continue }

                let sliceLines = Array(fileLines[startIdx..<endIdx])

                let buffer = Buffer(
                    filePath: fileResult.filePath,
                    lines: sliceLines,
                    startLineNumber: cluster.start,
                    fullDiskPath: fullPath,
                    diskFileLineCount: totalLines,
                    isLazySlice: true
                )
                buffers.append(buffer)

                let excerpt = Excerpt(
                    bufferId: buffer.id,
                    filePath: fileResult.filePath,
                    fileStatus: .modified,
                    bufferRange: 0..<sliceLines.count,
                    isCollapsed: false,
                    isFileStart: (clusterIdx == 0)
                )
                excerpts.append(excerpt)

                for lineNum in cluster.start...cluster.end {
                    if let lineMatches = lineMatchesMap[lineNum] {
                        let offsetInCluster = lineNum - cluster.start
                        let mbRow = runningMBRow + offsetInCluster
                        for m in lineMatches {
                            matchIdToMBRow[m.id] = mbRow
                        }
                    }
                }

                runningMBRow += sliceLines.count
            }
        }

        var updatedMatches: [ProjectSearchMatch] = []
        for fileResult in fileResults {
            for m in fileResult.matches {
                var matchCopy = m
                if let row = matchIdToMBRow[m.id] {
                    matchCopy.multiBufferRow = row
                }
                updatedMatches.append(matchCopy)
            }
        }

        return BuiltSlices(
            buffers: buffers,
            excerpts: excerpts,
            matches: updatedMatches,
            nextStartingMBRow: runningMBRow
        )
    }

    /// Merges match context windows and populates the MultiBuffer
    public func populate(
        multiBuffer: MultiBuffer,
        with fileResults: [ProjectSearchFileResult],
        query: ProjectSearchQuery,
        matches: inout [ProjectSearchMatch]
    ) {
        multiBuffer.clear()
        multiBuffer.setContentMode(.text)
        let built = buildSlices(for: fileResults, query: query, startingMBRow: 0)
        for buf in built.buffers {
            multiBuffer.addBuffer(buf)
        }
        multiBuffer.setExcerpts(built.excerpts)
        matches = built.matches
    }

    /// Re-scans a single file on disk and returns updated buffers and excerpts if matching,
    /// or empty arrays if the file no longer matches or was deleted.
    public func rescanFile(
        filePath: String,
        fullDiskPath: String,
        query: ProjectSearchQuery
    ) -> (buffers: [Buffer], excerpts: [Excerpt]) {
        guard !query.isEmpty else { return ([], []) }
        let fileURL = URL(fileURLWithPath: fullDiskPath)
        guard FileManager.default.fileExists(atPath: fullDiskPath) else { return ([], []) }

        // Check include/exclude globs
        let includeGlobs = parseGlobPatterns(query.includePattern)
        let excludeGlobs = parseGlobPatterns(query.excludePattern)
        let lastComponent = (filePath as NSString).lastPathComponent

        if !includeGlobs.isEmpty {
            let matchedInclude = includeGlobs.contains { matchGlob($0, string: filePath) || matchGlob($0, string: lastComponent) }
            if !matchedInclude { return ([], []) }
        }

        if !excludeGlobs.isEmpty {
            let matchedExclude = excludeGlobs.contains { matchGlob($0, string: filePath) || matchGlob($0, string: lastComponent) }
            if matchedExclude { return ([], []) }
        }

        let regex: NSRegularExpression?
        switch compileRegex(for: query) {
        case .regex(let r):
            regex = r
        case .literal:
            regex = nil
        case .failed:
            return ([], [])
        }

        guard let fileResult = scanFile(
            fileURL: fileURL,
            relativePath: filePath,
            query: query,
            regex: regex,
            maxAllowed: query.maxMatches
        ) else {
            return ([], [])
        }

        let built = buildSlices(for: [fileResult], query: query, startingMBRow: 0)
        return (built.buffers, built.excerpts)
    }

    /// Re-evaluates search matches in memory across the loaded MultiBuffer without touching disk.
    public func recalculateMatches(
        query: ProjectSearchQuery,
        in multiBuffer: MultiBuffer
    ) -> [ProjectSearchMatch] {
        guard !query.isEmpty else { return [] }

        let regex: NSRegularExpression?
        switch compileRegex(for: query) {
        case .regex(let r):
            regex = r
        case .literal:
            regex = nil
        case .failed:
            return []
        }

        var matches: [ProjectSearchMatch] = []
        var runningMBRow = 0

        for excerpt in multiBuffer.excerpts {
            guard let buf = multiBuffer.buffer(for: excerpt.bufferId) else { continue }
            let range = excerpt.bufferRange
            let lower = max(0, min(buf.lines.count, range.lowerBound))
            let upper = max(lower, min(buf.lines.count, range.upperBound))

            for bufRow in lower..<upper {
                let line = buf.lines[bufRow]
                let offsetInExcerpt = bufRow - lower
                let mbRow = runningMBRow + offsetInExcerpt

                let diskLineNumber: Int
                if buf.isLazySlice {
                    diskLineNumber = buf.startLineNumber + bufRow
                } else {
                    diskLineNumber = bufRow + 1
                }

                if let regex = regex {
                    let nsString = line as NSString
                    let fullRange = NSRange(location: 0, length: nsString.length)
                    let results = regex.matches(in: line, options: [], range: fullRange)
                    for res in results {
                        guard let strRange = Range(res.range, in: line) else { continue }
                        let startCol = line.distance(from: line.startIndex, to: strRange.lowerBound)
                        let endCol = line.distance(from: line.startIndex, to: strRange.upperBound)
                        matches.append(
                            ProjectSearchMatch(
                                filePath: excerpt.filePath,
                                fullDiskPath: buf.fullDiskPath ?? "",
                                lineNumber: diskLineNumber,
                                columnRange: startCol..<endCol,
                                lineText: line,
                                multiBufferRow: mbRow
                            )
                        )
                    }
                } else {
                    let searchStr = query.query
                    var searchStart = line.startIndex
                    let compareOptions: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]

                    while searchStart < line.endIndex,
                          let foundRange = line.range(of: searchStr, options: compareOptions, range: searchStart..<line.endIndex) {
                        let startCol = line.distance(from: line.startIndex, to: foundRange.lowerBound)
                        let endCol = line.distance(from: line.startIndex, to: foundRange.upperBound)
                        matches.append(
                            ProjectSearchMatch(
                                filePath: excerpt.filePath,
                                fullDiskPath: buf.fullDiskPath ?? "",
                                lineNumber: diskLineNumber,
                                columnRange: startCol..<endCol,
                                lineText: line,
                                multiBufferRow: mbRow
                            )
                        )
                        if foundRange.lowerBound == foundRange.upperBound {
                            break
                        }
                        searchStart = foundRange.upperBound
                    }
                }
            }

            runningMBRow += (upper - lower)
        }

        return matches
    }

    // MARK: - File Discovery & Globs

    private func collectFiles(
        in rootURL: URL,
        includeGlobs: [String],
        excludeGlobs: [String],
        maxFileSize: Int,
        isCancelled: (@Sendable () -> Bool)?
    ) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return files
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if isCancelled?() == true { break }

            let lastComponent = fileURL.lastPathComponent

            // Skip hidden files/directories and common ignored dirs
            if Self.defaultIgnoredDirectories.contains(lastComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }

            if resourceValues.isDirectory == true {
                if lastComponent.hasPrefix(".") && lastComponent != "." {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard resourceValues.isRegularFile == true else { continue }

            // Skip files exceeding maxFileSize
            if let size = resourceValues.fileSize, size > maxFileSize {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            if Self.binaryExtensions.contains(ext) {
                continue
            }

            let path = fileURL.standardizedFileURL.path
            let rootPath = rootURL.standardizedFileURL.path
            let relativePath: String
            if path.hasPrefix(rootPath) {
                let suffix = String(path.dropFirst(rootPath.count))
                relativePath = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            } else {
                relativePath = lastComponent
            }

            // Check include/exclude globs
            if !includeGlobs.isEmpty {
                let matchedInclude = includeGlobs.contains { matchGlob($0, string: relativePath) || matchGlob($0, string: lastComponent) }
                if !matchedInclude { continue }
            }

            if !excludeGlobs.isEmpty {
                let matchedExclude = excludeGlobs.contains { matchGlob($0, string: relativePath) || matchGlob($0, string: lastComponent) }
                if matchedExclude { continue }
            }

            files.append(fileURL)
        }

        return files.sorted { $0.path < $1.path }
    }

    private func parseGlobPatterns(_ patternString: String) -> [String] {
        patternString
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func matchGlob(_ pattern: String, string: String) -> Bool {
        if pattern.hasPrefix(".") {
            if string.hasSuffix(pattern) { return true }
        }
        if pattern.hasSuffix("/") {
            let trimmed = String(pattern.dropLast())
            if string.hasPrefix(trimmed + "/") || string.contains("/" + trimmed + "/") || string == trimmed {
                return true
            }
        }
        if fnmatch(pattern, string, 0) == 0 {
            return true
        }
        if fnmatch("*/" + pattern, string, 0) == 0 {
            return true
        }
        if fnmatch(pattern + "/*", string, 0) == 0 {
            return true
        }
        if fnmatch("*/" + pattern + "/*", string, 0) == 0 {
            return true
        }
        return false
    }
}
