import Foundation

extension MermaidParser {
    // MARK: - Sequence Diagram Parser

    static func parseSequenceDiagram(lines: [String]) throws -> MermaidSequenceAST {
        var participantsOrder: [String] = []
        var participantsByID: [String: MermaidSequenceParticipant] = [:]
        var items: [MermaidSequenceItem] = []
        var autonumber = false
        var messageNumber = 0

        func ensureParticipant(_ id: String, label: String? = nil, kind: MermaidParticipantKind? = nil) {
            let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty else { return }
            if var existing = participantsByID[trimmedID] {
                if let label, !label.isEmpty {
                    existing.label = label
                }
                if let kind {
                    existing.kind = kind
                }
                participantsByID[trimmedID] = existing
            } else {
                participantsByID[trimmedID] = MermaidSequenceParticipant(
                    id: trimmedID,
                    label: (label?.isEmpty == false) ? label! : trimmedID,
                    kind: kind ?? .participant
                )
                participantsOrder.append(trimmedID)
            }
        }

        for line in lines.dropFirst() {
            let lower = line.lowercased()

            if lower == "autonumber" {
                autonumber = true
                continue
            }

            if lower.hasPrefix("title ") || lower.hasPrefix("acc") ||
                lower.hasPrefix("box ") || lower == "end" && false {
                continue
            }

            // `participant A as Alice` or `actor U as User`
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let kind: MermaidParticipantKind = lower.hasPrefix("actor ") ? .actor : .participant
                let prefixLen = kind == .actor ? "actor ".count : "participant ".count
                let rest = String(line.dropFirst(prefixLen)).trimmingCharacters(in: .whitespaces)
                if let asRange = rest.range(of: " as ", options: .caseInsensitive) {
                    let id = String(rest[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let label = cleanLabel(String(rest[asRange.upperBound...]))
                    ensureParticipant(id, label: label, kind: kind)
                } else {
                    let id = cleanLabel(rest)
                    ensureParticipant(id, label: id, kind: kind)
                }
                continue
            }

            // `activate X` / `deactivate X`
            if lower.hasPrefix("activate ") {
                let id = String(line.dropFirst("activate ".count)).trimmingCharacters(in: .whitespaces)
                ensureParticipant(id)
                items.append(.activate(id))
                continue
            }
            if lower.hasPrefix("deactivate ") {
                let id = String(line.dropFirst("deactivate ".count)).trimmingCharacters(in: .whitespaces)
                ensureParticipant(id)
                items.append(.deactivate(id))
                continue
            }

            // `Note left of A: text` / `Note right of A: text` / `Note over A,B: text`
            if lower.hasPrefix("note ") {
                if let note = parseSequenceNote(line) {
                    for p in note.participants {
                        ensureParticipant(p)
                    }
                    items.append(.note(note))
                }
                continue
            }

            // Control blocks: loop / alt / opt / par / critical / break / rect
            let blockPrefixes: [(prefix: String, kind: MermaidSequenceBlockKind)] = [
                ("loop ", .loop), ("loop", .loop),
                ("alt ", .alt), ("alt", .alt),
                ("opt ", .opt), ("opt", .opt),
                ("par ", .par), ("par", .par),
                ("critical ", .critical), ("critical", .critical),
                ("break ", .break), ("break", .break),
                ("rect ", .rect)
            ]
            var matchedBlock = false
            for (prefix, kind) in blockPrefixes {
                if lower == prefix || lower.hasPrefix(prefix) {
                    let label = String(line.dropFirst(min(line.count, kind.rawValue.count)))
                        .trimmingCharacters(in: .whitespaces)
                    items.append(.blockStart(kind: kind, label: cleanLabel(label)))
                    matchedBlock = true
                    break
                }
            }
            if matchedBlock { continue }

            if lower == "else" || lower.hasPrefix("else ") {
                let label = String(line.dropFirst(min(line.count, 4))).trimmingCharacters(in: .whitespaces)
                items.append(.blockDivider(label: cleanLabel(label)))
                continue
            }
            if lower == "and" || lower.hasPrefix("and ") {
                let label = String(line.dropFirst(min(line.count, 3))).trimmingCharacters(in: .whitespaces)
                items.append(.blockDivider(label: cleanLabel(label)))
                continue
            }
            if lower == "option" || lower.hasPrefix("option ") {
                let label = String(line.dropFirst(min(line.count, 6))).trimmingCharacters(in: .whitespaces)
                items.append(.blockDivider(label: cleanLabel(label)))
                continue
            }
            if lower == "end" {
                items.append(.blockEnd)
                continue
            }

            // Message: `A->>+B: text` or `A-->>-B: text` or `A->B: text`
            if let msg = parseSequenceMessage(line) {
                ensureParticipant(msg.from)
                ensureParticipant(msg.to)
                messageNumber += 1
                let finalText = autonumber && !msg.text.isEmpty
                    ? "\(messageNumber). \(msg.text)"
                    : (autonumber ? "\(messageNumber)" : msg.text)
                let numbered = MermaidSequenceMessage(
                    from: msg.from,
                    to: msg.to,
                    text: finalText,
                    lineStyle: msg.lineStyle,
                    arrowHead: msg.arrowHead,
                    activateTarget: msg.activateTarget,
                    deactivateTarget: msg.deactivateTarget
                )
                items.append(.message(numbered))
            }
        }

        let participants = participantsOrder.compactMap { participantsByID[$0] }
        if participants.isEmpty {
            throw MermaidError.noRenderableContent
        }
        return MermaidSequenceAST(participants: participants, items: items, autonumber: autonumber)
    }

    private static func parseSequenceNote(_ line: String) -> MermaidSequenceNote? {
        let pattern = #"^note\s+(left of|right of|over)\s+([^:]+):\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let ns = line as NSString
        let posRaw = ns.substring(with: match.range(at: 1)).lowercased()
        let targetsRaw = ns.substring(with: match.range(at: 2))
        let textRaw = ns.substring(with: match.range(at: 3))

        let pos: MermaidSequenceNotePosition
        switch posRaw {
        case "left of": pos = .leftOf
        case "right of": pos = .rightOf
        default: pos = .over
        }

        let targets = targetsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targets.isEmpty else { return nil }

        return MermaidSequenceNote(position: pos, participants: targets, text: cleanLabel(textRaw))
    }

    private static func parseSequenceMessage(_ line: String) -> MermaidSequenceMessage? {
        let pattern = #"^(.+?)\s*(-->>|->>|-->|->|--x|-x|--\)|-\))\s*([+-])?\s*([^:]+?)(?:\s*:\s*(.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let ns = line as NSString
        let from = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let arrowOp = ns.substring(with: match.range(at: 2))
        let mod = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
        let to = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
        let text = match.range(at: 5).location != NSNotFound ? cleanLabel(ns.substring(with: match.range(at: 5))) : ""

        let lineStyle: MermaidEdgeLineStyle = arrowOp.hasPrefix("--") ? .dotted : .solid
        let arrowHead: MermaidArrowHead
        if arrowOp.hasSuffix("x") {
            arrowHead = .cross
        } else if arrowOp.hasSuffix("))") || arrowOp.hasSuffix(")") || arrowOp.hasSuffix("->") && !arrowOp.hasSuffix("->>") {
            arrowHead = .open
        } else {
            arrowHead = .normal
        }

        return MermaidSequenceMessage(
            from: from,
            to: to,
            text: text,
            lineStyle: lineStyle,
            arrowHead: arrowHead,
            activateTarget: mod == "+",
            deactivateTarget: mod == "-"
        )
    }

    // MARK: - Class Diagram Parser

    static func parseClassDiagram(lines: [String]) throws -> MermaidGraphAST {
        var direction: MermaidDirection = .topDown
        var nodeOrder: [String] = []
        var nodesByID: [String: MermaidNode] = [:]
        var edges: [MermaidEdge] = []
        var currentClassID: String?

        func ensureClass(_ id: String, label: String? = nil) {
            let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty else { return }
            if var existing = nodesByID[cleanID] {
                if let label, !label.isEmpty {
                    existing.label = label
                }
                nodesByID[cleanID] = existing
            } else {
                nodesByID[cleanID] = MermaidNode(
                    id: cleanID,
                    label: (label?.isEmpty == false) ? label! : cleanID,
                    shape: .classBox
                )
                nodeOrder.append(cleanID)
            }
        }

        func appendMember(_ rawMember: String, to classID: String) {
            let member = rawMember.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !member.isEmpty else { return }
            ensureClass(classID)
            guard var node = nodesByID[classID] else { return }
            if member.hasPrefix("<<") && member.hasSuffix(">>") {
                // Stereotype header prefix
                node.label = "\(member)\n\(node.label)"
            } else if member.contains("(") {
                node.secondaryLines.append(member)
            } else {
                node.subtitleLines.append(member)
            }
            nodesByID[classID] = node
        }

        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("direction "), let token = line.split(whereSeparator: { $0.isWhitespace }).dropFirst().first {
                if let dir = parseDirectionToken(String(token)) {
                    direction = dir
                }
                continue
            }
            if lower.hasPrefix("note ") || lower.hasPrefix("namespace ") || lower.hasPrefix("style ") || lower.hasPrefix("classdef ") {
                continue
            }

            if let activeID = currentClassID {
                if line == "}" {
                    currentClassID = nil
                    continue
                }
                appendMember(line, to: activeID)
                continue
            }

            // `class User {` or `class User["Display"] {` or `class User`
            if lower.hasPrefix("class ") {
                var rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                let opensBlock = rest.hasSuffix("{")
                if opensBlock {
                    rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                }
                let classID: String
                var displayName: String?
                if let bStart = rest.firstIndex(of: "["), let bEnd = rest.lastIndex(of: "]"), bStart < bEnd {
                    classID = String(rest[..<bStart]).trimmingCharacters(in: .whitespaces)
                    displayName = cleanLabel(String(rest[rest.index(after: bStart)..<bEnd]))
                } else {
                    classID = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? rest
                }
                ensureClass(classID, label: displayName)
                if opensBlock {
                    currentClassID = classID
                }
                continue
            }

            // Member line outside braces: `User : +String name`
            if let edge = parseClassRelation(line) {
                ensureClass(edge.source)
                ensureClass(edge.target)
                edges.append(edge)
                continue
            }

            if let colonIdx = line.firstIndex(of: ":") {
                let classID = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let member = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !classID.isEmpty && !member.isEmpty && !classID.contains(" ") {
                    appendMember(member, to: classID)
                }
            }
        }

        let orderedNodes = nodeOrder.compactMap { nodesByID[$0] }
        if orderedNodes.isEmpty {
            throw MermaidError.noRenderableContent
        }
        return MermaidGraphAST(type: .classDiagram, direction: direction, nodes: orderedNodes, edges: edges)
    }

    private static func parseClassRelation(_ line: String) -> MermaidEdge? {
        let pattern = #"^([A-Za-z0-9_~<>]+)\s*(?:\"([^\"]*)\")?\s*(<\|--|--\|>|\*--|--\*|o--|--o|<--|\.\.>|<\.\.|--\.\.|\.\.--|-->|--|\.\.)\s*(?:\"([^\"]*)\")?\s*([A-Za-z0-9_~<>]+)(?:\s*:\s*(.+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let ns = line as NSString
        let src = ns.substring(with: match.range(at: 1))
        let srcLabel = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
        let op = ns.substring(with: match.range(at: 3))
        let dstLabel = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : nil
        let dst = ns.substring(with: match.range(at: 5))
        let label = match.range(at: 6).location != NSNotFound ? cleanLabel(ns.substring(with: match.range(at: 6))) : nil

        let lineStyle: MermaidEdgeLineStyle = op.contains("..") ? .dotted : .solid
        var sourceArrow: MermaidArrowHead = .none
        var targetArrow: MermaidArrowHead = .none

        if op.hasPrefix("<|") { sourceArrow = .inheritance }
        else if op.hasPrefix("*") { sourceArrow = .composition }
        else if op.hasPrefix("o") { sourceArrow = .aggregation }
        else if op.hasPrefix("<") { sourceArrow = .normal }

        if op.hasSuffix("|>") { targetArrow = .inheritance }
        else if op.hasSuffix("*") { targetArrow = .composition }
        else if op.hasSuffix("o") { targetArrow = .aggregation }
        else if op.hasSuffix(">") { targetArrow = .normal }

        return MermaidEdge(
            source: src,
            target: dst,
            label: (label?.isEmpty == false) ? label : nil,
            lineStyle: lineStyle,
            sourceArrow: sourceArrow,
            targetArrow: targetArrow,
            sourceLabel: srcLabel,
            targetLabel: dstLabel
        )
    }

    // MARK: - ER Diagram Parser

    static func parseERDiagram(lines: [String]) throws -> MermaidGraphAST {
        var nodeOrder: [String] = []
        var nodesByID: [String: MermaidNode] = [:]
        var edges: [MermaidEdge] = []
        var currentEntityID: String?

        func ensureEntity(_ id: String) {
            let cleanID = cleanLabel(id)
            guard !cleanID.isEmpty else { return }
            if nodesByID[cleanID] == nil {
                nodesByID[cleanID] = MermaidNode(id: cleanID, label: cleanID, shape: .entityBox)
                nodeOrder.append(cleanID)
            }
        }

        for line in lines.dropFirst() {
            if let activeID = currentEntityID {
                if line == "}" {
                    currentEntityID = nil
                    continue
                }
                ensureEntity(activeID)
                if var node = nodesByID[activeID] {
                    // e.g. `int id PK "comment"` -> clean readable row `PK  id : int`
                    let attrText = formatERAttribute(line)
                    if !attrText.isEmpty {
                        node.subtitleLines.append(attrText)
                        nodesByID[activeID] = node
                    }
                }
                continue
            }

            if line.hasSuffix("{") {
                let entityID = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                ensureEntity(entityID)
                currentEntityID = cleanLabel(entityID)
                continue
            }

            if let edge = parseERRelation(line) {
                ensureEntity(edge.source)
                ensureEntity(edge.target)
                edges.append(edge)
            }
        }

        let orderedNodes = nodeOrder.compactMap { nodesByID[$0] }
        if orderedNodes.isEmpty {
            throw MermaidError.noRenderableContent
        }
        return MermaidGraphAST(type: .erDiagram, direction: .topDown, nodes: orderedNodes, edges: edges)
    }

    private static func formatERAttribute(_ raw: String) -> String {
        // Strip quoted comment at end if present
        var line = raw.trimmingCharacters(in: .whitespaces)
        if let qStart = line.firstIndex(of: "\"") {
            line = String(line[..<qStart]).trimmingCharacters(in: .whitespaces)
        }
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2 else { return line }
        let typeName = tokens[0]
        let fieldName = tokens[1]
        let keys = tokens.dropFirst(2).joined(separator: ",")
        return keys.isEmpty ? "\(fieldName): \(typeName)" : "[\(keys)] \(fieldName): \(typeName)"
    }

    private static func parseERRelation(_ line: String) -> MermaidEdge? {
        let pattern = #"^([^\s]+)\s+([|o}][|o])(--|\.\.)([|o{][|o])\s+([^\s:]+)(?:\s*:\s*(.+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return nil
        }
        let ns = line as NSString
        let src = cleanLabel(ns.substring(with: match.range(at: 1)))
        let leftCard = ns.substring(with: match.range(at: 2))
        let mid = ns.substring(with: match.range(at: 3))
        let rightCard = ns.substring(with: match.range(at: 4))
        let dst = cleanLabel(ns.substring(with: match.range(at: 5)))
        let label = match.range(at: 6).location != NSNotFound ? cleanLabel(ns.substring(with: match.range(at: 6))) : nil

        return MermaidEdge(
            source: src,
            target: dst,
            label: (label?.isEmpty == false) ? label : nil,
            lineStyle: mid == ".." ? .dotted : .solid,
            sourceArrow: mapERCardinality(leftCard),
            targetArrow: mapERCardinality(rightCard)
        )
    }

    private static func mapERCardinality(_ token: String) -> MermaidArrowHead {
        if token.contains("{") || token.contains("}") {
            return token.contains("o") ? .erZeroOrMore : .erOneOrMore
        }
        if token.contains("o") {
            return .erZeroOrOne
        }
        return .erOnlyOne
    }

    // MARK: - Pie Chart Parser

    static func parsePieChart(lines: [String]) throws -> MermaidPieAST {
        var showData = lines[0].lowercased().contains("showdata")
        var title: String?
        if let titleRange = lines[0].range(of: "title ", options: .caseInsensitive) {
            let t = cleanLabel(String(lines[0][titleRange.upperBound...]))
            if !t.isEmpty { title = t }
        }

        var slices: [MermaidPieSlice] = []
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower == "showdata" {
                showData = true
                continue
            }
            if lower.hasPrefix("title ") {
                let t = cleanLabel(String(line.dropFirst(6)))
                if !t.isEmpty { title = t }
                continue
            }
            // `"Label" : 42.5`
            if let colonIdx = line.lastIndex(of: ":") {
                let label = cleanLabel(String(line[..<colonIdx]))
                let valStr = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, let value = Double(valStr), value > 0 {
                    slices.append(MermaidPieSlice(label: label, value: value))
                }
            }
        }

        if slices.isEmpty {
            throw MermaidError.noRenderableContent
        }
        return MermaidPieAST(title: title, showData: showData, slices: slices)
    }
}
