import Foundation

public enum MarkdownSelectionLineFinder {
    public static func findBlockLineRanges(blocks: [MarkdownBlock], in fileLines: [String]) -> [ClosedRange<Int>?] {
        var ranges: [ClosedRange<Int>?] = Array(repeating: nil, count: blocks.count)
        guard !fileLines.isEmpty else { return ranges }

        var currentLine = 0
        let total = fileLines.count

        for (idx, block) in blocks.enumerated() {
            guard currentLine < total else { break }
            switch block {
            case .header(_, let text):
                let norm = normalize(text)
                for i in currentLine..<total {
                    let l = fileLines[i]
                    let trimmed = l.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") && (trimmed.contains(text) || normalize(trimmed).contains(norm)) {
                        ranges[idx] = (i + 1)...(i + 1)
                        currentLine = i + 1
                        break
                    }
                }

            case .codeBlock(_, _):
                var fenceStart: Int? = nil
                for i in currentLine..<total {
                    let trimmed = fileLines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                        fenceStart = i
                        break
                    }
                }
                if let start = fenceStart {
                    var fenceEnd = start
                    for i in (start + 1)..<total {
                        let trimmed = fileLines[i].trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                            fenceEnd = i
                            break
                        }
                    }
                    ranges[idx] = (start + 1)...(fenceEnd + 1)
                    currentLine = fenceEnd + 1
                }

            case .paragraph(let text):
                let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let firstLine = lines.first {
                    let normFirst = normalize(firstLine)
                    var startLine: Int? = nil
                    for i in currentLine..<total {
                        let l = fileLines[i]
                        if l.contains(firstLine) || normalize(l).contains(normFirst) {
                            startLine = i
                            break
                        }
                    }
                    if let s = startLine {
                        var endLine = s
                        if lines.count > 1, let lastLine = lines.last {
                            let normLast = normalize(lastLine)
                            for i in s..<total {
                                let l = fileLines[i]
                                if l.contains(lastLine) || normalize(l).contains(normLast) {
                                    endLine = i
                                    break
                                }
                            }
                        }
                        ranges[idx] = (s + 1)...(endLine + 1)
                        currentLine = endLine + 1
                    }
                }

            case .bulletItem(let text):
                let norm = normalize(text)
                for i in currentLine..<total {
                    let l = fileLines[i]
                    if l.contains(text) || normalize(l).contains(norm) {
                        ranges[idx] = (i + 1)...(i + 1)
                        currentLine = i + 1
                        break
                    }
                }

            case .numberedItem(let number, let text):
                let norm = normalize(text)
                for i in currentLine..<total {
                    let l = fileLines[i]
                    let trimmed = l.trimmingCharacters(in: .whitespaces)
                    if (trimmed.hasPrefix("\(number).") || trimmed.hasPrefix("\(number))")) && (l.contains(text) || normalize(l).contains(norm)) {
                        ranges[idx] = (i + 1)...(i + 1)
                        currentLine = i + 1
                        break
                    }
                }

            case .quote(let text):
                let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let firstLine = lines.first {
                    let normFirst = normalize(firstLine)
                    for i in currentLine..<total {
                        let l = fileLines[i]
                        let trimmed = l.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix(">") && (l.contains(firstLine) || normalize(l).contains(normFirst)) {
                            var endLine = i
                            if lines.count > 1, let lastLine = lines.last {
                                let normLast = normalize(lastLine)
                                for j in i..<total {
                                    let l2 = fileLines[j]
                                    if l2.contains(lastLine) || normalize(l2).contains(normLast) {
                                        endLine = j
                                        break
                                    }
                                }
                            }
                            ranges[idx] = (i + 1)...(endLine + 1)
                            currentLine = endLine + 1
                            break
                        }
                    }
                }

            case .table(let headers, let rows):
                if let firstHeader = headers.first {
                    let norm = normalize(firstHeader)
                    for i in currentLine..<total {
                        let l = fileLines[i]
                        if l.contains("|") && (l.contains(firstHeader) || normalize(l).contains(norm)) {
                            let tableRowsCount = 2 + rows.count
                            let endLine = min(total - 1, i + tableRowsCount - 1)
                            ranges[idx] = (i + 1)...(endLine + 1)
                            currentLine = endLine + 1
                            break
                        }
                    }
                }

            case .divider:
                for i in currentLine..<total {
                    let trimmed = fileLines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                        ranges[idx] = (i + 1)...(i + 1)
                        currentLine = i + 1
                        break
                    }
                }

            case .image(_, let path):
                for i in currentLine..<total {
                    let l = fileLines[i]
                    if l.contains(path) {
                        ranges[idx] = (i + 1)...(i + 1)
                        currentLine = i + 1
                        break
                    }
                }
            }
        }
        return ranges
    }

    public static func findLineRange(
        in fileLines: [String],
        for selectedText: String,
        hintRange: ClosedRange<Int>? = nil
    ) -> ClosedRange<Int>? {
        guard !fileLines.isEmpty else { return nil }

        let selLines = selectedText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstSnippet = selLines.first else { return nil }
        let lastSnippet = selLines.last ?? firstSnippet

        // 1. If hintRange provided, search within slice first
        if let hint = hintRange {
            let startLine0 = max(0, hint.lowerBound - 1)
            let endLine0 = min(fileLines.count - 1, hint.upperBound - 1)
            if startLine0 <= endLine0 {
                if let found = findRangeInSlice(fileLines, from: startLine0, to: endLine0, first: firstSnippet, last: lastSnippet, isMultiLine: selLines.count > 1) {
                    return found
                }
            }
        }

        // 2. Search entire file
        return findRangeInSlice(fileLines, from: 0, to: fileLines.count - 1, first: firstSnippet, last: lastSnippet, isMultiLine: selLines.count > 1)
    }

    private static func findRangeInSlice(
        _ fileLines: [String],
        from: Int,
        to: Int,
        first: String,
        last: String,
        isMultiLine: Bool
    ) -> ClosedRange<Int>? {
        let normFirst = normalize(first)
        let normLast = normalize(last)

        var matchedStart: Int? = nil

        for i in from...to {
            let line = fileLines[i]
            let normLine = normalize(line)

            if matchedStart == nil {
                if line.contains(first) || normLine.contains(normFirst) {
                    matchedStart = i
                    if !isMultiLine {
                        return (i + 1)...(i + 1)
                    }
                }
            } else if let s = matchedStart {
                if line.contains(last) || normLine.contains(normLast) {
                    return (s + 1)...(i + 1)
                }
            }
        }

        if let s = matchedStart {
            return (s + 1)...(s + 1)
        }
        return nil
    }

    public static func normalize(_ str: String) -> String {
        var s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- [x] ") || s.hasPrefix("- [ ] ") {
            s = String(s.dropFirst(6))
        } else if s.hasPrefix("☑ ") || s.hasPrefix("☐ ") {
            s = String(s.dropFirst(2))
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            s = String(s.dropFirst(2))
        } else if s.hasPrefix("> ") {
            s = String(s.dropFirst(2))
        }
        while s.hasPrefix("#") {
            s = String(s.dropFirst())
        }
        s = s.replacingOccurrences(of: "**", with: "")
             .replacingOccurrences(of: "__", with: "")
             .replacingOccurrences(of: "`", with: "")
             .trimmingCharacters(in: .whitespaces)
        return s.lowercased()
    }
}
