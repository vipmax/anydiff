import Foundation

/// A visual connection line or curve between lanes in a graph row.
public struct GraphSegment: Hashable, Sendable {
    public let fromLane: Int
    public let toLane: Int
    public let colorIndex: Int
    public let isDashed: Bool

    public init(fromLane: Int, toLane: Int, colorIndex: Int, isDashed: Bool = false) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.colorIndex = colorIndex
        self.isDashed = isDashed
    }
}

/// A vertical track passing straight through a row on a specific lane.
public struct PassThroughTrack: Hashable, Sendable {
    public let lane: Int
    public let colorIndex: Int

    public init(lane: Int, colorIndex: Int) {
        self.lane = lane
        self.colorIndex = colorIndex
    }
}

/// Layout information for a single row in the Git Graph.
public struct GraphRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let row: Int
    public let commit: GitCommit?
    public let isWorkingChanges: Bool
    public let isMergeCommit: Bool
    public let nodeLane: Int
    public let nodeColorIndex: Int
    public let passThroughTracks: [PassThroughTrack]
    public let inboundSegments: [GraphSegment]  // From top (y=0) to middle (y=0.5)
    public let outboundSegments: [GraphSegment] // From middle (y=0.5) to bottom (y=1.0)
    public let totalLanes: Int

    public init(
        id: String,
        row: Int,
        commit: GitCommit?,
        isWorkingChanges: Bool = false,
        isMergeCommit: Bool = false,
        nodeLane: Int,
        nodeColorIndex: Int,
        passThroughTracks: [PassThroughTrack],
        inboundSegments: [GraphSegment],
        outboundSegments: [GraphSegment],
        totalLanes: Int
    ) {
        self.id = id
        self.row = row
        self.commit = commit
        self.isWorkingChanges = isWorkingChanges
        self.isMergeCommit = isMergeCommit
        self.nodeLane = nodeLane
        self.nodeColorIndex = nodeColorIndex
        self.passThroughTracks = passThroughTracks
        self.inboundSegments = inboundSegments
        self.outboundSegments = outboundSegments
        self.totalLanes = totalLanes
    }
}

/// Pure Swift topological lane reservation algorithm for Git DAG graph rendering.
public final class GitGraphLayoutEngine: Sendable {
    public static let shared = GitGraphLayoutEngine()

    public static let paletteSize = 8

    public init() {}

    /// Generates graph rows with node positions, pass-through lines, and curves.
    public func buildLayout(commits: [GitCommit], includeWorkingChanges: Bool = true) -> [GraphRow] {
        guard !commits.isEmpty || includeWorkingChanges else { return [] }

        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count + (includeWorkingChanges ? 1 : 0))

        // Tracks which commit hash is expected next on each active lane
        var lanes: [String?] = []
        var currentRowIdx = 0

        // 1. Working Changes top row (if requested)
        if includeWorkingChanges {
            let workingColor = 0
            let headLane = 0
            if !commits.isEmpty {
                lanes.append(commits[0].hash)
            }

            let outbound = [
                GraphSegment(fromLane: headLane, toLane: headLane, colorIndex: workingColor, isDashed: true)
            ]

            let row = GraphRow(
                id: "working-changes",
                row: currentRowIdx,
                commit: nil,
                isWorkingChanges: true,
                isMergeCommit: false,
                nodeLane: headLane,
                nodeColorIndex: workingColor,
                passThroughTracks: [],
                inboundSegments: [],
                outboundSegments: outbound,
                totalLanes: 1
            )
            rows.append(row)
            currentRowIdx += 1
        }

        // 2. Process all commits in topological order
        for commit in commits {
            let commitHash = commit.hash

            // Find all active lanes currently expecting this commit
            var matchingLanes: [Int] = []
            for (idx, expected) in lanes.enumerated() {
                if expected == commitHash {
                    matchingLanes.append(idx)
                }
            }

            // The node is placed on the lowest-index (most primary) matching lane, or a newly allocated lane
            let nodeLane: Int
            if let primary = matchingLanes.min() {
                nodeLane = primary
            } else {
                if let freeIdx = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[freeIdx] = commitHash
                    nodeLane = freeIdx
                } else {
                    lanes.append(commitHash)
                    nodeLane = lanes.count - 1
                }
            }

            // Each lane index has a consistent, stable color (Lane 0 is always Blue mainline)
            let nodeColor = nodeLane % Self.paletteSize

            // Inbound segments: straight track from previous row, plus any other branches converging into this node
            var inbound: [GraphSegment] = []
            let isFirstCommitUnderWorkingChanges = includeWorkingChanges && currentRowIdx == 1
            inbound.append(GraphSegment(
                fromLane: nodeLane,
                toLane: nodeLane,
                colorIndex: nodeColor,
                isDashed: isFirstCommitUnderWorkingChanges
            ))

            for otherLane in matchingLanes where otherLane != nodeLane {
                inbound.append(GraphSegment(
                    fromLane: otherLane,
                    toLane: nodeLane,
                    colorIndex: otherLane % Self.paletteSize
                ))
                // Free this secondary lane now that it merged into nodeLane
                lanes[otherLane] = nil
            }

            // Pass-through tracks: active lanes not belonging to this commit
            var passThrough: [PassThroughTrack] = []
            for (idx, expected) in lanes.enumerated() {
                if idx != nodeLane, !matchingLanes.contains(idx), expected != nil {
                    passThrough.append(PassThroughTrack(lane: idx, colorIndex: idx % Self.paletteSize))
                }
            }

            // Outbound segments: connecting this commit down to its parent(s)
            var outbound: [GraphSegment] = []
            let parents = commit.parentHashes
            let isMerge = commit.isMergeCommit

            if parents.isEmpty {
                // Root commit (no parents) -> terminates this lane
                lanes[nodeLane] = nil
            } else if parents.count == 1 {
                let p0 = parents[0]
                if let existingParentLane = lanes.firstIndex(where: { $0 == p0 }) {
                    if existingParentLane < nodeLane {
                        // Parent is already expected on a lower (more primary) lane: curve into it and terminate this lane
                        outbound.append(GraphSegment(fromLane: nodeLane, toLane: existingParentLane, colorIndex: nodeColor))
                        lanes[nodeLane] = nil
                    } else if existingParentLane == nodeLane {
                        // Continue straight on the same lane
                        outbound.append(GraphSegment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeColor))
                    } else {
                        // existingParentLane > nodeLane: we are on the more primary lane! Keep p0 on our lane.
                        lanes[nodeLane] = p0
                        outbound.append(GraphSegment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeColor))
                    }
                } else {
                    // Continue down on the same lane
                    lanes[nodeLane] = p0
                    outbound.append(GraphSegment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeColor))
                }
            } else {
                // Merge commit with 2 or more parents
                let p0 = parents[0]
                // First parent continues on nodeLane
                lanes[nodeLane] = p0
                outbound.append(GraphSegment(fromLane: nodeLane, toLane: nodeLane, colorIndex: nodeColor))

                // Additional parents (branches branching off or merging)
                for pIdx in 1..<parents.count {
                    let pi = parents[pIdx]
                    if let existingParentLane = lanes.firstIndex(where: { $0 == pi }) {
                        outbound.append(GraphSegment(fromLane: nodeLane, toLane: existingParentLane, colorIndex: existingParentLane % Self.paletteSize))
                    } else {
                        let branchLane: Int
                        if let freeIdx = lanes.firstIndex(where: { $0 == nil }) {
                            lanes[freeIdx] = pi
                            branchLane = freeIdx
                        } else {
                            lanes.append(pi)
                            branchLane = lanes.count - 1
                        }
                        outbound.append(GraphSegment(fromLane: nodeLane, toLane: branchLane, colorIndex: branchLane % Self.paletteSize))
                    }
                }
            }

            // Compact trailing nil lanes to avoid unnecessary horizontal padding
            while let last = lanes.last, last == nil {
                lanes.removeLast()
            }

            let maxActiveLane = max(
                nodeLane,
                inbound.map(\.fromLane).max() ?? 0,
                inbound.map(\.toLane).max() ?? 0,
                outbound.map(\.fromLane).max() ?? 0,
                outbound.map(\.toLane).max() ?? 0,
                passThrough.map(\.lane).max() ?? 0
            )

            let graphRow = GraphRow(
                id: commit.hash,
                row: currentRowIdx,
                commit: commit,
                isWorkingChanges: false,
                isMergeCommit: isMerge,
                nodeLane: nodeLane,
                nodeColorIndex: nodeColor,
                passThroughTracks: passThrough.sorted(by: { $0.lane < $1.lane }),
                inboundSegments: inbound,
                outboundSegments: outbound,
                totalLanes: max(1, maxActiveLane + 1)
            )

            rows.append(graphRow)
            currentRowIdx += 1
        }

        return rows
    }
}
