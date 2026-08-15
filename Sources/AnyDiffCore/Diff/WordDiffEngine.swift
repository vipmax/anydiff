import Foundation

/// Word-level and character-level diff calculator for intra-line highlighting
public final class WordDiffEngine: Sendable {
    public static let shared = WordDiffEngine()

    public init() {}

    /// Computes diff highlight ranges for a pair of old line and new line
    public func diffWords(oldText: String, newText: String) -> (oldDiffRanges: [Range<Int>], newDiffRanges: [Range<Int>]) {
        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        guard !oldTokens.isEmpty && !newTokens.isEmpty else {
            return ([], [])
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
                // Matched token
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            } else {
                // Discrepancy range
                let oldStartToken = oldIdx
                while oldIdx < oldTokens.count && (lcsIdx >= lcs.count || oldTokens[oldIdx].text != lcs[lcsIdx]) {
                    oldIdx += 1
                }
                if oldIdx > oldStartToken {
                    let charStart = oldTokens[oldStartToken].range.lowerBound
                    let charEnd = oldTokens[oldIdx - 1].range.upperBound
                    oldDiffs.append(charStart..<charEnd)
                }

                let newStartToken = newIdx
                while newIdx < newTokens.count && (lcsIdx >= lcs.count || newTokens[newIdx].text != lcs[lcsIdx]) {
                    newIdx += 1
                }
                if newIdx > newStartToken {
                    let charStart = newTokens[newStartToken].range.lowerBound
                    let charEnd = newTokens[newIdx - 1].range.upperBound
                    newDiffs.append(charStart..<charEnd)
                }
            }
        }

        return (oldDiffs, newDiffs)
    }

    private struct Token {
        let text: String
        let range: Range<Int>
    }

    /// Splits text into word/punctuation/whitespace tokens with character offsets
    private func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let utf16 = Array(text.utf16)
        var i = 0

        while i < utf16.count {
            let start = i
            let char = Character(UnicodeScalar(utf16[i])!)

            if char.isWhitespace {
                while i < utf16.count && Character(UnicodeScalar(utf16[i])!).isWhitespace {
                    i += 1
                }
            } else if char.isLetter || char.isNumber || char == "_" {
                while i < utf16.count {
                    let c = Character(UnicodeScalar(utf16[i])!)
                    if c.isLetter || c.isNumber || c == "_" {
                        i += 1
                    } else {
                        break
                    }
                }
            } else {
                // Single punctuation or operator
                i += 1
            }

            let startIdx = text.index(text.startIndex, offsetBy: start)
            let endIdx = text.index(text.startIndex, offsetBy: i)
            let tokenStr = String(text[startIdx..<endIdx])
            tokens.append(Token(text: tokenStr, range: start..<i))
        }

        return tokens
    }

    /// Computes Longest Common Subsequence of tokens
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count
        let m = b.count
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
