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

        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        guard !oldTokens.isEmpty && !newTokens.isEmpty else {
            let oldR: [Range<Int>] = oldText.isEmpty ? [] : [0..<oldText.count]
            let newR: [Range<Int>] = newText.isEmpty ? [] : [0..<newText.count]
            return (oldR, newR)
        }

        let lcs = computeLCS(oldTokens.map(\.hash), newTokens.map(\.hash))

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

    /// Splits text into word/punctuation/whitespace tokens with character offsets and 32-bit FNV-1a hashes
    public func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        let count = chars.count
        var i = 0

        while i < count {
            let start = i
            let ch = chars[i]

            var h: UInt32 = 2166136261
            if ch.isWhitespace {
                while i < count && chars[i].isWhitespace {
                    if let scalar = chars[i].unicodeScalars.first?.value {
                        h = (h ^ scalar) &* 16777619
                    }
                    i += 1
                }
            } else if ch.isLetter || ch.isNumber || ch == "_" {
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    if let scalar = chars[i].unicodeScalars.first?.value {
                        h = (h ^ scalar) &* 16777619
                    }
                    i += 1
                }
            } else {
                if let scalar = ch.unicodeScalars.first?.value {
                    h = (h ^ scalar) &* 16777619
                }
                i += 1
            }

            tokens.append(Token(hash: h, range: start..<i))
        }

        return tokens
    }

    /// Computes Longest Common Subsequence of 32-bit token hashes (capped at 200 tokens) using a flat 1D buffer
    private func computeLCS(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let n = min(a.count, 200)
        let m = min(b.count, 200)
        guard n > 0 && m > 0 else { return [] }

        let stride = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * stride)

        for i in 0..<n {
            let rowOffset = (i + 1) * stride
            let prevRowOffset = i * stride
            for j in 0..<m {
                if a[i] == b[j] {
                    dp[rowOffset + j + 1] = dp[prevRowOffset + j] + 1
                } else {
                    dp[rowOffset + j + 1] = max(dp[prevRowOffset + j + 1], dp[rowOffset + j])
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
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[prevRowOffset + j] >= dp[rowOffset + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }
}
