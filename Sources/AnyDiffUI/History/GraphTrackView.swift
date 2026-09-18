import AppKit
import AnyDiffCore

/// High-performance CoreGraphics NSView rendering visual Git Graph nodes, pass-through tracks, and smooth bezier curves.
public final class GraphTrackView: NSView {
    public static let laneWidth: CGFloat = 14.0
    public static let initialMargin: CGFloat = 14.0

    // High-contrast, clean modern Git palette (matching VS Code / GitKraken)
    private static let palette: [NSColor] = [
        NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1.0), // Blue (mainline)
        NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0), // Amber / Yellow
        NSColor(red: 0.12, green: 0.73, blue: 0.83, alpha: 1.0), // Cyan / Teal
        NSColor(red: 0.93, green: 0.28, blue: 0.60, alpha: 1.0), // Pink / Magenta
        NSColor(red: 0.61, green: 0.35, blue: 0.95, alpha: 1.0), // Purple
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0), // Green
        NSColor(red: 0.98, green: 0.45, blue: 0.18, alpha: 1.0), // Orange
        NSColor(red: 0.95, green: 0.25, blue: 0.37, alpha: 1.0)  // Rose
    ]

    public var graphRow: GraphRow? {
        didSet {
            needsDisplay = true
        }
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public static func xPosition(for lane: Int) -> CGFloat {
        initialMargin + CGFloat(lane) * laneWidth
    }

    public static func preferredWidth(for totalLanes: Int) -> CGFloat {
        let maxLane = max(0, totalLanes - 1)
        return xPosition(for: maxLane) + 8.0
    }

    public static func color(for index: Int) -> NSColor {
        let safeIndex = abs(index) % palette.count
        return palette[safeIndex]
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let row = graphRow, let context = NSGraphicsContext.current?.cgContext else { return }

        let height = bounds.height
        let midY = height / 2.0
        let lineWidth: CGFloat = 1.75

        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // 1. Draw Pass-Through Lanes (straight vertical lines from y=-1 to y=height+1)
        for track in row.passThroughTracks {
            let x = Self.xPosition(for: track.lane)
            let color = Self.color(for: track.colorIndex)

            context.setStrokeColor(color.cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: x, y: -1))
            context.addLine(to: CGPoint(x: x, y: height + 1))
            context.strokePath()
        }

        // 2. Draw Inbound Segments (from top y=-1 to midY where the commit node sits)
        for segment in row.inboundSegments {
            let fromX = Self.xPosition(for: segment.fromLane)
            let toX = Self.xPosition(for: segment.toLane)
            let color = Self.color(for: segment.colorIndex)

            context.setStrokeColor(color.cgColor)
            if segment.isDashed {
                context.setLineDash(phase: 0, lengths: [3, 3])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }

            context.beginPath()
            if fromX == toX {
                context.move(to: CGPoint(x: fromX, y: -1))
                context.addLine(to: CGPoint(x: toX, y: midY))
            } else {
                let span = midY
                let cp1 = CGPoint(x: fromX, y: span * 0.55)
                let cp2 = CGPoint(x: toX, y: midY - span * 0.45)
                context.move(to: CGPoint(x: fromX, y: -1))
                context.addCurve(to: CGPoint(x: toX, y: midY), control1: cp1, control2: cp2)
            }
            context.strokePath()
        }

        // 3. Draw Outbound Segments (from midY where the commit node sits down to y=height+1)
        for segment in row.outboundSegments {
            let fromX = Self.xPosition(for: segment.fromLane)
            let toX = Self.xPosition(for: segment.toLane)
            let color = Self.color(for: segment.colorIndex)

            context.setStrokeColor(color.cgColor)
            if segment.isDashed {
                context.setLineDash(phase: 0, lengths: [3, 3])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }

            context.beginPath()
            if fromX == toX {
                context.move(to: CGPoint(x: fromX, y: midY))
                context.addLine(to: CGPoint(x: toX, y: height + 1))
            } else {
                // Smooth S-curve with perfectly vertical entry and exit tangents
                let span = height - midY
                let cp1 = CGPoint(x: fromX, y: midY + span * 0.55)
                let cp2 = CGPoint(x: toX, y: height - span * 0.45)
                context.move(to: CGPoint(x: fromX, y: midY))
                context.addCurve(to: CGPoint(x: toX, y: height + 1), control1: cp1, control2: cp2)
            }
            context.strokePath()
        }

        // Reset line dash before drawing nodes
        context.setLineDash(phase: 0, lengths: [])

        // 4. Draw Commit Node at (nodeLane, midY)
        let nodeX = Self.xPosition(for: row.nodeLane)
        let nodeCenter = CGPoint(x: nodeX, y: midY)
        let nodeColor = Self.color(for: row.nodeColorIndex)

        if row.isWorkingChanges {
            // Dashed outer ring + center dot (Working Changes style)
            let outerRadius: CGFloat = 5.0
            let outerRect = CGRect(
                x: nodeCenter.x - outerRadius,
                y: nodeCenter.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            )

            context.setStrokeColor(nodeColor.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2.5, 2.5])
            context.strokeEllipse(in: outerRect)

            let innerRadius: CGFloat = 1.8
            let innerRect = CGRect(
                x: nodeCenter.x - innerRadius,
                y: nodeCenter.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            context.setFillColor(nodeColor.cgColor)
            context.fillEllipse(in: innerRect)
        } else if row.isMergeCommit {
            // Concentric Target Node for Merge Commits (VS Code style ◎)
            let outerRadius: CGFloat = 5.0
            let outerRect = CGRect(
                x: nodeCenter.x - outerRadius,
                y: nodeCenter.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            )

            // Background mask fill to cleanly isolate crossing lines
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillEllipse(in: outerRect)

            // Outer ring
            context.setStrokeColor(nodeColor.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: outerRect)

            // Inner solid dot
            let innerRadius: CGFloat = 2.0
            let innerRect = CGRect(
                x: nodeCenter.x - innerRadius,
                y: nodeCenter.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            context.setFillColor(nodeColor.cgColor)
            context.fillEllipse(in: innerRect)
        } else {
            // Regular Commit Node (Solid filled circle with subtle clean border)
            let radius: CGFloat = 3.5
            let rect = CGRect(
                x: nodeCenter.x - radius,
                y: nodeCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            // Solid inner circle
            context.setFillColor(nodeColor.cgColor)
            context.fillEllipse(in: rect)

            // Crisp border
            context.setStrokeColor(NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(0.75)
            context.strokeEllipse(in: rect)
        }

        context.restoreGState()
    }
}
