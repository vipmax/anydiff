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

        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        guard !oldTokens.isEmpty && !newTokens.isEmpty else {
            return ([], [])
        }

        let lcs = computeLCS(oldTokens, newTokens)
        let totalTokens = oldTokens.count + newTokens.count
        guard !lcs.isEmpty, totalTokens > 0 else { return ([], []) }

        // Similarity check: if shared tokens are less than 25% of total tokens,
        // it's a completely different line — suppress word diff to avoid noise.
        let similarity = Double(lcs.count * 2) / Double(totalTokens)
        if similarity < 0.25 {
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

    /// Splits text into word/punctuation/whitespace tokens with character offsets and 32-bit FNV-1a hashes (Zero Heap Allocations)
    public func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = []
        tokens.reserveCapacity(min(64, text.count / 3 + 1))

        let utf8 = text.utf8
        let handled = utf8.withContiguousStorageIfAvailable { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            let count = buffer.count
            var i = 0
            var charOffset = 0

            @inline(__always)
            func isWordByte(_ b: UInt8) -> Bool {
                (b >= 0x30 && b <= 0x39) || // 0-9
                (b >= 0x41 && b <= 0x5A) || // A-Z
                (b >= 0x61 && b <= 0x7A) || // a-z
                b == 0x5F                   // _
            }

            @inline(__always)
            func isWhitespaceByte(_ b: UInt8) -> Bool {
                b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
            }

            while i < count {
                let startChar = charOffset
                let b = base[i]

                var h: UInt32 = 2166136261
                if isWhitespaceByte(b) {
                    while i < count && isWhitespaceByte(base[i]) {
                        h = (h ^ UInt32(base[i])) &* 16777619
                        i += 1
                        charOffset += 1
                    }
                } else if isWordByte(b) {
                    while i < count && isWordByte(base[i]) {
                        h = (h ^ UInt32(base[i])) &* 16777619
                        i += 1
                        charOffset += 1
                    }
                } else if b < 0x80 {
                    h = (h ^ UInt32(b)) &* 16777619
                    i += 1
                    charOffset += 1
                } else {
                    let chStart = i
                    i += 1
                    while i < count && (base[i] & 0xC0) == 0x80 { i += 1 }
                    let scalarLen = i - chStart
                    for k in 0..<scalarLen {
                        h = (h ^ UInt32(base[chStart + k])) &* 16777619
                    }
                    charOffset += 1
                }

                tokens.append(Token(hash: h, range: startChar..<charOffset))
            }
            return true
        } ?? false

        if handled {
            return tokens
        }

        // Fallback for non-contiguous string representation
        let scalars = text.unicodeScalars
        var idx = scalars.startIndex
        var charOffset = 0
        while idx < scalars.endIndex {
            let start = charOffset
            let ch = scalars[idx]
            var h: UInt32 = 2166136261
            if ch.value == 0x20 || ch.value == 0x09 || (ch.value > 127 && ch.properties.isWhitespace) {
                while idx < scalars.endIndex && (scalars[idx].value == 0x20 || scalars[idx].value == 0x09 || (scalars[idx].value > 127 && scalars[idx].properties.isWhitespace)) {
                    h = (h ^ scalars[idx].value) &* 16777619
                    idx = scalars.index(after: idx)
                    charOffset += 1
                }
            } else if (ch.value >= 0x30 && ch.value <= 0x39) || (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A) || ch.value == 0x5F || (ch.value > 127 && ch.properties.isAlphabetic) {
                while idx < scalars.endIndex && ((scalars[idx].value >= 0x30 && scalars[idx].value <= 0x39) || (scalars[idx].value >= 0x41 && scalars[idx].value <= 0x5A) || (scalars[idx].value >= 0x61 && scalars[idx].value <= 0x7A) || scalars[idx].value == 0x5F || (scalars[idx].value > 127 && scalars[idx].properties.isAlphabetic)) {
                    h = (h ^ scalars[idx].value) &* 16777619
                    idx = scalars.index(after: idx)
                    charOffset += 1
                }
            } else {
                h = (h ^ ch.value) &* 16777619
                idx = scalars.index(after: idx)
                charOffset += 1
            }
            tokens.append(Token(hash: h, range: start..<charOffset))
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
    /// 1. Equal line count (1:1 or N:N line replacement only).
    /// 2. Line count cap (<= 8 lines).
    /// 3. Similarity check (skips completely unrelated code rewrites).
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

                // Only perform word diff if deletedCount == addedCount (1:1 or N:N replacement)
                // and the count does not exceed MAX_WORD_DIFF_LINE_COUNT (8).
                guard deletedIndices.count == addedIndices.count && deletedIndices.count <= 8 else {
                    continue
                }

                for k in 0..<deletedIndices.count {
                    let dIdx = deletedIndices[k]
                    let aIdx = addedIndices[k]
                    let (oldRanges, newRanges) = diffWords(
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
