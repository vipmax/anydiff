import Foundation

/// Fast Myers diff engine for computing line-level unified diff hunks on live edits
public final class LineDiffEngine: Sendable {
    public static let shared = LineDiffEngine()

    public init() {}

    /// Computes unified diff hunks with word-level highlights between old text and new text
    public func diff(
        oldText: String,
        newText: String,
        contextLines: Int = 3
    ) -> [DiffHunk] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        return diff(oldLines: oldLines, newLines: newLines, contextLines: contextLines)
    }

    /// Computes unified diff hunks between old lines and new lines
    public func diff(
        oldLines: [String],
        newLines: [String],
        contextLines: Int = 3
    ) -> [DiffHunk] {
        guard oldLines != newLines else { return [] }

        let diffLines = computeMyersDiff(oldLines: oldLines, newLines: newLines)
        var hunks = groupIntoHunks(diffLines: diffLines, contextLines: contextLines)
        for i in hunks.indices {
            processWordDiffs(lines: &hunks[i].lines)
        }
        return hunks
    }

    /// Myers' Diff Algorithm for shortest edit script (SES)
    private func computeMyersDiff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let n = oldLines.count
        let m = newLines.count
        let maxD = n + m

        if n == 0 {
            return newLines.enumerated().map { idx, line in
                DiffLine(kind: .added, text: line, oldLineNumber: nil, newLineNumber: idx + 1)
            }
        }
        if m == 0 {
            return oldLines.enumerated().map { idx, line in
                DiffLine(kind: .deleted, text: line, oldLineNumber: idx + 1, newLineNumber: nil)
            }
        }

        var v = [Int: Int]()
        v[1] = 0
        var trace: [[Int: Int]] = []

        var foundD: Int? = nil
        outer: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                    x = v[k + 1] ?? 0
                } else {
                    x = (v[k - 1] ?? 0) + 1
                }
                var y = x - k

                while x < n && y < m && oldLines[x] == newLines[y] {
                    x += 1
                    y += 1
                }
                v[k] = x

                if x >= n && y >= m {
                    foundD = d
                    break outer
                }
            }
        }

        // Backtrack to reconstruct edit path
        var currentX = n
        var currentY = m
        var editScript: [(kind: DiffLineKind, oldIdx: Int?, newIdx: Int?)] = []

        if let dMax = foundD {
            for d in (0...dMax).reversed() {
                let vD = trace[d]
                let k = currentX - currentY
                let prevK: Int
                if k == -d || (k != d && (vD[k - 1] ?? 0) < (vD[k + 1] ?? 0)) {
                    prevK = k + 1
                } else {
                    prevK = k - 1
                }
                let prevX = vD[prevK] ?? 0
                let prevY = prevX - prevK

                while currentX > prevX && currentY > prevY {
                    currentX -= 1
                    currentY -= 1
                    editScript.append((.unchanged, currentX, currentY))
                }
                if d > 0 {
                    if currentX == prevX {
                        currentY -= 1
                        editScript.append((.added, nil, currentY))
                    } else if currentY == prevY {
                        currentX -= 1
                        editScript.append((.deleted, currentX, nil))
                    }
                }
            }
        }

        editScript.reverse()

        var result: [DiffLine] = []
        var runningOld = 1
        var runningNew = 1

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

        // Group changes within 2 * contextLines of each other into clusters
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

            let hunk = DiffHunk(
                oldRange: oldRange,
                newRange: newRange,
                header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                lines: hunkLines
            )
            hunks.append(hunk)
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
