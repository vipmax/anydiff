import Foundation

/// Fast and robust parser for Git Unified Diffs
public final class GitDiffParser: Sendable {
    public static let shared = GitDiffParser()

    public init() {}

    /// Parses unified diff text into a list of FileDiffs
    public func parse(diffText: String) -> [FileDiff] {
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
        guard lines.count <= 250 else { return }
        var i = 0
        while i < lines.count {
            if lines[i].kind == .deleted {
                var deletedIndices: [Int] = []
                while i < lines.count && lines[i].kind == .deleted {
                    deletedIndices.append(i)
                    i += 1
                }
                var addedIndices: [Int] = []
                while i < lines.count && lines[i].kind == .added {
                    addedIndices.append(i)
                    i += 1
                }

                let pairCount = min(deletedIndices.count, addedIndices.count)
                for k in 0..<pairCount {
                    let dIdx = deletedIndices[k]
                    let aIdx = addedIndices[k]
                    let (oldRanges, newRanges) = WordDiffEngine.shared.diffWords(
                        oldText: lines[dIdx].text,
                        newText: lines[aIdx].text
                    )
                    lines[dIdx].wordDiffRanges = oldRanges
                    lines[aIdx].wordDiffRanges = newRanges
                }
            } else {
                i += 1
            }
        }
    }
}
