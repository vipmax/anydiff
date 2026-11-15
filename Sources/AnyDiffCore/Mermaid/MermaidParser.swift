import Foundation

public enum MermaidParser {
    public static func parse(_ source: String) throws -> MermaidParsedDiagram {
        let lines = preprocessLines(source)
        guard let firstLine = lines.first else {
            throw MermaidError.emptyInput
        }

        let lower = firstLine.lowercased()
        if lower.hasPrefix("flowchart") || lower.hasPrefix("graph") {
            return .graph(try parseFlowchart(lines: lines))
        }
        if lower.hasPrefix("statediagram-v2") || lower.hasPrefix("statediagram") {
            return .graph(try parseStateDiagram(lines: lines))
        }
        if lower.hasPrefix("sequencediagram") {
            return .sequence(try parseSequenceDiagram(lines: lines))
        }
        if lower.hasPrefix("classdiagram") {
            return .graph(try parseClassDiagram(lines: lines))
        }
        if lower.hasPrefix("erdiagram") {
            return .graph(try parseERDiagram(lines: lines))
        }
        if lower.hasPrefix("pie") {
            return .pie(try parsePieChart(lines: lines))
        }

        throw MermaidError.unsupportedDiagramType(firstLine)
    }

    // MARK: - Preprocessing

    static func preprocessLines(_ source: String) -> [String] {
        var cleaned = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Strip %%{ ... }%% frontmatter / init directives (possibly multiline)
        while let start = cleaned.range(of: "%%{"),
              let end = cleaned.range(of: "}%%", range: start.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }

        var result: [String] = []
        for rawLine in cleaned.components(separatedBy: "\n") {
            let withoutComment = stripLineComment(rawLine)
            let parts = splitSemicolonsOutsideQuotesAndBrackets(withoutComment)
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
            }
        }
        return result
    }

    private static func stripLineComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var prevWasPercent = false
        var index = line.startIndex

        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                prevWasPercent = false
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
                prevWasPercent = false
            } else if !inDouble && !inSingle && ch == "%" {
                if prevWasPercent {
                    let cutIndex = line.index(before: index)
                    return String(line[..<cutIndex])
                }
                prevWasPercent = true
            } else {
                prevWasPercent = false
            }
            index = line.index(after: index)
        }
        return line
    }

    private static func splitSemicolonsOutsideQuotesAndBrackets(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inDouble = false
        var inSingle = false
        var bracketDepth = 0

        for ch in line {
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                current.append(ch)
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
                current.append(ch)
            } else if !inDouble && !inSingle {
                if ch == "[" || ch == "(" || ch == "{" {
                    bracketDepth += 1
                    current.append(ch)
                } else if (ch == "]" || ch == ")" || ch == "}") && bracketDepth > 0 {
                    bracketDepth -= 1
                    current.append(ch)
                } else if ch == ";" && bracketDepth == 0 {
                    parts.append(current)
                    current.removeAll(keepingCapacity: true)
                } else {
                    current.append(ch)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }

    static func cleanLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 && ((s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'"))) {
            s = String(s.dropFirst().dropLast())
        }
        // Handle Markdown string wrapper "`...`"
        if s.count >= 2 && s.hasPrefix("`") && s.hasSuffix("`") {
            s = String(s.dropFirst().dropLast())
        }
        let brReplacements = ["<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>", "\\n"]
        for br in brReplacements {
            s = s.replacingOccurrences(of: br, with: "\n")
        }
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "#quot;", with: "\"")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDirectionToken(_ token: String) -> MermaidDirection? {
        switch token.uppercased() {
        case "TD", "TB": return .topDown
        case "BT": return .bottomTop
        case "LR": return .leftRight
        case "RL": return .rightLeft
        default: return nil
        }
    }

    // MARK: - Flowchart Parser

    private static func parseFlowchart(lines: [String]) throws -> MermaidGraphAST {
        var direction: MermaidDirection = .topDown
        let headerTokens = lines[0].split(whereSeparator: { $0.isWhitespace })
        if headerTokens.count >= 2, let dir = parseDirectionToken(String(headerTokens[1])) {
            direction = dir
        }

        var nodeOrder: [String] = []
        var nodesByID: [String: MermaidNode] = [:]
        var edges: [MermaidEdge] = []
        var subgraphs: [MermaidSubgraph] = []
        var subgraphStack: [Int] = [] // indices into `subgraphs`
        var subgraphCounter = 0

        func registerNode(id: String, label: String?, shape: MermaidNodeShape?) {
            let currentSubgraphID = subgraphStack.last.map { subgraphs[$0].id }
            if var existing = nodesByID[id] {
                if let label, !label.isEmpty {
                    existing.label = label
                }
                if let shape, existing.shape == .rectangle || shape != .rectangle {
                    existing.shape = shape
                }
                if existing.subgraphID == nil, let currentSubgraphID {
                    existing.subgraphID = currentSubgraphID
                    if let stackIdx = subgraphStack.last, !subgraphs[stackIdx].nodeIDs.contains(id) {
                        subgraphs[stackIdx].nodeIDs.append(id)
                    }
                }
                nodesByID[id] = existing
            } else {
                let node = MermaidNode(
                    id: id,
                    label: (label?.isEmpty == false) ? label! : id,
                    shape: shape ?? .rectangle,
                    subgraphID: currentSubgraphID
                )
                nodesByID[id] = node
                nodeOrder.append(id)
                if let stackIdx = subgraphStack.last {
                    subgraphs[stackIdx].nodeIDs.append(id)
                }
            }
        }

        for line in lines.dropFirst() {
            let lower = line.lowercased()

            // Skip styling / metadata lines
            if lower.hasPrefix("classdef ") || lower.hasPrefix("class ") ||
                lower.hasPrefix("style ") || lower.hasPrefix("linkstyle ") ||
                lower.hasPrefix("click ") || lower.hasPrefix("acc") {
                continue
            }

            if lower.hasPrefix("direction "), let dirToken = line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first {
                if let dir = parseDirectionToken(String(dirToken)) {
                    if let sgIndex = subgraphStack.last {
                        subgraphs[sgIndex].direction = dir
                    } else {
                        direction = dir
                    }
                }
                continue
            }

            if lower == "subgraph" || lower.hasPrefix("subgraph ") {
                let rest = String(line.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
                let (sgID, sgTitle) = parseSubgraphHeader(rest, counter: &subgraphCounter)
                let parentID = subgraphStack.last.map { subgraphs[$0].id }
                subgraphs.append(MermaidSubgraph(id: sgID, title: sgTitle, parentID: parentID))
                subgraphStack.append(subgraphs.count - 1)
                continue
            }

            if lower == "end" {
                if !subgraphStack.isEmpty {
                    subgraphStack.removeLast()
                }
                continue
            }

            // Parse chain of nodes and edges: A[Start] & B -->|"Go"| C{Check} -- "No" --> A
            parseFlowchartStatement(line, registerNode: registerNode) { edge in
                edges.append(edge)
            }
        }

        let orderedNodes = nodeOrder.compactMap { nodesByID[$0] }
        if orderedNodes.isEmpty && subgraphs.isEmpty {
            throw MermaidError.noRenderableContent
        }

        return MermaidGraphAST(
            type: .flowchart,
            direction: direction,
            nodes: orderedNodes,
            edges: edges,
            subgraphs: subgraphs
        )
    }

    private static func parseSubgraphHeader(_ raw: String, counter: inout Int) -> (id: String, title: String) {
        if raw.isEmpty {
            counter += 1
            return ("sg_\(counter)", "Group \(counter)")
        }
        // Pattern: `id [Title]` or `id["Title"]`
        if let bracketStart = raw.firstIndex(of: "["),
           let bracketEnd = raw.lastIndex(of: "]"),
           bracketStart < bracketEnd {
            let idPart = raw[..<bracketStart].trimmingCharacters(in: .whitespaces)
            let titlePart = cleanLabel(String(raw[raw.index(after: bracketStart)..<bracketEnd]))
            let id = idPart.isEmpty ? "sg_\({ counter += 1; return counter }())" : idPart
            return (id, titlePart.isEmpty ? id : titlePart)
        }
        let cleaned = cleanLabel(raw)
        let id = cleaned.replacingOccurrences(of: " ", with: "_")
        return (id.isEmpty ? "sg_\({ counter += 1; return counter }())" : id, cleaned)
    }

    private static func parseFlowchartStatement(
        _ line: String,
        registerNode: (String, String?, MermaidNodeShape?) -> Void,
        addEdge: (MermaidEdge) -> Void
    ) {
        var cursor = line.startIndex
        let end = line.endIndex

        func skipWhitespace() {
            while cursor < end && line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
        }

        func parseNodeGroup() -> [String] {
            var ids: [String] = []
            while cursor < end {
                skipWhitespace()
                guard let parsed = consumeNodeSpec(in: line, from: &cursor) else {
                    break
                }
                registerNode(parsed.id, parsed.label, parsed.shape)
                ids.append(parsed.id)
                skipWhitespace()
                if cursor < end && line[cursor] == "&" {
                    cursor = line.index(after: cursor)
                    continue
                }
                break
            }
            return ids
        }

        var leftGroup = parseNodeGroup()
        guard !leftGroup.isEmpty else { return }

        while cursor < end {
            skipWhitespace()
            guard cursor < end else { break }

            guard let edgeSpec = consumeFlowchartEdge(in: line, from: &cursor) else {
                break
            }

            let rightGroup = parseNodeGroup()
            guard !rightGroup.isEmpty else { break }

            for src in leftGroup {
                for dst in rightGroup {
                    addEdge(MermaidEdge(
                        source: src,
                        target: dst,
                        label: edgeSpec.label,
                        lineStyle: edgeSpec.lineStyle,
                        sourceArrow: edgeSpec.sourceArrow,
                        targetArrow: edgeSpec.targetArrow
                    ))
                }
            }
            leftGroup = rightGroup
        }
    }

    private struct ParsedNodeSpec {
        let id: String
        let label: String?
        let shape: MermaidNodeShape?
    }

    private static func consumeNodeSpec(in line: String, from cursor: inout String.Index) -> ParsedNodeSpec? {
        let end = line.endIndex
        while cursor < end && line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        guard cursor < end else { return nil }

        // Read identifier until whitespace, `&`, shape opener, or edge starter
        let idStart = cursor
        while cursor < end {
            let ch = line[cursor]
            if ch.isWhitespace || ch == "&" || ch == "[" || ch == "(" || ch == "{" ||
                ch == "<" || ch == "|" {
                break
            }
            // Stop before edge operators (`--`, `-.`, `==`, `o--`, `x--`)
            if ch == "-" || ch == "=" {
                let rem = line[cursor...]
                if rem.hasPrefix("--") || rem.hasPrefix("-.") || rem.hasPrefix("==") {
                    break
                }
            }
            if (ch == "o" || ch == "x") && cursor == idStart {
                // Only treat as edge prefix if immediately followed by `--` or `-.`
                let next = line.index(after: cursor)
                if next < end && (line[next] == "-" || line[next] == "=") {
                    // Could be node id like `x` before `-->`? Wait: if `cursor == idStart`, it's node id only when followed by whitespace, not `o--`
                }
            }
            cursor = line.index(after: cursor)
        }

        // Strip trailing `:::className` if attached to id before shape
        var rawID = String(line[idStart..<cursor])
        if rawID.isEmpty { return nil }

        var classSuffixRange: String.Index?
        if let colons = rawID.range(of: ":::") {
            rawID = String(rawID[..<colons.lowerBound])
            classSuffixRange = idStart
            _ = classSuffixRange
        }

        var label: String?
        var shape: MermaidNodeShape?

        if cursor < end {
            let rem = line[cursor...]
            let shapeTokens: [(open: String, close: String, shape: MermaidNodeShape)] = [
                ("(((", ")))", .doubleCircle),
                ("([", "])", .stadium),
                ("[[", "]]", .subroutine),
                ("[(", ")]", .cylinder),
                ("((", "))", .circle),
                ("{{", "}}", .hexagon),
                ("[/", "/]", .parallelogram),
                ("[\\", "\\]", .parallelogramAlt),
                ("[/", "\\]", .trapezoid),
                ("[\\", "/]", .trapezoidAlt),
                ("[", "]", .rectangle),
                ("(", ")", .rounded),
                ("{", "}", .diamond)
            ]

            for token in shapeTokens {
                if rem.hasPrefix(token.open) {
                    let contentStart = line.index(cursor, offsetBy: token.open.count)
                    if let closeIdx = findClosingToken(token.close, in: line, from: contentStart) {
                        let rawLabel = String(line[contentStart..<closeIdx])
                        label = cleanLabel(rawLabel)
                        shape = token.shape
                        cursor = line.index(closeIdx, offsetBy: token.close.count)
                        break
                    }
                }
            }
        }

        // Consume optional :::className after shape
        if cursor < end && line[cursor...].hasPrefix(":::") {
            cursor = line.index(cursor, offsetBy: 3)
            while cursor < end && !line[cursor].isWhitespace && line[cursor] != "&" {
                cursor = line.index(after: cursor)
            }
        }

        return ParsedNodeSpec(id: rawID, label: label, shape: shape)
    }

    private static func findClosingToken(_ token: String, in line: String, from start: String.Index) -> String.Index? {
        var idx = start
        let end = line.endIndex
        var inDouble = false
        var inSingle = false

        while idx < end {
            let ch = line[idx]
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                idx = line.index(after: idx)
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                idx = line.index(after: idx)
                continue
            }
            if !inDouble && !inSingle && line[idx...].hasPrefix(token) {
                return idx
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private struct ParsedEdgeSpec {
        let label: String?
        let lineStyle: MermaidEdgeLineStyle
        let sourceArrow: MermaidArrowHead
        let targetArrow: MermaidArrowHead
    }

    private static func consumeFlowchartEdge(in line: String, from cursor: inout String.Index) -> ParsedEdgeSpec? {
        let start = cursor
        let end = line.endIndex
        let rem = line[cursor...]

        // 1. Check text-embedded label syntax:
        //    `-- "label" -->`, `-- label -->`, `-. label .->`, `== label ==>`, `-- label ---`, etc.
        if let embedded = matchTextEmbeddedEdge(in: line, from: cursor) {
            cursor = embedded.nextIndex
            return embedded.spec
        }

        // 2. Standard arrow operators
        var sourceArrow: MermaidArrowHead = .none
        if rem.hasPrefix("<") {
            sourceArrow = .normal
            cursor = line.index(after: cursor)
        } else if rem.hasPrefix("o") && (rem.dropFirst().hasPrefix("--") || rem.dropFirst().hasPrefix("-.")) {
            sourceArrow = .circle
            cursor = line.index(after: cursor)
        } else if rem.hasPrefix("x") && (rem.dropFirst().hasPrefix("--") || rem.dropFirst().hasPrefix("-.")) {
            sourceArrow = .cross
            cursor = line.index(after: cursor)
        }

        guard cursor < end else {
            cursor = start
            return nil
        }

        let opSlice = line[cursor...]
        var lineStyle: MermaidEdgeLineStyle = .solid
        var targetArrow: MermaidArrowHead = .none
        var matchedOpLen = 0

        // Dotted forms: `-.-...->`, `-.->`, `-.-`
        if opSlice.hasPrefix("-.") {
            lineStyle = .dotted
            var idx = line.index(cursor, offsetBy: 2)
            while idx < end && (line[idx] == "-" || line[idx] == ".") {
                idx = line.index(after: idx)
            }
            if idx < end && line[idx] == ">" {
                targetArrow = .normal
                idx = line.index(after: idx)
            } else if idx < end && line[idx] == "o" {
                targetArrow = .circle
                idx = line.index(after: idx)
            } else if idx < end && line[idx] == "x" {
                targetArrow = .cross
                idx = line.index(after: idx)
            }
            matchedOpLen = line.distance(from: cursor, to: idx)
        } else if opSlice.hasPrefix("==") {
            lineStyle = .thick
            var idx = line.index(cursor, offsetBy: 2)
            while idx < end && line[idx] == "=" {
                idx = line.index(after: idx)
            }
            if idx < end && line[idx] == ">" {
                targetArrow = .normal
                idx = line.index(after: idx)
            }
            matchedOpLen = line.distance(from: cursor, to: idx)
        } else if opSlice.hasPrefix("--") {
            lineStyle = .solid
            var idx = line.index(cursor, offsetBy: 2)
            while idx < end && line[idx] == "-" {
                idx = line.index(after: idx)
            }
            if idx < end && line[idx] == ">" {
                targetArrow = .normal
                idx = line.index(after: idx)
            } else if idx < end && line[idx] == "o" {
                targetArrow = .circle
                idx = line.index(after: idx)
            } else if idx < end && line[idx] == "x" {
                targetArrow = .cross
                idx = line.index(after: idx)
            }
            matchedOpLen = line.distance(from: cursor, to: idx)
        }

        guard matchedOpLen >= 2 else {
            cursor = start
            return nil
        }

        cursor = line.index(cursor, offsetBy: matchedOpLen)

        // Optional pipe label `|text|`
        while cursor < end && line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        var label: String?
        if cursor < end && line[cursor] == "|" {
            let lStart = line.index(after: cursor)
            if let lEnd = line[lStart...].firstIndex(of: "|") {
                let raw = String(line[lStart..<lEnd])
                let cleaned = cleanLabel(raw)
                if !cleaned.isEmpty {
                    label = cleaned
                }
                cursor = line.index(after: lEnd)
            }
        }

        return ParsedEdgeSpec(
            label: label,
            lineStyle: lineStyle,
            sourceArrow: sourceArrow,
            targetArrow: targetArrow
        )
    }

    private static func matchTextEmbeddedEdge(
        in line: String,
        from cursor: String.Index
    ) -> (spec: ParsedEdgeSpec, nextIndex: String.Index)? {
        let sub = String(line[cursor...])
        // Match: optional `<`, opener (`--`, `-.`, `==`), spaces, label, spaces, closer (`-->`, `---`, `.->`, `-.-`, `==>`, `===`)
        let pattern = #"^(<)?(--|-\.|==)\s+(.+?)\s+(--+|-\.-|==+)(>)?(?=\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) else {
            return nil
        }
        let ns = sub as NSString
        let hasBack = match.range(at: 1).location != NSNotFound
        let opener = ns.substring(with: match.range(at: 2))
        let rawLabel = ns.substring(with: match.range(at: 3))
        let hasForward = match.range(at: 5).location != NSNotFound

        let lineStyle: MermaidEdgeLineStyle
        if opener == "-." {
            lineStyle = .dotted
        } else if opener == "==" {
            lineStyle = .thick
        } else {
            lineStyle = .solid
        }

        let cleaned = cleanLabel(rawLabel)
        let matchLen = match.range.length
        let utf16End = sub.utf16.index(sub.utf16.startIndex, offsetBy: matchLen)
        let advanceCount = sub.distance(from: sub.startIndex, to: utf16End)
        let nextIdx = line.index(cursor, offsetBy: advanceCount)

        return (
            ParsedEdgeSpec(
                label: cleaned.isEmpty ? nil : cleaned,
                lineStyle: lineStyle,
                sourceArrow: hasBack ? .normal : .none,
                targetArrow: hasForward ? .normal : .none
            ),
            nextIdx
        )
    }

    // MARK: - State Diagram Parser

    private static func parseStateDiagram(lines: [String]) throws -> MermaidGraphAST {
        var direction: MermaidDirection = .topDown
        var nodeOrder: [String] = []
        var nodesByID: [String: MermaidNode] = [:]
        var edges: [MermaidEdge] = []
        var subgraphs: [MermaidSubgraph] = []
        var subgraphStack: [Int] = []
        var startCounter = 0
        var endCounter = 0

        func registerState(id: String, label: String? = nil, shape: MermaidNodeShape = .rounded) {
            let sgID = subgraphStack.last.map { subgraphs[$0].id }
            if var existing = nodesByID[id] {
                if let label, !label.isEmpty {
                    existing.label = label
                }
                if existing.subgraphID == nil, let sgID {
                    existing.subgraphID = sgID
                    if let idx = subgraphStack.last, !subgraphs[idx].nodeIDs.contains(id) {
                        subgraphs[idx].nodeIDs.append(id)
                    }
                }
                nodesByID[id] = existing
            } else {
                nodesByID[id] = MermaidNode(
                    id: id,
                    label: (label?.isEmpty == false) ? label! : id,
                    shape: shape,
                    subgraphID: sgID
                )
                nodeOrder.append(id)
                if let idx = subgraphStack.last {
                    subgraphs[idx].nodeIDs.append(id)
                }
            }
        }

        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("classdef ") || lower.hasPrefix("class ") ||
                lower.hasPrefix("style ") || lower.hasPrefix("note ") || lower == "end note" {
                continue
            }

            if lower.hasPrefix("direction "), let token = line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first {
                if let dir = parseDirectionToken(String(token)) {
                    direction = dir
                }
                continue
            }

            // Composite state: `state "Name" as id {` or `state id {`
            if lower.hasPrefix("state ") && line.hasSuffix("{") {
                let inner = String(line.dropFirst(6).dropLast()).trimmingCharacters(in: .whitespaces)
                let (sgID, sgTitle) = parseStateAlias(inner)
                let parentID = subgraphStack.last.map { subgraphs[$0].id }
                subgraphs.append(MermaidSubgraph(id: sgID, title: sgTitle, parentID: parentID))
                subgraphStack.append(subgraphs.count - 1)
                continue
            }

            if line == "}" {
                if !subgraphStack.isEmpty {
                    subgraphStack.removeLast()
                }
                continue
            }

            // `state "Description" as s1`
            if lower.hasPrefix("state ") {
                let rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let (id, title) = parseStateAlias(rest)
                registerState(id: id, label: title)
                continue
            }

            // Transition: `A --> B : label` or `[*] --> A`
            if let arrowRange = line.range(of: "-->") {
                let leftRaw = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let afterArrow = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                let rightRaw: String
                let label: String?
                if let colonIdx = afterArrow.firstIndex(of: ":") {
                    rightRaw = String(afterArrow[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let lbl = cleanLabel(String(afterArrow[afterArrow.index(after: colonIdx)...]))
                    label = lbl.isEmpty ? nil : lbl
                } else {
                    rightRaw = afterArrow
                    label = nil
                }

                let srcID: String
                if leftRaw == "[*]" {
                    startCounter += 1
                    srcID = "__state_start_\(startCounter)"
                    registerState(id: srcID, label: "", shape: .stateStart)
                } else {
                    srcID = leftRaw
                    registerState(id: srcID)
                }

                let dstID: String
                if rightRaw == "[*]" {
                    endCounter += 1
                    dstID = "__state_end_\(endCounter)"
                    registerState(id: dstID, label: "", shape: .stateEnd)
                } else {
                    dstID = rightRaw
                    registerState(id: dstID)
                }

                edges.append(MermaidEdge(
                    source: srcID,
                    target: dstID,
                    label: label,
                    lineStyle: .solid,
                    sourceArrow: .none,
                    targetArrow: .normal
                ))
                continue
            }

            // State description: `State : description`
            if let colonIdx = line.firstIndex(of: ":") {
                let id = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let desc = cleanLabel(String(line[line.index(after: colonIdx)...]))
                if !id.isEmpty && !desc.isEmpty {
                    registerState(id: id, label: "\(id)\n\(desc)")
                }
            }
        }

        let orderedNodes = nodeOrder.compactMap { nodesByID[$0] }
        if orderedNodes.isEmpty && subgraphs.isEmpty {
            throw MermaidError.noRenderableContent
        }

        return MermaidGraphAST(
            type: .state,
            direction: direction,
            nodes: orderedNodes,
            edges: edges,
            subgraphs: subgraphs
        )
    }

    private static func parseStateAlias(_ raw: String) -> (id: String, title: String) {
        if let asRange = raw.range(of: " as ", options: .caseInsensitive) {
            let title = cleanLabel(String(raw[..<asRange.lowerBound]))
            let id = String(raw[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (id.isEmpty ? title : id, title.isEmpty ? id : title)
        }
        let cleaned = cleanLabel(raw)
        return (cleaned, cleaned)
    }
}
