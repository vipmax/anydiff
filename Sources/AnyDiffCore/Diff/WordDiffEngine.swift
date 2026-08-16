import Foundation

/// Word-level and character-level diff calculator for intra-line highlighting
public final class WordDiffEngine: Sendable {
    public static let shared = WordDiffEngine()

    public init() {}

    public struct Token: Sendable {
        public let text: String
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

        let lcs = computeLCS(oldTokens.map(\.text), newTokens.map(\.text))

        var oldDiffs: [Range<Int>] = []
        var newDiffs: [Range<Int>] = []

        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldTokens.count || newIdx < newTokens.count {
            if lcsIdx < lcs.count && oldIdx < oldTokens.count && newIdx < newTokens.count &&
                oldTokens[oldIdx].text == lcs[lcsIdx] && newTokens[newIdx].text == lcs[lcsIdx] {
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            } else {
                let oldStart = oldIdx
                while oldIdx < oldTokens.count && (lcsIdx >= lcs.count || oldTokens[oldIdx].text != lcs[lcsIdx]) {
                    oldIdx += 1
                }
                if oldIdx > oldStart {
                    let charStart = oldTokens[oldStart].range.lowerBound
                    let charEnd = oldTokens[oldIdx - 1].range.upperBound
                    oldDiffs.append(charStart..<charEnd)
                }

                let newStart = newIdx
                while newIdx < newTokens.count && (lcsIdx >= lcs.count || newTokens[newIdx].text != lcs[lcsIdx]) {
                    newIdx += 1
                }
                if newIdx > newStart {
                    let charStart = newTokens[newStart].range.lowerBound
                    let charEnd = newTokens[newIdx - 1].range.upperBound
                    newDiffs.append(charStart..<charEnd)
                }

                // Safety guarantee: always advance to prevent any infinite loop
                if oldIdx == oldStart && newIdx == newStart {
                    if oldIdx < oldTokens.count && (lcsIdx >= lcs.count || oldTokens[oldIdx].text != lcs[lcsIdx]) {
                        oldDiffs.append(oldTokens[oldIdx].range)
                        oldIdx += 1
                    } else if newIdx < newTokens.count && (lcsIdx >= lcs.count || newTokens[newIdx].text != lcs[lcsIdx]) {
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

    /// Splits text into word/punctuation/whitespace tokens with character offsets
    public func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        let count = chars.count
        var i = 0

        while i < count {
            let start = i
            let ch = chars[i]

            if ch.isWhitespace {
                while i < count && chars[i].isWhitespace {
                    i += 1
                }
            } else if ch.isLetter || ch.isNumber || ch == "_" {
                while i < count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
            } else {
                i += 1
            }

            let tokenStr = String(chars[start..<i])
            tokens.append(Token(text: tokenStr, range: start..<i))
        }

        return tokens
    }

    /// Computes Longest Common Subsequence of tokens (capped at 200 tokens)
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let n = min(a.count, 200)
        let m = min(b.count, 200)
        guard n > 0 && m > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in 0..<n {
            for j in 0..<m {
                if a[i] == b[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var lcs: [String] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }
}
