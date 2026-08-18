import Foundation

/// Fast Myers diff engine for computing line-level unified diff hunks on live edits
public final class LineDiffEngine: Sendable {
    public static let shared = LineDiffEngine()

    public init() {}

    /// Recomputes intra-line highlights without changing the line-level edit
    /// script. Used by the editor when a character edit can retain git's
    /// original hunk alignment.
    public func refreshWordDiffs(in lines: inout [DiffLine]) {
        for index in lines.indices {
            lines[index].wordDiffRanges.removeAll(keepingCapacity: true)
        }
        processWordDiffs(lines: &lines)
    }

    /// Computes the complete line-level diff without grouping it into hunks.
    public func diffLines(
        oldLines: [String],
        newLines: [String],
        oldStartLine: Int = 1,
        newStartLine: Int = 1,
        enablePrefixSuffixPruning: Bool = true
    ) -> [DiffLine] {
        guard oldLines != newLines else {
            return oldLines.enumerated().map { index, line in
                DiffLine(
                    kind: .unchanged,
                    text: line,
                    oldLineNumber: oldStartLine + index,
                    newLineNumber: newStartLine + index
                )
            }
        }

        var lines: [DiffLine]
        if enablePrefixSuffixPruning {
            lines = computeMyersDiff(
                oldLines: oldLines,
                newLines: newLines,
                oldStartLine: oldStartLine,
                newStartLine: newStartLine
            )
        } else {
            lines = computeMyersDiffCore(
                oldLines: oldLines,
                newLines: newLines,
                oldStartLine: oldStartLine,
                newStartLine: newStartLine
            )
        }
        processWordDiffs(lines: &lines)
        return lines
    }

    /// Computes diff lines ONLY for the specified slice of the new buffer (targetRange in 0-based buffer rows),
    /// avoiding allocation and materialization of DiffLines for rows outside targetRange.
    /// Returns the slice's DiffLines along with the total file-level additions and deletions counts.
    public func diffLinesForSlice(
        oldLines: [String],
        newLines: [String],
        oldStartLine: Int = 1,
        newStartLine: Int = 1,
        targetRange: Range<Int>
    ) -> (lines: [(line: DiffLine, bufferRow: Int)], additions: Int, deletions: Int) {
        let n = oldLines.count
        let m = newLines.count

        // 1. Fast Path: both are identical
        if oldLines == newLines {
            let clamped = max(0, min(m, targetRange.lowerBound))..<max(0, min(m, targetRange.upperBound))
            var result: [(line: DiffLine, bufferRow: Int)] = []
            result.reserveCapacity(clamped.count)
            for r in clamped {
                let num = newStartLine + r
                let dLine = DiffLine(kind: .unchanged, text: newLines[r], oldLineNumber: num, newLineNumber: num)
                result.append((line: dLine, bufferRow: r))
            }
            return (lines: result, additions: 0, deletions: 0)
        }

        // 2. Common Prefix in O(N)
        var prefixCount = 0
        let minCount = min(n, m)
        while prefixCount < minCount && oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        // 3. Common Suffix in O(N)
        let suffixCount = stableCommonSuffixCount(
            oldLines: oldLines,
            newLines: newLines,
            prefixCount: prefixCount
        )

        var result: [(line: DiffLine, bufferRow: Int)] = []
        var additions = 0
        var deletions = 0

        // A. Process Prefix region intersection with targetRange
        let prefixEnd = prefixCount
        let prefixIntersectionStart = max(0, min(prefixEnd, targetRange.lowerBound))
        let prefixIntersectionEnd = max(prefixIntersectionStart, min(prefixEnd, targetRange.upperBound))
        for r in prefixIntersectionStart..<prefixIntersectionEnd {
            let oldNum = oldStartLine + r
            let newNum = newStartLine + r
            let dLine = DiffLine(kind: .unchanged, text: newLines[r], oldLineNumber: oldNum, newLineNumber: newNum)
            result.append((line: dLine, bufferRow: r))
        }

        // B. Process Middle region (if any changes exist)
        let oldMiddleRange = prefixCount..<(n - suffixCount)
        let newMiddleRange = prefixCount..<(m - suffixCount)

        if !oldMiddleRange.isEmpty || !newMiddleRange.isEmpty {
            let trimmedOldStart = oldStartLine + prefixCount
            let trimmedNewStart = newStartLine + prefixCount

            var middleDiff = computeMyersDiffCore(
                oldLines: oldLines,
                oldRange: oldMiddleRange,
                newLines: newLines,
                newRange: newMiddleRange,
                oldStartLine: trimmedOldStart,
                newStartLine: trimmedNewStart
            )
            processWordDiffs(lines: &middleDiff)

            var curBRow = prefixCount
            for dLine in middleDiff {
                let row = curBRow
                if dLine.kind == .deleted {
                    deletions += 1
                    // Deleted line attached to current buffer row
                    if m == 0 {
                        result.append((line: dLine, bufferRow: 0))
                    } else if targetRange.isEmpty {
                        if row == targetRange.lowerBound {
                            result.append((line: dLine, bufferRow: row))
                        }
                    } else if targetRange.contains(row) || (row == targetRange.upperBound && targetRange.upperBound == m) {
                        result.append((line: dLine, bufferRow: row))
                    }
                } else if dLine.kind == .added {
                    additions += 1
                    if targetRange.contains(row) {
                        result.append((line: dLine, bufferRow: row))
                    }
                    curBRow += 1
                } else {
                    if targetRange.contains(row) {
                        result.append((line: dLine, bufferRow: row))
                    }
                    curBRow += 1
                }
            }
        }

        // C. Process Suffix region intersection with targetRange
        let suffixStartInNew = m - suffixCount
        let suffixIntersectionStart = max(suffixStartInNew, min(m, targetRange.lowerBound))
        let suffixIntersectionEnd = max(suffixIntersectionStart, min(m, targetRange.upperBound))

        let oldSuffixOffset = (n - suffixCount) - suffixStartInNew
        for r in suffixIntersectionStart..<suffixIntersectionEnd {
            let oldNum = oldStartLine + r + oldSuffixOffset
            let newNum = newStartLine + r
            let dLine = DiffLine(kind: .unchanged, text: newLines[r], oldLineNumber: oldNum, newLineNumber: newNum)
            result.append((line: dLine, bufferRow: r))
        }

        return (lines: result, additions: additions, deletions: deletions)
    }

    /// Computes unified diff hunks with word-level highlights between old text and new text
    public func diff(
        oldText: String,
        newText: String,
        oldStartLine: Int = 1,
        newStartLine: Int = 1,
        contextLines: Int = 3,
        enablePrefixSuffixPruning: Bool = true
    ) -> [DiffHunk] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        return diff(
            oldLines: oldLines,
            newLines: newLines,
            oldStartLine: oldStartLine,
            newStartLine: newStartLine,
            contextLines: contextLines,
            enablePrefixSuffixPruning: enablePrefixSuffixPruning
        )
    }

    /// Computes unified diff hunks between old lines and new lines
    public func diff(
        oldLines: [String],
        newLines: [String],
        oldStartLine: Int = 1,
        newStartLine: Int = 1,
        contextLines: Int = 3,
        enablePrefixSuffixPruning: Bool = true
    ) -> [DiffHunk] {
        guard oldLines != newLines else { return [] }

        let diffLines: [DiffLine]
        if enablePrefixSuffixPruning {
            diffLines = computeMyersDiff(
                oldLines: oldLines,
                newLines: newLines,
                oldStartLine: oldStartLine,
                newStartLine: newStartLine
            )
        } else {
            diffLines = computeMyersDiffCore(
                oldLines: oldLines,
                oldRange: 0..<oldLines.count,
                newLines: newLines,
                newRange: 0..<newLines.count,
                oldStartLine: oldStartLine,
                newStartLine: newStartLine
            )
        }
        var hunks = groupIntoHunks(diffLines: diffLines, contextLines: contextLines)
        for i in hunks.indices {
            processWordDiffs(lines: &hunks[i].lines)
        }
        return hunks
    }

    /// Myers' Diff Algorithm with Common Prefix and Suffix Pruning Optimization (Zero Array Allocations)
    private func computeMyersDiff(
        oldLines: [String],
        newLines: [String],
        oldStartLine: Int,
        newStartLine: Int
    ) -> [DiffLine] {
        let n = oldLines.count
        let m = newLines.count

        if n == 0 {
            return newLines.enumerated().map { idx, line in
                DiffLine(kind: .added, text: line, oldLineNumber: nil, newLineNumber: newStartLine + idx)
            }
        }
        if m == 0 {
            return oldLines.enumerated().map { idx, line in
                DiffLine(kind: .deleted, text: line, oldLineNumber: oldStartLine + idx, newLineNumber: nil)
            }
        }

        // 1. Common Prefix Pruning: strip identical lines at the start in O(N)
        var prefixCount = 0
        let minCount = min(n, m)
        while prefixCount < minCount && oldLines[prefixCount] == newLines[prefixCount] {
            prefixCount += 1
        }

        // 2. Common Suffix Pruning: strip identical lines at the end in O(N)
        let suffixCount = stableCommonSuffixCount(
            oldLines: oldLines,
            newLines: newLines,
            prefixCount: prefixCount
        )

        // If entire arrays matched via prefix + suffix
        if prefixCount + suffixCount == n && prefixCount + suffixCount == m {
            return oldLines.enumerated().map { idx, line in
                DiffLine(kind: .unchanged, text: line, oldLineNumber: oldStartLine + idx, newLineNumber: newStartLine + idx)
            }
        }

        var result: [DiffLine] = []
        result.reserveCapacity(n + m)

        // Append unchanged common prefix lines
        for i in 0..<prefixCount {
            result.append(DiffLine(
                kind: .unchanged,
                text: oldLines[i],
                oldLineNumber: oldStartLine + i,
                newLineNumber: newStartLine + i
            ))
        }

        // Compute Myers edit graph only on the trimmed middle slice using direct index ranges (0 Array allocations)
        let oldMiddleRange = prefixCount..<(n - suffixCount)
        let newMiddleRange = prefixCount..<(m - suffixCount)
        let trimmedOldStart = oldStartLine + prefixCount
        let trimmedNewStart = newStartLine + prefixCount

        let middleDiff = computeMyersDiffCore(
            oldLines: oldLines,
            oldRange: oldMiddleRange,
            newLines: newLines,
            newRange: newMiddleRange,
            oldStartLine: trimmedOldStart,
            newStartLine: trimmedNewStart
        )
        result.append(contentsOf: middleDiff)

        // Append unchanged common suffix lines
        let oldSuffixStart = n - suffixCount
        let newSuffixStart = m - suffixCount
        for i in 0..<suffixCount {
            result.append(DiffLine(
                kind: .unchanged,
                text: oldLines[oldSuffixStart + i],
                oldLineNumber: oldStartLine + oldSuffixStart + i,
                newLineNumber: newStartLine + newSuffixStart + i
            ))
        }

        return result
    }

    /// Returns a common suffix whose first line is a useful edit boundary.
    ///
    /// A raw suffix scan is ambiguous when an inserted block ends with the same
    /// structural lines as the pre-existing block (`}`, `}`, blank). Matching that
    /// entire suffix moves the old closing lines to the end of the insertion. Keep
    /// the final EOF line as an anchor, but peel low-information boundary lines so
    /// the recursive diff can preserve the earlier, prefix-adjacent occurrence.
    private func stableCommonSuffixCount(
        oldLines: [String],
        newLines: [String],
        prefixCount: Int
    ) -> Int {
        let n = oldLines.count
        let m = newLines.count
        let limit = min(n, m) - prefixCount
        guard limit > 0 else { return 0 }

        var suffixCount = 0
        while suffixCount < limit &&
                oldLines[n - 1 - suffixCount] == newLines[m - 1 - suffixCount] {
            suffixCount += 1
        }

        while suffixCount > 1 && isLowInformationBoundaryLine(oldLines[n - suffixCount]) {
            suffixCount -= 1
        }
        return suffixCount
    }

    private func isLowInformationBoundaryLine(_ line: String) -> Bool {
        let structuralCharacters = CharacterSet(charactersIn: "{}[](),;")
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.unicodeScalars.allSatisfy { structuralCharacters.contains($0) }
    }

    /// Core Myers algorithm executed on direct integer hash ranges with trace vector
    private func computeMyersDiffCore(
        oldLines: [String],
        oldRange: Range<Int>? = nil,
        newLines: [String],
        newRange: Range<Int>? = nil,
        oldStartLine: Int,
        newStartLine: Int
    ) -> [DiffLine] {
        let oRange = oldRange ?? (0..<oldLines.count)
        let nRange = newRange ?? (0..<newLines.count)
        let n = oRange.count
        let m = nRange.count
        let maxD = n + m

        if n == 0 {
            return (0..<m).map { idx in
                DiffLine(kind: .added, text: newLines[nRange.lowerBound + idx], oldLineNumber: nil, newLineNumber: newStartLine + idx)
            }
        }
        if m == 0 {
            return (0..<n).map { idx in
                DiffLine(kind: .deleted, text: oldLines[oRange.lowerBound + idx], oldLineNumber: oldStartLine + idx, newLineNumber: nil)
            }
        }

        // Fast integer hashing of lines: cmp instruction vs String equality
        var stringToId: [String: Int] = [:]
        stringToId.reserveCapacity(n + m)
        var nextId = 1

        var oldIds = [Int]()
        oldIds.reserveCapacity(n)
        for i in oRange {
            let s = oldLines[i]
            if let id = stringToId[s] {
                oldIds.append(id)
            } else {
                let id = nextId
                nextId += 1
                stringToId[s] = id
                oldIds.append(id)
            }
        }

        var newIds = [Int]()
        newIds.reserveCapacity(m)
        for i in nRange {
            let s = newLines[i]
            if let id = stringToId[s] {
                newIds.append(id)
            } else {
                let id = nextId
                nextId += 1
                stringToId[s] = id
                newIds.append(id)
            }
        }

        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 1)
        v[1 + offset] = 0

        var trace: [[Int]] = []
        trace.reserveCapacity(min(maxD + 1, 500))

        var foundD: Int? = nil
        let searchLimit = min(maxD, 400)
        outer: for d in 0...searchLimit {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                let kOffset = k + offset
                var x: Int
                if k == -d || (k != d && v[kOffset - 1] < v[kOffset + 1]) {
                    x = v[kOffset + 1]
                } else {
                    x = v[kOffset - 1] + 1
                }
                var y = x - k

                // Integer comparison is a single 1-cycle CPU instruction
                while x < n && y < m && oldIds[x] == newIds[y] {
                    x += 1
                    y += 1
                }
                v[kOffset] = x

                if x >= n && y >= m {
                    foundD = d
                    break outer
                }
            }
        }

        var currentX = n
        var currentY = m
        var editScript: [(kind: DiffLineKind, oldIdx: Int?, newIdx: Int?)] = []
        editScript.reserveCapacity(maxD)

        if let dMax = foundD {
            for d in (0...dMax).reversed() {
                let vD = trace[d]
                let k = currentX - currentY
                let kOffset = k + offset
                let prevK: Int
                if k == -d || (k != d && vD[kOffset - 1] < vD[kOffset + 1]) {
                    prevK = k + 1
                } else {
                    prevK = k - 1
                }
                let prevKOffset = prevK + offset
                let prevX = vD[prevKOffset]
                let prevY = prevX - prevK

                while currentX > prevX && currentY > prevY {
                    currentX -= 1
                    currentY -= 1
                    editScript.append((.unchanged, oRange.lowerBound + currentX, nRange.lowerBound + currentY))
                }
                if d > 0 {
                    if currentX == prevX {
                        currentY -= 1
                        editScript.append((.added, nil, nRange.lowerBound + currentY))
                    } else if currentY == prevY {
                        currentX -= 1
                        editScript.append((.deleted, oRange.lowerBound + currentX, nil))
                    }
                }
            }
        } else {
            // Fallback for extreme diffs (>400 edits)
            for i in 0..<n {
                editScript.append((.deleted, oRange.lowerBound + i, nil))
            }
            for j in 0..<m {
                editScript.append((.added, nil, nRange.lowerBound + j))
            }
            editScript.reverse()
        }

        editScript.reverse()

        var result: [DiffLine] = []
        result.reserveCapacity(editScript.count)
        var runningOld = oldStartLine
        var runningNew = newStartLine

        for edit in editScript {
            switch edit.kind {
            case .unchanged:
                let line = oldLines[edit.oldIdx!]
                result.append(DiffLine(kind: .unchanged, text: line, oldLineNumber: runningOld, newLineNumber: runningNew))
                runningOld += 1
                runningNew += 1
            case .deleted:
                let line = oldLines[edit.oldIdx!]
                result.append(DiffLine(kind: .deleted, text: line, oldLineNumber: runningOld, newLineNumber: nil))
                runningOld += 1
            case .added:
                let line = newLines[edit.newIdx!]
                result.append(DiffLine(kind: .added, text: line, oldLineNumber: nil, newLineNumber: runningNew))
                runningNew += 1
            case .header:
                break
            }
        }

        return result
    }

    /// Groups continuous diff lines into hunks with context windows
    private func groupIntoHunks(diffLines: [DiffLine], contextLines: Int) -> [DiffHunk] {
        var changeIndices: [Int] = []
        for (i, line) in diffLines.enumerated() {
            if line.kind == .added || line.kind == .deleted {
                changeIndices.append(i)
            }
        }

        guard !changeIndices.isEmpty else { return [] }

        var clusters: [[Int]] = []
        var currentCluster = [changeIndices[0]]

        for idx in changeIndices.dropFirst() {
            if idx - currentCluster.last! <= (contextLines * 2 + 1) {
                currentCluster.append(idx)
            } else {
                clusters.append(currentCluster)
                currentCluster = [idx]
            }
        }
        clusters.append(currentCluster)

        var hunks: [DiffHunk] = []
        for cluster in clusters {
            let firstChange = cluster.first!
            let lastChange = cluster.last!

            let startIdx = max(0, firstChange - contextLines)
            let endIdx = min(diffLines.count - 1, lastChange + contextLines)
            guard startIdx <= endIdx && startIdx >= 0 && endIdx < diffLines.count else { continue }

            let hunkLines = Array(diffLines[startIdx...endIdx])
            let oldStart = hunkLines.compactMap(\.oldLineNumber).first ?? 1
            let oldCount = hunkLines.filter { $0.kind == .unchanged || $0.kind == .deleted }.count
            let newStart = hunkLines.compactMap(\.newLineNumber).first ?? 1
            let newCount = hunkLines.filter { $0.kind == .unchanged || $0.kind == .added }.count

            let oldRange = oldStart..<(oldStart + max(1, oldCount))
            let newRange = newStart..<(newStart + max(1, newCount))

            hunks.append(DiffHunk(
                oldRange: oldRange,
                newRange: newRange,
                header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                lines: hunkLines
            ))
        }

        return hunks
    }

    /// Computes intra-line word diffs for adjacent deleted/added lines in a hunk
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
