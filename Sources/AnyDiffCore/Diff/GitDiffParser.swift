import Foundation

 
/// Splits streaming byte chunks (e.g. 64KB buffers from posix_read or file/memory chunks) into line slices
/// using fast SIMD memchr (0x0A) with zero string copies and rollover handling.
public final class ChunkLineSplitter {
    private var remainder = [UInt8]()
    private let onLine: (UnsafeBufferPointer<UInt8>) -> Void

    public init(onLine: @escaping (UnsafeBufferPointer<UInt8>) -> Void) {
        self.onLine = onLine
    }

    /// Processes an incoming raw chunk of bytes, extracting full lines and invoking `onLine`.
    public func processChunk(_ chunk: UnsafeBufferPointer<UInt8>) {
        guard let chunkBase = chunk.baseAddress, !chunk.isEmpty else { return }

        var currentOffset = 0
        let totalCount = chunk.count

        // 1. If we have a pending partial line from the previous chunk, find first newline to complete it
        if !remainder.isEmpty {
            if let newlinePtr = memchr(chunkBase, 0x0A, totalCount) {
                let leadingLen = chunkBase.distance(to: newlinePtr.assumingMemoryBound(to: UInt8.self))
                remainder.append(contentsOf: UnsafeBufferPointer(start: chunkBase, count: leadingLen))
                if remainder.last == 0x0D {
                    remainder.removeLast()
                }
                remainder.withUnsafeBufferPointer { lineBuf in
                    onLine(lineBuf)
                }
                remainder.removeAll(keepingCapacity: true)
                currentOffset = leadingLen + 1
            } else {
                remainder.append(contentsOf: chunk)
                return
            }
        }

        // 2. Scan lines in the current chunk using vectorized memchr
        while currentOffset < totalCount {
            let currentBase = chunkBase.advanced(by: currentOffset)
            let remainingBytes = totalCount - currentOffset

            guard let newlinePtr = memchr(currentBase, 0x0A, remainingBytes) else {
                // No more newlines in this chunk: store remainder for next chunk
                remainder.append(contentsOf: UnsafeBufferPointer(start: currentBase, count: remainingBytes))
                break
            }

            var lineLen = currentBase.distance(to: newlinePtr.assumingMemoryBound(to: UInt8.self))
            if lineLen > 0 && currentBase[lineLen - 1] == 0x0D {
                lineLen -= 1
            }

            let lineSlice = UnsafeBufferPointer(start: currentBase, count: lineLen)
            onLine(lineSlice)
            currentOffset += currentBase.distance(to: newlinePtr.assumingMemoryBound(to: UInt8.self)) + 1
        }
    }

    /// Flushes any pending line at EOF.
    public func finish() {
        if !remainder.isEmpty {
            if remainder.last == 0x0D {
                remainder.removeLast()
            }
            remainder.withUnsafeBufferPointer { lineBuf in
                onLine(lineBuf)
            }
            remainder.removeAll(keepingCapacity: false)
        }
    }
}

/// Fast and robust parser for Git Unified Diffs
public final class GitDiffParser: Sendable {
    public static let shared = GitDiffParser()

    public init() {}

    /// High-performance zero-allocation parser for unified diff text (using fast UTF-8 byte scanning)
    public func parse(diffText: String) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []
        let streamer = StreamingGitDiffParser()
        let splitter = ChunkLineSplitter { lineBytes in
            if let file = streamer.feed(lineBytes: lineBytes) {
                fileDiffs.append(file)
            }
        }

        let utf8View = diffText.utf8
        let handled = utf8View.withContiguousStorageIfAvailable { buffer -> Bool in
            splitter.processChunk(buffer)
            splitter.finish()
            return true
        } ?? false

        if !handled {
            let data = Data(diffText.utf8)
            data.withUnsafeBytes { rawBuffer in
                let buffer = rawBuffer.bindMemory(to: UInt8.self)
                splitter.processChunk(buffer)
                splitter.finish()
            }
        }

        if let finalFile = streamer.finish() {
            fileDiffs.append(finalFile)
        }
        return fileDiffs
    }

    /// Ultra-fast Zero-Copy parser directly from raw Data (records byte spans without allocating String instances)
    public func parseZeroCopy(data: Data) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []
        data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let streamer = ZeroCopyStreamingGitDiffParser(baseAddress: basePtr, dataSize: data.count)
            let splitter = ChunkLineSplitter { lineBytes in
                if let file = streamer.feed(lineBytes: lineBytes) {
                    fileDiffs.append(file)
                }
            }
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            splitter.processChunk(buffer)
            splitter.finish()
            if let finalFile = streamer.finish() {
                fileDiffs.append(finalFile)
            }
        }
        return fileDiffs
    }

    /// Fast parser directly from raw Data (zero-copy buffer scanning)
    public func parse(data: Data) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []
        let streamer = StreamingGitDiffParser()
        let splitter = ChunkLineSplitter { lineBytes in
            if let file = streamer.feed(lineBytes: lineBytes) {
                fileDiffs.append(file)
            }
        }
        data.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            splitter.processChunk(buffer)
            splitter.finish()
        }
        if let finalFile = streamer.finish() {
            fileDiffs.append(finalFile)
        }
        return fileDiffs
    }

    /// Fast parser directly from an UnsafeBufferPointer of bytes
    public func parse(bytes: UnsafeBufferPointer<UInt8>) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []
        let streamer = StreamingGitDiffParser()
        let splitter = ChunkLineSplitter { lineBytes in
            if let file = streamer.feed(lineBytes: lineBytes) {
                fileDiffs.append(file)
            }
        }
        splitter.processChunk(bytes)
        splitter.finish()
        if let finalFile = streamer.finish() {
            fileDiffs.append(finalFile)
        }
        return fileDiffs
    }

    /// Legacy parser implementation using String.enumerateLines and grapheme cluster iteration
    public func parseLegacy(diffText: String) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []
        let streamer = StreamingGitDiffParser()
        diffText.enumerateLines { line, _ in
            if let file = streamer.feed(line: line) {
                fileDiffs.append(file)
            }
        }
        if let finalFile = streamer.finish() {
            fileDiffs.append(finalFile)
        }
        return fileDiffs
    }

    /// Fast scanner for hunk header from byte buffer `@@ -oldStart,oldCount +newStart,newCount @@ header`
    public func parseHunkHeaderBytes(_ bytes: UnsafeBufferPointer<UInt8>) -> (Range<Int>, Range<Int>, String)? {
        guard let base = bytes.baseAddress, bytes.count >= 4 else { return nil }
        guard base[0] == 0x40 && base[1] == 0x40 else { return nil } // @@

        let str = String(decoding: bytes, as: UTF8.self)
        return parseHunkHeader(str)
    }

    /// Ultra-fast zero-allocation scanner for hunk header line `@@ -oldStart,oldCount +newStart,newCount @@ header`
    public func parseHunkHeader(_ line: String) -> (Range<Int>, Range<Int>, String)? {
        guard line.hasPrefix("@@") else { return nil }
        guard let minusIdx = line.firstIndex(of: "-") else { return nil }
        let afterMinus = line[line.index(after: minusIdx)...]
        guard let plusIdx = afterMinus.firstIndex(of: "+") else { return nil }

        let oldPart = afterMinus[..<plusIdx].trimmingCharacters(in: .whitespaces)
        let afterPlus = afterMinus[afterMinus.index(after: plusIdx)...]

        guard let closingRange = afterPlus.range(of: "@@") else { return nil }
        let newPart = afterPlus[..<closingRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let headerText = String(afterPlus[closingRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        let oldSplit = oldPart.split(separator: ",")
        guard !oldSplit.isEmpty, let oldStart = Int(oldSplit[0]) else { return nil }
        let oldCount = oldSplit.count > 1 ? (Int(oldSplit[1]) ?? 1) : 1

        let newSplit = newPart.split(separator: ",")
        guard !newSplit.isEmpty, let newStart = Int(newSplit[0]) else { return nil }
        let newCount = newSplit.count > 1 ? (Int(newSplit[1]) ?? 1) : 1

        return (oldStart..<(oldStart + oldCount), newStart..<(newStart + newCount), headerText)
    }
}

/// Streaming incremental parser that emits `FileDiff`s on the fly as lines arrive from network or pipe
public final class StreamingGitDiffParser {
    private var currentFile: FileDiff?
    private var currentHunk: DiffHunk?
    private var hunkLines: [DiffLine] = []
    private var oldLineNumber: Int = 0
    private var newLineNumber: Int = 0

    public init() {}

    private func flushHunk() {
        if var hunk = currentHunk {
            processWordDiffs(lines: &hunkLines)
            hunk.lines = hunkLines
            var adds = 0 
            var dels = 0
            for line in hunkLines {
                if line.kind == .added { adds += 1 }
                else if line.kind == .deleted { dels += 1 }
            }
            hunk.addedLineCount = adds
            hunk.deletedLineCount = dels
            currentFile?.hunks.append(hunk)
            currentHunk = nil
            hunkLines.removeAll(keepingCapacity: true)
        }
    }

    private func flushFile() -> FileDiff? {
        flushHunk()
        if let file = currentFile {
            currentFile = nil
            return file
        }
        return nil
    }

    /// Feeds a single line of unified diff. Returns a completed `FileDiff` if this line begins a new file.
    public func feed(line: String) -> FileDiff? {
        var completedFile: FileDiff? = nil

        if line.hasPrefix("diff --git ") {
            completedFile = flushFile()
            let parts = line.components(separatedBy: " ")
            let oldPath = parts.count > 2 ? String(parts[2].dropFirst(2)) : "old"
            let newPath = parts.count > 3 ? String(parts[3].dropFirst(2)) : "new"
            currentFile = FileDiff(oldPath: oldPath, newPath: newPath, status: .modified)
        } else if line.hasPrefix("new file mode") {
            currentFile?.status = .added
        } else if line.hasPrefix("deleted file mode") {
            currentFile?.status = .deleted
        } else if line.hasPrefix("rename from ") {
            currentFile?.status = .renamed
            currentFile?.oldPath = String(line.dropFirst("rename from ".count))
        } else if line.hasPrefix("rename to ") {
            currentFile?.newPath = String(line.dropFirst("rename to ".count))
        } else if line.hasPrefix("--- ") {
            if line.hasPrefix("--- /dev/null") {
                currentFile?.status = .added
            }
        } else if line.hasPrefix("+++ ") {
            if line.hasPrefix("+++ /dev/null") {
                currentFile?.status = .deleted
            } else if currentFile == nil {
                let p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let cleanPath = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
                currentFile = FileDiff(oldPath: cleanPath, newPath: cleanPath, status: .modified)
            }
        } else if line.hasPrefix("@@ ") {
            flushHunk()
            if currentFile == nil {
                currentFile = FileDiff(oldPath: "File", newPath: "File", status: .modified)
            }

            if let (oldRange, newRange, header) = GitDiffParser.shared.parseHunkHeader(line) {
                oldLineNumber = oldRange.lowerBound
                newLineNumber = newRange.lowerBound
                currentHunk = DiffHunk(
                    oldRange: oldRange,
                    newRange: newRange,
                    header: header,
                    lines: []
                )
            }
        } else if currentHunk != nil {
            guard let firstChar = line.first else {
                appendHunkLine(kindByte: nil, text: "")
                return completedFile
            }

            switch firstChar {
            case "+": appendHunkLine(kindByte: 0x2B, text: String(line.dropFirst()))
            case "-": appendHunkLine(kindByte: 0x2D, text: String(line.dropFirst()))
            case " ": appendHunkLine(kindByte: 0x20, text: String(line.dropFirst()))
            case "\\":
                break
            default:
                appendHunkLine(kindByte: nil, text: line)
            }
        }

        return completedFile
    }

    /// Feeds a UTF-8 line without first constructing a `String` for control-only lines.
    /// The scanner uses the first byte to dispatch the common hunk-line cases; text is
    /// decoded only when it is needed by the model or by the metadata parser.
    public func feed(lineBytes: UnsafeBufferPointer<UInt8>) -> FileDiff? {
        guard !lineBytes.isEmpty else {
            if currentHunk != nil {
                appendHunkLine(kindByte: nil, text: "")
            }
            return nil
        }

        if currentHunk != nil {
            switch lineBytes[0] {
            case 0x2B: // +
                appendHunkLine(kindByte: 0x2B, text: String(decoding: lineBytes.dropFirst(), as: UTF8.self))
                return nil
            case 0x2D: // -
                appendHunkLine(kindByte: 0x2D, text: String(decoding: lineBytes.dropFirst(), as: UTF8.self))
                return nil
            case 0x20: // context
                appendHunkLine(kindByte: 0x20, text: String(decoding: lineBytes.dropFirst(), as: UTF8.self))
                return nil
            case 0x5C: // "\\ No newline at end of file"
                return nil
            default:
                break
            }
        }

        // Outside a hunk, most metadata lines are intentionally ignored. Decode only
        // lines that can change parser state or start a hunk/file.
        switch lineBytes[0] {
        case 0x2B, 0x2D, 0x40, 0x64, 0x6E, 0x72: // + - @ d n r
            return feed(line: String(decoding: lineBytes, as: UTF8.self))
        default:
            return nil
        }
    }

    /// Flushes and returns the last pending file when the stream finishes
    public func finish() -> FileDiff? {
        flushFile()
    }

    private func appendHunkLine(kindByte: UInt8?, text: String) {
        switch kindByte {
        case 0x2B:
            hunkLines.append(DiffLine(kind: .added, text: text, oldLineNumber: nil, newLineNumber: newLineNumber))
            newLineNumber += 1
        case 0x2D:
            hunkLines.append(DiffLine(kind: .deleted, text: text, oldLineNumber: oldLineNumber, newLineNumber: nil))
            oldLineNumber += 1
        default:
            hunkLines.append(DiffLine(kind: .unchanged, text: text, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber))
            oldLineNumber += 1
            newLineNumber += 1
        }
    }

    private func processWordDiffs(lines: inout [DiffLine]) {
        WordDiffEngine.shared.processWordDiffs(lines: &lines)
    }
}

/// Zero-copy streaming parser123 that records byte offsets (LineSpan) directly into continuous Data
public final class ZeroCopyStreamingGitDiffParser {
    private var currentFile: FileDiff?
    private var currentHunk: DiffHunk?
    private var hunkSpans: [LineSpan] = []
    private var oldLineNumber: Int = 0
    private var newLineNumber: Int = 0
    private let baseAddress: UnsafePointer<UInt8>
    private let dataSize: Int

    public init(baseAddress: UnsafePointer<UInt8>, dataSize: Int = 0) {
        self.baseAddress = baseAddress
        self.dataSize = dataSize
    }

    private func safeOffset(for lineBase: UnsafePointer<UInt8>) -> UInt32 {
        let ptr = lineBase.advanced(by: 1)
        if ptr >= baseAddress && (dataSize == 0 || ptr <= baseAddress.advanced(by: dataSize)) {
            let dist = baseAddress.distance(to: ptr)
            return UInt32(clamping: max(0, dist))
        }
        return 0
    }

    private func flushHunk() {
        if var hunk = currentHunk {
            hunk.lineSpans = hunkSpans
            var adds = 0
            var dels = 0
            for span in hunkSpans {
                if span.kind == .added { adds += 1 }
                else if span.kind == .deleted { dels += 1 }
            }
            hunk.addedLineCount = adds
            hunk.deletedLineCount = dels
            currentFile?.hunks.append(hunk)
            currentHunk = nil
            hunkSpans.removeAll(keepingCapacity: true)
        }
    }

    private func flushFile() -> FileDiff? {
        flushHunk()
        if let file = currentFile {
            currentFile = nil
            return file
        }
        return nil
    }

    public func feed(lineBytes: UnsafeBufferPointer<UInt8>) -> FileDiff? {
        guard let lineBase = lineBytes.baseAddress, !lineBytes.isEmpty else {
            return nil
        }

        if currentHunk != nil {
            let firstByte = lineBytes[0]
            let offset = safeOffset(for: lineBase)
            let len = UInt16(clamping: max(0, lineBytes.count - 1))
            let safeOldNum = oldLineNumber > 0 ? UInt32(clamping: oldLineNumber) : 0
            let safeNewNum = newLineNumber > 0 ? UInt32(clamping: newLineNumber) : 0

            switch firstByte {
            case 0x2B: // +
                hunkSpans.append(LineSpan(offset: offset, length: len, kind: .added, oldLineNumber: 0, newLineNumber: safeNewNum))
                newLineNumber += 1
                return nil
            case 0x2D: // -
                hunkSpans.append(LineSpan(offset: offset, length: len, kind: .deleted, oldLineNumber: safeOldNum, newLineNumber: 0))
                oldLineNumber += 1
                return nil
            case 0x20: // context ' '
                hunkSpans.append(LineSpan(offset: offset, length: len, kind: .unchanged, oldLineNumber: safeOldNum, newLineNumber: safeNewNum))
                oldLineNumber += 1
                newLineNumber += 1
                return nil
            case 0x5C: // \\ No newline at end of file
                return nil
            default:
                break
            }
        }

        // Decode metadata lines only outside hunk bodies
        let line = String(decoding: lineBytes, as: UTF8.self)
        var completedFile: FileDiff? = nil

        if line.hasPrefix("diff --git ") {
            completedFile = flushFile()
            let parts = line.components(separatedBy: " ")
            let oldPath = parts.count > 2 ? String(parts[2].dropFirst(2)) : "old"
            let newPath = parts.count > 3 ? String(parts[3].dropFirst(2)) : "new"
            currentFile = FileDiff(oldPath: oldPath, newPath: newPath, status: .modified)
        } else if line.hasPrefix("new file mode") {
            currentFile?.status = .added
        } else if line.hasPrefix("deleted file mode") {
            currentFile?.status = .deleted
        } else if line.hasPrefix("rename from ") {
            currentFile?.status = .renamed
            currentFile?.oldPath = String(line.dropFirst("rename from ".count))
        } else if line.hasPrefix("rename to ") {
            currentFile?.newPath = String(line.dropFirst("rename to ".count))
        } else if line.hasPrefix("--- ") {
            if line.hasPrefix("--- /dev/null") {
                currentFile?.status = .added
            }
        } else if line.hasPrefix("+++ ") {
            if line.hasPrefix("+++ /dev/null") {
                currentFile?.status = .deleted
            } else if currentFile == nil {
                let p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let cleanPath = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
                currentFile = FileDiff(oldPath: cleanPath, newPath: cleanPath, status: .modified)
            }
        } else if line.hasPrefix("@@ ") || line.hasPrefix("@@") {
            flushHunk()
            if currentFile == nil {
                currentFile = FileDiff(oldPath: "File", newPath: "File", status: .modified)
            }
            if let (oldRange, newRange, header) = GitDiffParser.shared.parseHunkHeader(line) {
                oldLineNumber = oldRange.lowerBound
                newLineNumber = newRange.lowerBound
                currentHunk = DiffHunk(
                    oldRange: oldRange,
                    newRange: newRange,
                    header: header,
                    lines: [],
                    lineSpans: []
                )
            }
        }

        return completedFile
    }

    public func finish() -> FileDiff? {
        flushFile()
    }
}
