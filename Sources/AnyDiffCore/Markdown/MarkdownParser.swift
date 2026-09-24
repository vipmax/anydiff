import Foundation

public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var currentLanguage: String? = nil
        var currentCodeLines: [String] = []
        var currentParagraphLines: [String] = []
        var currentQuoteLines: [String] = []

        func flushParagraph() {
            if !currentParagraphLines.isEmpty {
                let text = currentParagraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.paragraph(text))
                }
                currentParagraphLines.removeAll()
            }
        }

        func flushQuote() {
            if !currentQuoteLines.isEmpty {
                let text = currentQuoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(.quote(text))
                }
                currentQuoteLines.removeAll()
            }
        }

        var lineIndex = 0
        let totalLines = lines.count

        while lineIndex < totalLines {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Code Block Fence (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCodeBlock {
                    let code = currentCodeLines.joined(separator: "\n")
                    blocks.append(.codeBlock(language: currentLanguage, code: code))
                    currentCodeLines.removeAll()
                    currentLanguage = nil
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    flushQuote()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    currentLanguage = lang.isEmpty ? nil : lang
                    currentCodeLines.removeAll()
                    inCodeBlock = true
                }
                lineIndex += 1
                continue
            }

            if inCodeBlock {
                currentCodeLines.append(line)
                lineIndex += 1
                continue
            }

            // 2. Quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                if let gtIdx = line.firstIndex(of: ">") {
                    let afterGt = line[line.index(after: gtIdx)...]
                    currentQuoteLines.append(String(afterGt).trimmingCharacters(in: .whitespaces))
                }
                lineIndex += 1
                continue
            } else if !currentQuoteLines.isEmpty {
                flushQuote()
            }

            // 3. Thematic break / Divider (---, ***, ___)
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                lineIndex += 1
                continue
            }

            // 4. Headers (#, ##, ###, ####, #####, ######)
            if trimmed.hasPrefix("#") {
                var level = 0
                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }
                if level >= 1 && level <= 6 {
                    let afterHashes = trimmed.dropFirst(level)
                    if afterHashes.hasPrefix(" ") || afterHashes.hasPrefix("\t") {
                        flushParagraph()
                        let headerText = afterHashes.trimmingCharacters(in: .whitespaces)
                        blocks.append(.header(level: level, text: headerText))
                        lineIndex += 1
                        continue
                    }
                }
            }

            // 5. Tables: Check for header row + delimiter row
            if trimmed.contains("|") && lineIndex + 1 < totalLines {
                let nextTrimmed = lines[lineIndex + 1].trimmingCharacters(in: .whitespaces)
                if isTableDelimiterRow(nextTrimmed) {
                    flushParagraph()
                    let headers = parseTableRow(trimmed)
                    var rows: [[String]] = []
                    lineIndex += 2 // skip header and delimiter

                    while lineIndex < totalLines {
                        let rowLine = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                        if rowLine.isEmpty || !rowLine.contains("|") {
                            break
                        }
                        rows.append(parseTableRow(rowLine))
                        lineIndex += 1
                    }

                    blocks.append(.table(headers: headers, rows: rows))
                    continue
                }
            }

            // 6. Bullet Items (- , * , + )
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                var itemText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if itemText.hasPrefix("[ ] ") {
                    itemText = "☐ " + itemText.dropFirst(4)
                } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
                    itemText = "☑ " + itemText.dropFirst(4)
                }
                if !itemText.isEmpty {
                    blocks.append(.bulletItem(itemText))
                }
                lineIndex += 1
                continue
            }

            // 7. Numbered list items (e.g. "1. ", "2) ")
            if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let prefix = String(trimmed[match])
                let number = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".) \t"))
                var itemText = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if itemText.hasPrefix("[ ] ") {
                    itemText = "☐ " + itemText.dropFirst(4)
                } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
                    itemText = "☑ " + itemText.dropFirst(4)
                }
                if !itemText.isEmpty {
                    blocks.append(.numberedItem(number: number, text: itemText))
                }
                lineIndex += 1
                continue
            }

            // 8. Standalone Image (![alt](path))
            if let imageInfo = parseStandaloneImage(trimmed) {
                flushParagraph()
                blocks.append(.image(alt: imageInfo.alt, path: imageInfo.path))
                lineIndex += 1
                continue
            }

            // 9. Empty lines
            if trimmed.isEmpty {
                flushParagraph()
                lineIndex += 1
                continue
            }

            currentParagraphLines.append(line)
            lineIndex += 1
        }

        if inCodeBlock {
            let code = currentCodeLines.joined(separator: "\n")
            blocks.append(.codeBlock(language: currentLanguage, code: code))
        }
        flushParagraph()
        flushQuote()

        return blocks
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let nonSpace = trimmed.filter { !$0.isWhitespace }
        guard nonSpace.count >= 3 else { return false }
        return nonSpace.allSatisfy({ $0 == "-" }) ||
               nonSpace.allSatisfy({ $0 == "*" }) ||
               nonSpace.allSatisfy({ $0 == "_" })
    }

    private static func isTableDelimiterRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("-") && trimmed.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "|- :")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            trimmed = String(trimmed.dropFirst())
        }
        if trimmed.hasSuffix("|") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseStandaloneImage(_ trimmed: String) -> (alt: String, path: String)? {
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let closeBracketIndex = trimmed.firstIndex(of: "]"),
              let openParenIndex = trimmed[closeBracketIndex...].firstIndex(of: "(") else {
            return nil
        }
        guard trimmed.index(after: closeBracketIndex) == openParenIndex else {
            return nil
        }
        let afterOpenParen = trimmed[trimmed.index(after: openParenIndex)...]
        guard let closeParenIndex = afterOpenParen.firstIndex(of: ")"),
              trimmed.index(after: closeParenIndex) == trimmed.endIndex else {
            return nil
        }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracketIndex])
        let pathPart = trimmed[trimmed.index(after: openParenIndex)..<closeParenIndex]
            .trimmingCharacters(in: .whitespaces)
        let url: String
        if let spaceIdx = pathPart.firstIndex(where: { $0.isWhitespace }) {
            url = String(pathPart[..<spaceIdx])
        } else {
            url = pathPart
        }
        guard !url.isEmpty else { return nil }
        return (alt: alt, path: url)
    }
}
