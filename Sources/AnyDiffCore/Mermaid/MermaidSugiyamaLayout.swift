import Foundation
import CoreGraphics

enum MermaidSugiyamaLayout {
    struct Config {
        var nodeSpacing: CGFloat = 34
        var layerSpacing: CGFloat = 54
        var margin: CGFloat = 24
        var maxNodeTextWidth: CGFloat = 240
        var maxEdgeLabelWidth: CGFloat = 170
        var backEdgeLaneStep: CGFloat = 46
    }

    private struct LayoutItem {
        let id: String
        let isDummy: Bool
        let astIndex: Int?
        var size: CGSize
        var wrappedLines: [String]
        var subtitleLines: [String]
        var secondaryLines: [String]
        var shape: MermaidNodeShape
        var subgraphID: String?
        var rank: Int = 0
        var orderInRank: Int = 0
        var center: CGPoint = .zero
    }

    private struct WorkingEdge {
        let astIndex: Int
        let sourceItem: Int
        let targetItem: Int
        let originalSource: Int
        let originalTarget: Int
        let isBackEdge: Bool
        let isSelfLoop: Bool
        var waypointItems: [Int] = []
        var labelLines: [String] = []
        var labelSize: CGSize = .zero
    }

    static func layout(
        _ ast: MermaidGraphAST,
        measurer: MermaidTextMeasurer,
        maxWidth: CGFloat
    ) -> MermaidPositionedGraph {
        var config = Config()
        if maxWidth > 0 && maxWidth < 460 {
            config.maxNodeTextWidth = max(140, maxWidth * 0.48)
        }

        let isHorizontal = ast.direction.isHorizontal

        // 1. Measure all AST nodes
        var items: [LayoutItem] = []
        var idToItemIndex: [String: Int] = [:]

        for (idx, node) in ast.nodes.enumerated() {
            let measured = measureNode(node, measurer: measurer, maxTextWidth: config.maxNodeTextWidth)
            let item = LayoutItem(
                id: node.id,
                isDummy: false,
                astIndex: idx,
                size: measured.size,
                wrappedLines: measured.wrappedLines,
                subtitleLines: node.subtitleLines,
                secondaryLines: node.secondaryLines,
                shape: node.shape,
                subgraphID: node.subgraphID
            )
            idToItemIndex[node.id] = items.count
            items.append(item)
        }

        // Measure edge labels
        var rawEdges: [(astIndex: Int, src: Int, dst: Int, labelLines: [String], labelSize: CGSize)] = []
        var maxEdgeLabelPrimarySpan: CGFloat = 0

        for (idx, edge) in ast.edges.enumerated() {
            guard let s = idToItemIndex[edge.source], let t = idToItemIndex[edge.target] else { continue }
            var labelLines: [String] = []
            var labelSize: CGSize = .zero
            if let label = edge.label, !label.isEmpty {
                let wrapped = measurer.wrapText(label, role: .edgeLabel, maxWidth: config.maxEdgeLabelWidth)
                labelLines = wrapped.lines
                labelSize = CGSize(width: wrapped.size.width + 14, height: wrapped.size.height + 8)
                let primarySpan = isHorizontal ? labelSize.width : labelSize.height
                maxEdgeLabelPrimarySpan = max(maxEdgeLabelPrimarySpan, primarySpan)
            }
            rawEdges.append((idx, s, t, labelLines, labelSize))
        }

        if maxEdgeLabelPrimarySpan > 0 {
            config.layerSpacing = max(config.layerSpacing, maxEdgeLabelPrimarySpan + 26)
        }

        // 2. Cycle removal via DFS
        let backEdgeFlags = detectBackEdges(nodeCount: items.count, edges: rawEdges.map { ($0.src, $0.dst) })

        var workingEdges: [WorkingEdge] = []
        var forwardAdjacency = Array(repeating: [Int](), count: items.count)
        var inDegree = Array(repeating: 0, count: items.count)

        for (edgeIdx, raw) in rawEdges.enumerated() {
            let isSelfLoop = raw.src == raw.dst
            let isBack = backEdgeFlags[edgeIdx] && !isSelfLoop
            let workingSrc = isBack ? raw.dst : raw.src
            let workingDst = isBack ? raw.src : raw.dst

            let we = WorkingEdge(
                astIndex: raw.astIndex,
                sourceItem: workingSrc,
                targetItem: workingDst,
                originalSource: raw.src,
                originalTarget: raw.dst,
                isBackEdge: isBack,
                isSelfLoop: isSelfLoop,
                labelLines: raw.labelLines,
                labelSize: raw.labelSize
            )
            workingEdges.append(we)

            if !isSelfLoop && !isBack {
                forwardAdjacency[workingSrc].append(workingDst)
                inDegree[workingDst] += 1
            } else if isBack {
                // Reversed edge still helps ensure sourceItem (originally target) sits earlier than targetItem
                forwardAdjacency[workingSrc].append(workingDst)
                inDegree[workingDst] += 1
            }
            _ = we
        }

        // 3. Longest-path rank assignment on DAG
        assignRanks(itemCount: items.count, adjacency: forwardAdjacency, inDegree: inDegree, items: &items)

        // 4. Insert dummy nodes for forward edges spanning > 1 rank
        var dummyCounter = 0
        for eIdx in workingEdges.indices {
            if workingEdges[eIdx].isSelfLoop || workingEdges[eIdx].isBackEdge {
                continue
            }
            let rSrc = items[workingEdges[eIdx].sourceItem].rank
            let rDst = items[workingEdges[eIdx].targetItem].rank
            if rDst - rSrc > 1 {
                var waypoints: [Int] = []
                for r in (rSrc + 1)..<rDst {
                    dummyCounter += 1
                    let dummyID = "__dummy_\(dummyCounter)"
                    let dummySize = CGSize(width: 10, height: 10)
                    var dummy = LayoutItem(
                        id: dummyID,
                        isDummy: true,
                        astIndex: nil,
                        size: dummySize,
                        wrappedLines: [],
                        subtitleLines: [],
                        secondaryLines: [],
                        shape: .rectangle,
                        subgraphID: nil
                    )
                    dummy.rank = r
                    let dummyIdx = items.count
                    items.append(dummy)
                    waypoints.append(dummyIdx)
                }
                workingEdges[eIdx].waypointItems = waypoints
            }
        }

        // 5. Group by rank & minimize crossings (barycenter)
        let maxRank = items.map(\.rank).max() ?? 0
        var ranks: [[Int]] = Array(repeating: [], count: maxRank + 1)
        for idx in items.indices {
            ranks[items[idx].rank].append(idx)
        }

        // Build adjacency across consecutive ranks (including dummy chains) for crossing minimization
        var prevNeighbors = Array(repeating: [Int](), count: items.count)
        var nextNeighbors = Array(repeating: [Int](), count: items.count)
        for we in workingEdges where !we.isSelfLoop && !we.isBackEdge {
            var chain = [we.sourceItem]
            chain.append(contentsOf: we.waypointItems)
            chain.append(we.targetItem)
            for i in 0..<(chain.count - 1) {
                let u = chain[i]
                let v = chain[i + 1]
                nextNeighbors[u].append(v)
                prevNeighbors[v].append(u)
            }
        }

        for r in ranks.indices {
            for (pos, idx) in ranks[r].enumerated() {
                items[idx].orderInRank = pos
            }
        }

        // 4 sweeps of barycenter ordering
        for _ in 0..<4 {
            // Top-down sweep
            for r in 1..<ranks.count {
                ranks[r].sort { a, b in
                    let ba = barycenter(of: prevNeighbors[a], items: items, fallback: Double(items[a].orderInRank))
                    let bb = barycenter(of: prevNeighbors[b], items: items, fallback: Double(items[b].orderInRank))
                    if abs(ba - bb) > 0.001 { return ba < bb }
                    return items[a].orderInRank < items[b].orderInRank
                }
                for (pos, idx) in ranks[r].enumerated() {
                    items[idx].orderInRank = pos
                }
            }
            // Bottom-up sweep
            if ranks.count >= 2 {
                for r in stride(from: ranks.count - 2, through: 0, by: -1) {
                    ranks[r].sort { a, b in
                        let ba = barycenter(of: nextNeighbors[a], items: items, fallback: Double(items[a].orderInRank))
                        let bb = barycenter(of: nextNeighbors[b], items: items, fallback: Double(items[b].orderInRank))
                        if abs(ba - bb) > 0.001 { return ba < bb }
                        return items[a].orderInRank < items[b].orderInRank
                    }
                    for (pos, idx) in ranks[r].enumerated() {
                        items[idx].orderInRank = pos
                    }
                }
            }
        }

        // 6. Coordinate assignment
        assignCoordinates(
            ranks: ranks,
            items: &items,
            prevNeighbors: prevNeighbors,
            nextNeighbors: nextNeighbors,
            isHorizontal: isHorizontal,
            config: config
        )

        // Mirror if BT or RL
        if ast.direction.isReversed {
            let maxPrimary = items.map { item in
                isHorizontal ? (item.center.x + item.size.width / 2) : (item.center.y + item.size.height / 2)
            }.max() ?? 0
            for idx in items.indices {
                if isHorizontal {
                    items[idx].center.x = maxPrimary - items[idx].center.x
                } else {
                    items[idx].center.y = maxPrimary - items[idx].center.y
                }
            }
        }

        // 7. Compute subgraph bounding boxes (bottom-up) and add header spacing
        let groups = computeSubgraphGroups(ast: ast, items: items, idToItemIndex: idToItemIndex)

        // 8. Route edges (forward chains + side-lane back-edges + self-loops)
        let positionedEdges = routeAllEdges(
            ast: ast,
            workingEdges: workingEdges,
            items: items,
            isHorizontal: isHorizontal,
            config: config
        )

        // 9. Normalize everything into positive coordinates with clean margin
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        func includeRect(_ r: CGRect) {
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }

        for item in items where !item.isDummy {
            includeRect(CGRect(
                x: item.center.x - item.size.width / 2,
                y: item.center.y - item.size.height / 2,
                width: item.size.width,
                height: item.size.height
            ))
        }
        for group in groups {
            includeRect(group.frame)
        }
        for edge in positionedEdges {
            for pt in edge.points {
                includeRect(CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
            }
            if let lf = edge.labelFrame {
                includeRect(lf)
            }
        }

        if minX == .greatestFiniteMagnitude {
            minX = 0; minY = 0; maxX = 100; maxY = 100
        }

        let shiftX = config.margin - minX
        let shiftY = config.margin - minY
        let totalSize = CGSize(
            width: ceil((maxX - minX) + config.margin * 2),
            height: ceil((maxY - minY) + config.margin * 2)
        )

        let finalNodes: [MermaidPositionedNode] = items.compactMap { item in
            guard !item.isDummy else { return nil }
            let frame = CGRect(
                x: item.center.x - item.size.width / 2 + shiftX,
                y: item.center.y - item.size.height / 2 + shiftY,
                width: item.size.width,
                height: item.size.height
            )
            return MermaidPositionedNode(
                id: item.id,
                wrappedLines: item.wrappedLines,
                subtitleLines: item.subtitleLines,
                secondaryLines: item.secondaryLines,
                shape: item.shape,
                frame: frame
            )
        }

        let finalGroups = groups.map { group in
            MermaidPositionedGroup(
                id: group.id,
                title: group.title,
                frame: group.frame.offsetBy(dx: shiftX, dy: shiftY),
                headerHeight: group.headerHeight,
                depth: group.depth
            )
        }

        let finalEdges = positionedEdges.map { edge in
            MermaidPositionedEdge(
                source: edge.source,
                target: edge.target,
                points: edge.points.map { CGPoint(x: $0.x + shiftX, y: $0.y + shiftY) },
                isBackEdge: edge.isBackEdge,
                lineStyle: edge.lineStyle,
                sourceArrow: edge.sourceArrow,
                targetArrow: edge.targetArrow,
                labelLines: edge.labelLines,
                labelFrame: edge.labelFrame?.offsetBy(dx: shiftX, dy: shiftY),
                sourceLabel: edge.sourceLabel,
                targetLabel: edge.targetLabel
            )
        }

        return MermaidPositionedGraph(
            type: ast.type,
            size: totalSize,
            groups: finalGroups,
            nodes: finalNodes,
            edges: finalEdges
        )
    }

    // MARK: - Node Measurement

    private static func measureNode(
        _ node: MermaidNode,
        measurer: MermaidTextMeasurer,
        maxTextWidth: CGFloat
    ) -> (size: CGSize, wrappedLines: [String]) {
        switch node.shape {
        case .stateStart, .stateEnd:
            return (CGSize(width: 24, height: 24), [])

        case .classBox:
            let header = measurer.wrapText(node.label, role: .nodeHeader, maxWidth: maxTextWidth)
            let attrSizes = node.subtitleLines.map { measurer.measureText($0, role: .nodeDetail, maxWidth: maxTextWidth) }
            let methodSizes = node.secondaryLines.map { measurer.measureText($0, role: .nodeDetail, maxWidth: maxTextWidth) }

            let maxW = max(
                header.size.width,
                attrSizes.map(\.width).max() ?? 0,
                methodSizes.map(\.width).max() ?? 0
            )
            let width = max(120, ceil(maxW + 28))
            let headerH = ceil(header.size.height + 16)
            let attrsH = node.subtitleLines.isEmpty ? 12 : ceil(attrSizes.reduce(0) { $0 + $1.height + 4 } + 12)
            let methodsH = node.secondaryLines.isEmpty ? 12 : ceil(methodSizes.reduce(0) { $0 + $1.height + 4 } + 12)
            return (CGSize(width: width, height: headerH + attrsH + methodsH), header.lines)

        case .entityBox:
            let header = measurer.wrapText(node.label, role: .nodeHeader, maxWidth: maxTextWidth)
            let rowSizes = node.subtitleLines.map { measurer.measureText($0, role: .nodeDetail, maxWidth: maxTextWidth) }
            let maxW = max(header.size.width, rowSizes.map(\.width).max() ?? 0)
            let width = max(120, ceil(maxW + 28))
            let headerH = ceil(header.size.height + 16)
            let rowsH = node.subtitleLines.isEmpty ? 16 : ceil(rowSizes.reduce(0) { $0 + $1.height + 5 } + 12)
            return (CGSize(width: width, height: headerH + rowsH), header.lines)

        default:
            let wrapped = measurer.wrapText(node.label, role: .nodeLabel, maxWidth: maxTextWidth)
            var w = ceil(wrapped.size.width) + 32
            var h = ceil(wrapped.size.height) + 20

            switch node.shape {
            case .diamond:
                // Ensure text fits comfortably inside diamond diagonals
                w = max(84, ceil(wrapped.size.width * 1.45 + 36))
                h = max(60, ceil(wrapped.size.height * 1.55 + 28))
            case .circle, .doubleCircle:
                let d = max(56, ceil(hypot(wrapped.size.width + 16, wrapped.size.height + 16)))
                w = d + (node.shape == .doubleCircle ? 10 : 0)
                h = w
            case .stadium:
                w += 14
            case .hexagon, .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt:
                w += 22
            case .subroutine:
                w += 16
            case .cylinder:
                h += 16
            default:
                break
            }

            return (CGSize(width: max(68, w), height: max(38, h)), wrapped.lines)
        }
    }

    // MARK: - Cycle Detection & Ranking

    private static func detectBackEdges(nodeCount: Int, edges: [(Int, Int)]) -> [Bool] {
        var adj = Array(repeating: [(edgeIdx: Int, dst: Int)](), count: nodeCount)
        for (i, e) in edges.enumerated() {
            adj[e.0].append((i, e.1))
        }

        enum State { case unvisited, visiting, visited }
        var state = Array(repeating: State.unvisited, count: nodeCount)
        var isBack = Array(repeating: false, count: edges.count)

        func dfs(_ u: Int) {
            state[u] = .visiting
            for (edgeIdx, v) in adj[u] {
                if state[v] == .visiting {
                    isBack[edgeIdx] = true
                } else if state[v] == .unvisited {
                    dfs(v)
                }
            }
            state[u] = .visited
        }

        for i in 0..<nodeCount where state[i] == .unvisited {
            dfs(i)
        }
        return isBack
    }

    private static func assignRanks(
        itemCount: Int,
        adjacency: [[Int]],
        inDegree initialInDegree: [Int],
        items: inout [LayoutItem]
    ) {
        var inDeg = initialInDegree
        var queue: [Int] = []
        for i in 0..<itemCount where inDeg[i] == 0 {
            queue.append(i)
        }

        var head = 0
        var topo: [Int] = []
        while head < queue.count {
            let u = queue[head]
            head += 1
            topo.append(u)
            for v in adjacency[u] {
                items[v].rank = max(items[v].rank, items[u].rank + 1)
                inDeg[v] -= 1
                if inDeg[v] == 0 {
                    queue.append(v)
                }
            }
        }

        // Pull source-only roots closer to their first target to eliminate wasted vertical stretch
        for u in topo.reversed() {
            if initialInDegree[u] == 0, !adjacency[u].isEmpty {
                let minChildRank = adjacency[u].map { items[$0].rank }.min() ?? 1
                items[u].rank = max(0, minChildRank - 1)
            }
        }
    }

    private static func barycenter(of neighbors: [Int], items: [LayoutItem], fallback: Double) -> Double {
        guard !neighbors.isEmpty else { return fallback }
        let sum = neighbors.reduce(0.0) { $0 + Double(items[$1].orderInRank) }
        return sum / Double(neighbors.count)
    }

    // MARK: - Coordinate Assignment

    private static func assignCoordinates(
        ranks: [[Int]],
        items: inout [LayoutItem],
        prevNeighbors: [[Int]],
        nextNeighbors: [[Int]],
        isHorizontal: Bool,
        config: Config
    ) {
        // 1. Primary axis position per rank
        var primaryCursor: CGFloat = 0
        var rankPrimaryCenter = Array(repeating: CGFloat(0), count: ranks.count)

        for (r, nodesInRank) in ranks.enumerated() {
            let maxSpan = nodesInRank.map { idx in
                isHorizontal ? items[idx].size.width : items[idx].size.height
            }.max() ?? 38
            rankPrimaryCenter[r] = primaryCursor + maxSpan / 2
            primaryCursor += maxSpan + config.layerSpacing
        }

        // 2. Initial secondary axis placement centered around 0
        for (r, nodesInRank) in ranks.enumerated() {
            let spans = nodesInRank.map { idx in
                isHorizontal ? items[idx].size.height : items[idx].size.width
            }
            let totalSpan = spans.reduce(0, +) + CGFloat(max(0, nodesInRank.count - 1)) * config.nodeSpacing
            var secCursor = -totalSpan / 2
            for (i, idx) in nodesInRank.enumerated() {
                let span = spans[i]
                let secCenter = secCursor + span / 2
                items[idx].center = isHorizontal
                    ? CGPoint(x: rankPrimaryCenter[r], y: secCenter)
                    : CGPoint(x: secCenter, y: rankPrimaryCenter[r])
                secCursor += span + config.nodeSpacing
            }
        }

        // 3. Refine secondary coordinates toward parent/child averages & resolve overlaps
        func secCoord(_ idx: Int) -> CGFloat {
            isHorizontal ? items[idx].center.y : items[idx].center.x
        }
        func setSecCoord(_ idx: Int, _ val: CGFloat) {
            if isHorizontal { items[idx].center.y = val }
            else { items[idx].center.x = val }
        }
        func secSpan(_ idx: Int) -> CGFloat {
            isHorizontal ? items[idx].size.height : items[idx].size.width
        }

        for _ in 0..<3 {
            // Downward pass: align with parents
            for r in 1..<ranks.count {
                for idx in ranks[r] {
                    let parents = prevNeighbors[idx]
                    if !parents.isEmpty {
                        let avg = parents.reduce(CGFloat(0)) { $0 + secCoord($1) } / CGFloat(parents.count)
                        setSecCoord(idx, avg)
                    }
                }
                resolveRankOverlaps(ranks[r], secCoord: secCoord, setSecCoord: setSecCoord, secSpan: secSpan, spacing: config.nodeSpacing)
            }

            // Upward pass: align with children
            if ranks.count >= 2 {
                for r in stride(from: ranks.count - 2, through: 0, by: -1) {
                    for idx in ranks[r] {
                        let children = nextNeighbors[idx]
                        if !children.isEmpty {
                            let avg = children.reduce(CGFloat(0)) { $0 + secCoord($1) } / CGFloat(children.count)
                            setSecCoord(idx, avg)
                        }
                    }
                    resolveRankOverlaps(ranks[r], secCoord: secCoord, setSecCoord: setSecCoord, secSpan: secSpan, spacing: config.nodeSpacing)
                }
            }
        }
    }

    private static func resolveRankOverlaps(
        _ rankNodes: [Int],
        secCoord: (Int) -> CGFloat,
        setSecCoord: (Int, CGFloat) -> Void,
        secSpan: (Int) -> CGFloat,
        spacing: CGFloat
    ) {
        guard rankNodes.count > 1 else { return }
        // Push left-to-right to ensure minimum spacing
        for i in 1..<rankNodes.count {
            let prev = rankNodes[i - 1]
            let curr = rankNodes[i]
            let minAllowed = secCoord(prev) + secSpan(prev) / 2 + spacing + secSpan(curr) / 2
            if secCoord(curr) < minAllowed {
                setSecCoord(curr, minAllowed)
            }
        }
        // Re-center the rank around the midpoint of its desired span if needed
        let first = rankNodes.first!
        let last = rankNodes.last!
        let minEdge = secCoord(first) - secSpan(first) / 2
        let maxEdge = secCoord(last) + secSpan(last) / 2
        let currentMid = (minEdge + maxEdge) / 2
        if abs(currentMid) > 200 {
            for idx in rankNodes {
                setSecCoord(idx, secCoord(idx) - currentMid)
            }
        }
    }

    // MARK: - Subgraph Bounding Boxes

    private static func computeSubgraphGroups(
        ast: MermaidGraphAST,
        items: [LayoutItem],
        idToItemIndex: [String: Int]
    ) -> [MermaidPositionedGroup] {
        guard !ast.subgraphs.isEmpty else { return [] }

        var depths: [String: Int] = [:]
        let byID = Dictionary(ast.subgraphs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func depth(of id: String, visited: Set<String> = []) -> Int {
            if let cached = depths[id] { return cached }
            guard let sg = byID[id], let pid = sg.parentID, !visited.contains(pid) else {
                depths[id] = 0
                return 0
            }
            var nextVisited = visited
            nextVisited.insert(id)
            let d = 1 + depth(of: pid, visited: nextVisited)
            depths[id] = d
            return d
        }

        for sg in ast.subgraphs {
            _ = depth(of: sg.id)
        }

        // Compute frames bottom-up (deepest first)
        let sortedIndices = ast.subgraphs.indices.sorted {
            (depths[ast.subgraphs[$0].id] ?? 0) > (depths[ast.subgraphs[$1].id] ?? 0)
        }

        var framesByID: [String: CGRect] = [:]
        var results: [MermaidPositionedGroup] = []
        let headerHeight: CGFloat = 26
        let padding: CGFloat = 14

        for idx in sortedIndices {
            let sg = ast.subgraphs[idx]
            var unionRect = CGRect.null

            for nodeID in sg.nodeIDs {
                if let itemIdx = idToItemIndex[nodeID] {
                    let item = items[itemIdx]
                    let r = CGRect(
                        x: item.center.x - item.size.width / 2,
                        y: item.center.y - item.size.height / 2,
                        width: item.size.width,
                        height: item.size.height
                    )
                    unionRect = unionRect.union(r)
                }
            }

            for childSG in ast.subgraphs where childSG.parentID == sg.id {
                if let childFrame = framesByID[childSG.id] {
                    unionRect = unionRect.union(childFrame)
                }
            }

            if unionRect.isNull {
                unionRect = CGRect(x: 0, y: 0, width: 120, height: 60)
            }

            let box = CGRect(
                x: unionRect.minX - padding,
                y: unionRect.minY - padding - headerHeight,
                width: max(120, unionRect.width + padding * 2),
                height: unionRect.height + padding * 2 + headerHeight
            )
            framesByID[sg.id] = box
            results.append(MermaidPositionedGroup(
                id: sg.id,
                title: sg.title,
                frame: box,
                headerHeight: headerHeight,
                depth: depths[sg.id] ?? 0
            ))
        }

        return results.sorted { $0.depth < $1.depth }
    }

    // MARK: - Edge Routing & Shape Clipping

    private static func routeAllEdges(
        ast: MermaidGraphAST,
        workingEdges: [WorkingEdge],
        items: [LayoutItem],
        isHorizontal: Bool,
        config: Config
    ) -> [MermaidPositionedEdge] {
        var result: [MermaidPositionedEdge] = []
        var backEdgeLaneIndex = 0
        var pairCounts: [String: Int] = [:]

        for we in workingEdges {
            let pairKey = "\(we.originalSource)->\(we.originalTarget)"
            let pairIndex = pairCounts[pairKey, default: 0]
            pairCounts[pairKey] = pairIndex + 1

            let astEdge = ast.edges[we.astIndex]
            let srcItem = items[we.originalSource]
            let dstItem = items[we.originalTarget]

            if we.isSelfLoop {
                let pts = routeSelfLoop(node: srcItem, loopIndex: pairIndex, isHorizontal: isHorizontal)
                let labelFrame = placeLabelOnSegment(
                    p0: pts[1],
                    p1: pts[2],
                    size: we.labelSize
                )
                result.append(MermaidPositionedEdge(
                    source: astEdge.source,
                    target: astEdge.target,
                    points: pts,
                    isBackEdge: true,
                    lineStyle: astEdge.lineStyle,
                    sourceArrow: astEdge.sourceArrow,
                    targetArrow: astEdge.targetArrow,
                    labelLines: we.labelLines,
                    labelFrame: labelFrame,
                    sourceLabel: astEdge.sourceLabel,
                    targetLabel: astEdge.targetLabel
                ))
                continue
            }

            if we.isBackEdge {
                backEdgeLaneIndex += 1
                let laneOffset = CGFloat(backEdgeLaneIndex) * config.backEdgeLaneStep
                let (pts, labelFrame) = routeBackEdge(
                    src: srcItem,
                    dst: dstItem,
                    allItems: items,
                    laneOffset: laneOffset,
                    labelSize: we.labelSize,
                    isHorizontal: isHorizontal
                )
                result.append(MermaidPositionedEdge(
                    source: astEdge.source,
                    target: astEdge.target,
                    points: pts,
                    isBackEdge: true,
                    lineStyle: astEdge.lineStyle,
                    sourceArrow: astEdge.sourceArrow,
                    targetArrow: astEdge.targetArrow,
                    labelLines: we.labelLines,
                    labelFrame: labelFrame,
                    sourceLabel: astEdge.sourceLabel,
                    targetLabel: astEdge.targetLabel
                ))
                continue
            }

            // Forward edge through optional dummy waypoints
            var rawPoints: [CGPoint] = [srcItem.center]
            for wpIdx in we.waypointItems {
                rawPoints.append(items[wpIdx].center)
            }
            rawPoints.append(dstItem.center)

            // Offset slightly if multiple parallel edges share the exact same endpoints
            if pairIndex > 0 {
                let delta = CGFloat((pairIndex % 2 == 1 ? 1 : -1) * ((pairIndex + 1) / 2)) * 12
                for i in rawPoints.indices {
                    if isHorizontal { rawPoints[i].y += delta }
                    else { rawPoints[i].x += delta }
                }
            }

            // Clip endpoints to source/target shapes
            if rawPoints.count >= 2 {
                let firstTarget = rawPoints[1]
                rawPoints[0] = clipPointToShape(
                    from: rawPoints[0],
                    toward: firstTarget,
                    node: srcItem
                )
                let lastIdx = rawPoints.count - 1
                let lastSource = rawPoints[lastIdx - 1]
                rawPoints[lastIdx] = clipPointToShape(
                    from: rawPoints[lastIdx],
                    toward: lastSource,
                    node: dstItem
                )
            }

            // Place label near the middle segment
            let midSegIdx = max(0, (rawPoints.count - 2) / 2)
            let labelFrame = we.labelLines.isEmpty ? nil : placeLabelOnSegment(
                p0: rawPoints[midSegIdx],
                p1: rawPoints[midSegIdx + 1],
                size: we.labelSize
            )

            result.append(MermaidPositionedEdge(
                source: astEdge.source,
                target: astEdge.target,
                points: rawPoints,
                isBackEdge: false,
                lineStyle: astEdge.lineStyle,
                sourceArrow: astEdge.sourceArrow,
                targetArrow: astEdge.targetArrow,
                labelLines: we.labelLines,
                labelFrame: labelFrame,
                sourceLabel: astEdge.sourceLabel,
                targetLabel: astEdge.targetLabel
            ))
        }

        return result
    }

    private static func routeSelfLoop(
        node: LayoutItem,
        loopIndex: Int,
        isHorizontal: Bool
    ) -> [CGPoint] {
        let offset = 28 + CGFloat(loopIndex) * 18
        if isHorizontal {
            let start = CGPoint(x: node.center.x + node.size.width * 0.25, y: node.center.y - node.size.height / 2)
            let p1 = CGPoint(x: start.x, y: node.center.y - node.size.height / 2 - offset)
            let p2 = CGPoint(x: node.center.x - node.size.width * 0.25, y: p1.y)
            let end = CGPoint(x: p2.x, y: node.center.y - node.size.height / 2)
            return [start, p1, p2, end]
        } else {
            let start = CGPoint(x: node.center.x + node.size.width / 2, y: node.center.y - node.size.height * 0.2)
            let p1 = CGPoint(x: node.center.x + node.size.width / 2 + offset, y: start.y)
            let p2 = CGPoint(x: p1.x, y: node.center.y + node.size.height * 0.2)
            let end = CGPoint(x: node.center.x + node.size.width / 2, y: p2.y)
            return [start, p1, p2, end]
        }
    }

    private static func routeBackEdge(
        src: LayoutItem,
        dst: LayoutItem,
        allItems: [LayoutItem],
        laneOffset: CGFloat,
        labelSize: CGSize,
        isHorizontal: Bool
    ) -> (points: [CGPoint], labelFrame: CGRect?) {
        let minRank = min(src.rank, dst.rank)
        let maxRank = max(src.rank, dst.rank)
        let spanItems = allItems.filter { !$0.isDummy && $0.rank >= minRank && $0.rank <= maxRank }

        if isHorizontal {
            let maxY = (spanItems.map { $0.center.y + $0.size.height / 2 }.max() ?? src.center.y)
            let laneY = maxY + laneOffset + labelSize.height * 0.4
            let start = CGPoint(x: src.center.x, y: src.center.y + src.size.height / 2)
            let p1 = CGPoint(x: src.center.x, y: laneY)
            let p2 = CGPoint(x: dst.center.x, y: laneY)
            let end = CGPoint(x: dst.center.x, y: dst.center.y + dst.size.height / 2)
            let labelFrame = labelSize == .zero ? nil : placeLabelOnSegment(p0: p1, p1: p2, size: labelSize)
            return ([start, p1, p2, end], labelFrame)
        } else {
            let maxX = (spanItems.map { $0.center.x + $0.size.width / 2 }.max() ?? src.center.x)
            let laneX = maxX + laneOffset + labelSize.width * 0.4
            let start = CGPoint(x: src.center.x + src.size.width / 2, y: src.center.y)
            let p1 = CGPoint(x: laneX, y: src.center.y)
            let p2 = CGPoint(x: laneX, y: dst.center.y)
            let end = CGPoint(x: dst.center.x + dst.size.width / 2, y: dst.center.y)
            let labelFrame = labelSize == .zero ? nil : placeLabelOnSegment(p0: p1, p1: p2, size: labelSize)
            return ([start, p1, p2, end], labelFrame)
        }
    }

    private static func placeLabelOnSegment(p0: CGPoint, p1: CGPoint, size: CGSize) -> CGRect? {
        guard size.width > 0 && size.height > 0 else { return nil }
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        return CGRect(
            x: mid.x - size.width / 2,
            y: mid.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clipPointToShape(from center: CGPoint, toward target: CGPoint, node: LayoutItem) -> CGPoint {
        let dx = target.x - center.x
        let dy = target.y - center.y
        if abs(dx) < 0.001 && abs(dy) < 0.001 {
            return center
        }

        let hw = node.size.width / 2
        let hh = node.size.height / 2

        switch node.shape {
        case .circle, .doubleCircle, .stateStart, .stateEnd:
            let r = min(hw, hh)
            let len = hypot(dx, dy)
            return CGPoint(x: center.x + dx / len * r, y: center.y + dy / len * r)

        case .diamond:
            // Diamond boundary: |x|/hw + |y|/hh = 1
            let denom = (abs(dx) / max(1, hw)) + (abs(dy) / max(1, hh))
            guard denom > 0.0001 else { return center }
            let t = 1.0 / denom
            return CGPoint(x: center.x + dx * t, y: center.y + dy * t)

        default:
            // Axis-aligned rectangle boundary
            let tx = abs(dx) > 0.0001 ? hw / abs(dx) : .greatestFiniteMagnitude
            let ty = abs(dy) > 0.0001 ? hh / abs(dy) : .greatestFiniteMagnitude
            let t = min(tx, ty)
            return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
        }
    }
}
