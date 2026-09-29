import Foundation

/// Builds and populates `Buffer` and `Excerpt` models in `MultiBuffer` from `FileDiff` structures.
public enum MultiBufferBuilder {

    public static func resolveDiskPath(for relativePath: String, in baseDir: String?) -> String? {
        guard let baseDir, !baseDir.isEmpty else { return nil }
        let fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: fullPath) {
            return fullPath
        }
        let components = relativePath.components(separatedBy: "/")
        if components.count > 1 {
            let subPath = components.dropFirst().joined(separator: "/")
            let altPath = (baseDir as NSString).appendingPathComponent(subPath)
            if FileManager.default.fileExists(atPath: altPath) {
                return altPath
            }
        }
        return fullPath
    }

    public static func buildBuffersAndExcerpts(
        for file: FileDiff,
        rawData: Data? = nil,
        baseDirectory: String? = nil,
        isCollapsed: Bool = false
    ) -> (buffers: [Buffer], excerpts: [Excerpt]) {
        let fileAdds = file.additions
        let fileDels = file.deletions
        let resolvedDiskPath = resolveDiskPath(for: file.displayPath, in: baseDirectory)

        if file.status == .unmodified {
            let content = (resolvedDiskPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }) ?? ""
            let lines = content.components(separatedBy: "\n")
            let buffer = Buffer(
                filePath: file.displayPath,
                lines: lines,
                language: Buffer.detectLanguage(for: file.displayPath),
                baselineLines: lines,
                totalAdditions: 0,
                totalDeletions: 0,
                startLineNumber: 1,
                fullDiskPath: resolvedDiskPath,
                diskFileLineCount: lines.count
            )
            buffer.isFullFile = true
            let excerpt = Excerpt(
                bufferId: buffer.id,
                filePath: file.displayPath,
                fileStatus: .unmodified,
                bufferRange: 0..<lines.count,
                hunk: nil,
                isCollapsed: isCollapsed,
                isFileStart: true
            )
            return ([buffer], [excerpt])
        }

        if file.status == .deleted {
            let hunk = file.hunks.first
            let buffer: Buffer
            if let rawData, let h = hunk, !h.lineSpans.isEmpty {
                buffer = Buffer(
                    filePath: file.displayPath,
                    storage: .makeDiffFlat(data: rawData, spans: h.lineSpans, side: .old),
                    language: Buffer.detectLanguage(for: file.displayPath),
                    totalAdditions: 0,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: resolvedDiskPath,
                    diskFileLineCount: h.lineSpans.count - h.addedLineCount
                )
            } else {
                var oldLines: [String] = []
                for h in file.hunks {
                    for line in h.lines {
                        if line.kind == .deleted || line.kind == .unchanged {
                            oldLines.append(line.text)
                        }
                    }
                }
                buffer = Buffer(
                    filePath: file.displayPath,
                    lines: [],
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: oldLines,
                    totalAdditions: 0,
                    totalDeletions: fileDels,
                    startLineNumber: 1,
                    fullDiskPath: resolvedDiskPath,
                    diskFileLineCount: oldLines.count
                )
            }
            buffer.isFullFile = true
            let excerpt = Excerpt(
                bufferId: buffer.id,
                filePath: file.displayPath,
                fileStatus: .deleted,
                bufferRange: 0..<0,
                hunk: hunk,
                isCollapsed: isCollapsed,
                isFileStart: true
            )
            return ([buffer], [excerpt])
        }

        if file.hunks.isEmpty {
            let buffer = Buffer(
                filePath: file.displayPath,
                lines: [],
                language: Buffer.detectLanguage(for: file.displayPath),
                baselineLines: [],
                totalAdditions: fileAdds,
                totalDeletions: fileDels,
                startLineNumber: 1,
                fullDiskPath: resolvedDiskPath,
                diskFileLineCount: 0
            )
            buffer.isFullFile = true
            let excerpt = Excerpt(
                bufferId: buffer.id,
                filePath: file.displayPath,
                fileStatus: file.status,
                bufferRange: 0..<0,
                hunk: nil,
                isCollapsed: isCollapsed,
                isFileStart: true
            )
            return ([buffer], [excerpt])
        }

        var buffers: [Buffer] = []
        var excerpts: [Excerpt] = []
        buffers.reserveCapacity(file.hunks.count)
        excerpts.reserveCapacity(file.hunks.count)

        for (hIdx, hunk) in file.hunks.enumerated() {
            let startLine = hunk.newRange.lowerBound
            let isLazy = (file.status != .added || file.hunks.count > 1)
            let buffer: Buffer

            if let rawData, !hunk.lineSpans.isEmpty {
                buffer = Buffer(
                    filePath: file.displayPath,
                    storage: .makeDiffFlat(data: rawData, spans: hunk.lineSpans, side: .new),
                    language: Buffer.detectLanguage(for: file.displayPath),
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: startLine,
                    fullDiskPath: resolvedDiskPath,
                    diskFileLineCount: nil,
                    isLazySlice: isLazy
                )
            } else {
                let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                buffer = Buffer(
                    filePath: file.displayPath,
                    lines: newFileLines,
                    language: Buffer.detectLanguage(for: file.displayPath),
                    baselineLines: oldBaselineLines,
                    totalAdditions: fileAdds,
                    totalDeletions: fileDels,
                    startLineNumber: startLine,
                    fullDiskPath: resolvedDiskPath,
                    diskFileLineCount: nil,
                    isLazySlice: isLazy
                )
            }
            buffer.isFullFile = (file.status == .added && file.hunks.count == 1)
            buffers.append(buffer)

            let excerpt = Excerpt(
                bufferId: buffer.id,
                filePath: file.displayPath,
                fileStatus: file.status,
                bufferRange: 0..<buffer.lineCount,
                hunk: hunk,
                isCollapsed: isCollapsed,
                isFileStart: (hIdx == 0)
            )
            excerpts.append(excerpt)
        }

        return (buffers, excerpts)
    }

    public static func append(
        files: [FileDiff],
        rawData: Data? = nil,
        baseDirectory: String? = nil,
        collapsedPaths: Set<String> = [],
        into target: MultiBuffer
    ) {
        for file in files {
            let isCollapsed = collapsedPaths.contains(file.displayPath)
            let (buffers, excerpts) = buildBuffersAndExcerpts(
                for: file,
                rawData: rawData,
                baseDirectory: baseDirectory,
                isCollapsed: isCollapsed
            )
            for buf in buffers {
                target.addBuffer(buf)
            }
            for exc in excerpts {
                target.addExcerpt(exc)
            }
        }
    }

    public static func makeCleanFileBuffer(
        fullDiskPath: String,
        relativePath: String
    ) -> (buffer: Buffer, excerpt: Excerpt, fileDiff: FileDiff)? {
        guard FileManager.default.fileExists(atPath: fullDiskPath),
              let content = try? String(contentsOfFile: fullDiskPath, encoding: .utf8) else {
            return nil
        }
        let lines = content.components(separatedBy: "\n")
        let buffer = Buffer(
            filePath: relativePath,
            lines: lines,
            language: Buffer.detectLanguage(for: relativePath),
            baselineLines: lines,
            totalAdditions: 0,
            totalDeletions: 0,
            startLineNumber: 1,
            fullDiskPath: fullDiskPath,
            diskFileLineCount: lines.count
        )
        buffer.isFullFile = true

        let excerpt = Excerpt(
            bufferId: buffer.id,
            filePath: relativePath,
            fileStatus: .unmodified,
            bufferRange: 0..<lines.count,
            hunk: nil,
            isCollapsed: false,
            isFileStart: true
        )

        let cleanFileDiff = FileDiff(
            oldPath: relativePath,
            newPath: relativePath,
            status: .unmodified,
            hunks: []
        )

        return (buffer, excerpt, cleanFileDiff)
    }
}
