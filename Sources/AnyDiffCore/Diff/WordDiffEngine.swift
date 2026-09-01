import Foundation

/// Word-level and character-level diff calculator for intra-line highlighting (Zero-Allocation)
public final class WordDiffEngine: Sendable {
    public static let shared = WordDiffEngine()

    public init() {}

    public struct Token: Sendable {
        public let hash: UInt32
        public let range: Range<Int>
    }

    /// Computes diff highlight ranges for a pair of old line and new line
    public func diffWords(oldText: String, newText: String) -> (oldDiffRanges: [Range<Int>], newDiffRanges: [Range<Int>]) {
        guard oldText != newText else { return ([], []) }

        // Skip lines exceeding 512 bytes (MAX_WORD_DIFF_LEN)
        if oldText.utf8.count > 512 || newText.utf8.count > 512 {
            return ([], [])
        }

        // Fast path for whitespace-only / empty line differences (Zero Allocations)
        if isWhitespaceOrEmpty(oldText) && isWhitespaceOrEmpty(newText) {
            return diffWhitespaceLines(oldText: oldText, newText: newText)
        }

        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        guard !oldTokens.isEmpty && !newTokens.isEmpty else {
            return ([], [])
        }

        let totalTokens = oldTokens.count + newTokens.count
        guard totalTokens > 0 else { return ([], []) }

        // Early-exit: if the maximum possible LCS cannot reach 60% similarity,
        // avoid running the O(N x M) DP table computation.
        let maxPossibleLCS = min(oldTokens.count, newTokens.count)
        let maxPossibleSimilarity = Double(maxPossibleLCS * 2) / Double(totalTokens)
        if maxPossibleSimilarity < 0.60 {
            return ([], [])
        }

        let lcs = computeLCS(oldTokens, newTokens)
        guard !lcs.isEmpty else { return ([], []) }

        // Similarity check: if shared tokens are less than 60% of total tokens,
        // it's a completely different line — suppress word diff to avoid noise.
        let similarity = Double(lcs.count * 2) / Double(totalTokens)
        if similarity < 0.60 {
            return ([], [])
        }

        var oldDiffs: [Range<Int>] = []
        var newDiffs: [Range<Int>] = []

        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldTokens.count || newIdx < newTokens.count {
            if lcsIdx < lcs.count && oldIdx < oldTokens.count && newIdx < newTokens.count &&
                oldTokens[oldIdx].hash == lcs[lcsIdx] && newTokens[newIdx].hash == lcs[lcsIdx] {
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            } else {
                let oldStart = oldIdx
                while oldIdx < oldTokens.count && (lcsIdx >= lcs.count || oldTokens[oldIdx].hash != lcs[lcsIdx]) {
                    oldIdx += 1
                }
                if oldIdx > oldStart {
                    let charStart = oldTokens[oldStart].range.lowerBound
                    let charEnd = oldTokens[oldIdx - 1].range.upperBound
                    oldDiffs.append(charStart..<charEnd)
                }

                let newStart = newIdx
                while newIdx < newTokens.count && (lcsIdx >= lcs.count || newTokens[newIdx].hash != lcs[lcsIdx]) {
                    newIdx += 1
                }
                if newIdx > newStart {
                    let charStart = newTokens[newStart].range.lowerBound
                    let charEnd = newTokens[newIdx - 1].range.upperBound
                    newDiffs.append(charStart..<charEnd)
                }

                // Safety guarantee: always advance to prevent any infinite loop
                if oldIdx == oldStart && newIdx == newStart {
                    if oldIdx < oldTokens.count && (lcsIdx >= lcs.count || oldTokens[oldIdx].hash != lcs[lcsIdx]) {
                        oldDiffs.append(oldTokens[oldIdx].range)
                        oldIdx += 1
                    } else if newIdx < newTokens.count && (lcsIdx >= lcs.count || newTokens[newIdx].hash != lcs[lcsIdx]) {
                        newDiffs.append(newTokens[newIdx].range)
                        newIdx += 1
                    } else {
                        if oldIdx < oldTokens.count {
                            oldDiffs.append(oldTokens[oldIdx].range)
                            oldIdx += 1
                        }
                        if newIdx < newTokens.count {
                            newDiffs.append(newTokens[newIdx].range)
                            newIdx += 1
                        }
                        if lcsIdx < lcs.count {
                            lcsIdx += 1
                        }
                    }
                }
            }
        }

        return (oldDiffs, newDiffs)
    }

    @inline(__always)
    private func isWhitespaceOrEmpty(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if !scalar.properties.isWhitespace {
                return false
            }
        }
        return true
    }

    /// Fast, zero-allocation comparison for lines containing only whitespace and/or empty lines
    private func diffWhitespaceLines(oldText: String, newText: String) -> (oldDiffRanges: [Range<Int>], newDiffRanges: [Range<Int>]) {
        let oldScalars = oldText.unicodeScalars
        let newScalars = newText.unicodeScalars

        var oldIdx = oldScalars.startIndex
        var newIdx = newScalars.startIndex
        var prefixLen = 0

        while oldIdx < oldScalars.endIndex && newIdx < newScalars.endIndex && oldScalars[oldIdx] == newScalars[newIdx] {
            prefixLen += 1
            oldIdx = oldScalars.index(after: oldIdx)
            newIdx = newScalars.index(after: newIdx)
        }

        var oldEnd = oldScalars.endIndex
        var newEnd = newScalars.endIndex
        var oldSuffixLen = 0
        var newSuffixLen = 0

        while oldEnd > oldIdx && newEnd > newIdx {
            let prevOld = oldScalars.index(before: oldEnd)
            let prevNew = newScalars.index(before: newEnd)
            if oldScalars[prevOld] == newScalars[prevNew] {
                oldEnd = prevOld
                newEnd = prevNew
                oldSuffixLen += 1
                newSuffixLen += 1
            } else {
                break
            }
        }

        let oldEndOffset = oldText.count - oldSuffixLen
        let newEndOffset = newText.count - newSuffixLen

        var oldDiffs: [Range<Int>] = []
        var newDiffs: [Range<Int>] = []

        if prefixLen < oldEndOffset {
            oldDiffs.reserveCapacity(1)
            oldDiffs.append(prefixLen..<oldEndOffset)
        }
        if prefixLen < newEndOffset {
            newDiffs.reserveCapacity(1)
            newDiffs.append(prefixLen..<newEndOffset)
        }

        return (oldDiffs, newDiffs)
    }

    /// Splits text into word/punctuation/whitespace tokens with character offsets and 32-bit FNV-1a hashes
    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = []
        tokens.reserveCapacity(min(64, text.count / 3 + 1))

        @inline(__always)
        func isWord(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            return (v >= 0x30 && v <= 0x39) || // 0-9
                   (v >= 0x41 && v <= 0x5A) || // A-Z
                   (v >= 0x61 && v <= 0x7A) || // a-z
                   v == 0x5F ||                 // _
                   s.properties.isAlphabetic ||
                   s.properties.numericType != nil
        }

        let scalars = text.unicodeScalars
        var idx = scalars.startIndex
        var charOffset = 0

        while idx < scalars.endIndex {
            let startChar = charOffset
            let s = scalars[idx]
            var h: UInt32 = 2166136261

            if s.properties.isWhitespace {
                while idx < scalars.endIndex && scalars[idx].properties.isWhitespace {
                    let cur = scalars[idx]
                    h = (h ^ cur.value) &* 16777619
                    charOffset += cur.utf16.count
                    idx = scalars.index(after: idx)
                }
            } else if isWord(s) {
                while idx < scalars.endIndex && isWord(scalars[idx]) {
                    let cur = scalars[idx]
                    h = (h ^ cur.value) &* 16777619
                    charOffset += cur.utf16.count
                    idx = scalars.index(after: idx)
                }
            } else {
                h = (h ^ s.value) &* 16777619
                charOffset += s.utf16.count
                idx = scalars.index(after: idx)
            }

            tokens.append(Token(hash: h, range: startChar..<charOffset))
        }

        return tokens
    }

    /// Computes Longest Common Subsequence of 32-bit token hashes (capped at 200 tokens)
    /// using stack allocation with zero heap overhead and L1-cache locality.
    private func computeLCS(_ a: [Token], _ b: [Token]) -> [UInt32] {
        let n = min(a.count, 200)
        let m = min(b.count, 200)
        guard n > 0 && m > 0 else { return [] }

        let stride = m + 1
        let totalSize = (n + 1) * stride

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: totalSize) { dpBuffer in
            dpBuffer.initialize(repeating: 0)

            for i in 0..<n {
                let rowOffset = (i + 1) * stride
                let prevRowOffset = i * stride
                let aHash = a[i].hash
                for j in 0..<m {
                    if aHash == b[j].hash {
                        dpBuffer[rowOffset + j + 1] = dpBuffer[prevRowOffset + j] &+ 1
                    } else {
                        dpBuffer[rowOffset + j + 1] = max(dpBuffer[prevRowOffset + j + 1], dpBuffer[rowOffset + j])
                    }
                }
            }

            var lcs: [UInt32] = []
            lcs.reserveCapacity(min(n, m))
            var i = n
            var j = m
            while i > 0 && j > 0 {
                let rowOffset = i * stride
                let prevRowOffset = (i - 1) * stride
                if a[i - 1].hash == b[j - 1].hash {
                    lcs.append(a[i - 1].hash)
                    i -= 1
                    j -= 1
                } else if dpBuffer[prevRowOffset + j] >= dpBuffer[rowOffset + j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }

            return lcs.reversed()
        }
    }

    /// Computes intra-line word diffs for adjacent deleted/added lines in a hunk
    /// following balanced word-diff rules:
    /// 1. Only one deleted line paired with one added line.
    /// 2. Similarity check (skips completely unrelated code rewrites).
    public func processWordDiffs(lines: inout [DiffLine]) {
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

                // Only perform word diff for a single-line replacement. Multi-line
                // replacements are easier to read with line-level highlighting only.
                guard deletedIndices.count == 1 && addedIndices.count == 1 else {
                    continue
                }

                let dIdx = deletedIndices[0]
                let aIdx = addedIndices[0]
                let (oldRanges, newRanges) = diffWords(
                    oldText: lines[dIdx].text,
                    newText: lines[aIdx].text
                )
                lines[dIdx].wordDiffRanges = oldRanges
                lines[aIdx].wordDiffRanges = newRanges
            } else {
                i += 1
            }
        }
    }
}
