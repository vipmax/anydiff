import Foundation

/// Fast and robust parser for Git Unified Diffs
public final class GitDiffParser: Sendable {
    public static let shared = GitDiffParser()

    public init() {}

    /// Parses unified diff text into a list of FileDiffs
    public func parse(diffText: String) -> [FileDiff] {
        var fileDiffs: [FileDiff] = []

        var currentFile: FileDiff?
        var currentHunk: DiffHunk?
        var hunkLines: [DiffLine] = []

        var oldLineNumber: Int = 0
        var newLineNumber: Int = 0

        func flushHunk() {
            if var hunk = currentHunk {
                // Post-process hunk lines for word-level diffs
                processWordDiffs(lines: &hunkLines)
                hunk.lines = hunkLines
                currentFile?.hunks.append(hunk)
                currentHunk = nil
                hunkLines.removeAll()
            }
        }

        func flushFile() {
            flushHunk()
            if let file = currentFile {
                fileDiffs.append(file)
                currentFile = nil
            }
        }

        diffText.enumerateLines { line, _ in
            if line.hasPrefix("diff --git ") {
                flushFile()
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
                    // Diff without 'diff --git' header (e.g. standard patch)
                    let p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    let cleanPath = p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
                    currentFile = FileDiff(oldPath: cleanPath, newPath: cleanPath, status: .modified)
                }
            } else if line.hasPrefix("@@ ") {
                flushHunk()
                if currentFile == nil {
                    currentFile = FileDiff(oldPath: "File", newPath: "File", status: .modified)
                }

                if let (oldRange, newRange, header) = self.parseHunkHeader(line) {
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
                    // Empty unchanged line
                    let diffLine = DiffLine(
                        kind: .unchanged,
                        text: "",
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber
                    )
                    hunkLines.append(diffLine)
                    oldLineNumber += 1
                    newLineNumber += 1
                    return
                }

                let text = String(line.dropFirst())
                switch firstChar {
                case "+":
                    let diffLine = DiffLine(
                        kind: .added,
                        text: text,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber
                    )
                    hunkLines.append(diffLine)
                    newLineNumber += 1
                case "-":
                    let diffLine = DiffLine(
                        kind: .deleted,
                        text: text,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil
                    )
                    hunkLines.append(diffLine)
                    oldLineNumber += 1
                case " ":
                    let diffLine = DiffLine(
                        kind: .unchanged,
                        text: text,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber
                    )
                    hunkLines.append(diffLine)
                    oldLineNumber += 1
                    newLineNumber += 1
                case "\\":
                    // "\ No newline at end of file"
                    break
                default:
                    // Treat as context line if unexpected
                    let diffLine = DiffLine(
                        kind: .unchanged,
                        text: line,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber
                    )
                    hunkLines.append(diffLine)
                    oldLineNumber += 1
                    newLineNumber += 1
                }
            }
        }

        flushFile()
        return fileDiffs
    }

    /// Parses hunk header line `@@ -oldStart,oldCount +newStart,newCount @@ header`
    private func parseHunkHeader(_ line: String) -> (Range<Int>, Range<Int>, String)? {
        let pattern = #"^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else {
            return nil
        }

        let oldStartStr = nsLine.substring(with: match.range(at: 1))
        let oldCountStr = match.range(at: 2).location != NSNotFound ? nsLine.substring(with: match.range(at: 2)) : "1"
        let newStartStr = nsLine.substring(with: match.range(at: 3))
        let newCountStr = match.range(at: 4).location != NSNotFound ? nsLine.substring(with: match.range(at: 4)) : "1"
        let headerText = match.range(at: 5).location != NSNotFound ? nsLine.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces) : ""

        let oldStart = Int(oldStartStr) ?? 1
        let oldCount = Int(oldCountStr) ?? 1
        let newStart = Int(newStartStr) ?? 1
        let newCount = Int(newCountStr) ?? 1

        return (oldStart..<(oldStart + oldCount), newStart..<(newStart + newCount), headerText)
    }

    /// Computes word-level diffs for adjacent deleted and added lines in a hunk
    private func processWordDiffs(lines: inout [DiffLine]) {
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

                // If paired 1:1 or small block, compute word diffs
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
