import AppKit
import CoreGraphics
import CoreText
import AnyDiffCore

public enum MermaidCGContextRenderer {
    public static func draw(
        _ diagram: MermaidLayoutDiagram,
        in ctx: CGContext,
        palette: MermaidThemePalette,
        opaqueBackground: NSColor? = nil
    ) {
        let logicalSize = diagram.size
        guard logicalSize.width > 1, logicalSize.height > 1 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        if let bg = opaqueBackground {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(origin: .zero, size: logicalSize))
        }

        switch diagram {
        case .graph(let graph):
            drawGraph(graph, in: ctx, palette: palette)
        case .sequence(let sequence):
            drawSequence(sequence, in: ctx, palette: palette)
        case .pie(let pie):
            drawPie(pie, in: ctx, palette: palette)
        }
    }

    public static func renderImage(
        _ diagram: MermaidLayoutDiagram,
        palette: MermaidThemePalette,
        scale: CGFloat = 2.0,
        opaqueBackground: NSColor? = nil
    ) -> NSImage? {
        let logicalSize = diagram.size
        guard logicalSize.width > 1, logicalSize.height > 1 else { return nil }

        let pixelWidth = max(2, Int(ceil(logicalSize.width * scale)))
        let pixelHeight = max(2, Int(ceil(logicalSize.height * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Flip to top-left origin in logical points
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: logicalSize.height)
        ctx.scaleBy(x: 1, y: -1)

        draw(diagram, in: ctx, palette: palette, opaqueBackground: opaqueBackground)

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = NSImage(size: logicalSize)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize
        image.addRepresentation(rep)
        return image
    }

    public static func pngData(from image: NSImage) -> Data? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
            ?? image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Graph Drawing

    private static func drawGraph(
        _ graph: MermaidPositionedGraph,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        // 1. Subgroups
        for group in graph.groups {
            drawSubgraph(group, in: ctx, palette: palette)
        }

        // 2. Edges & Arrowheads
        for edge in graph.edges {
            drawEdgePath(edge, in: ctx, palette: palette)
            drawArrowHeads(edge, in: ctx, palette: palette)
        }

        // 3. Nodes
        var nodeAccentIndex = 0
        for node in graph.nodes {
            let accent: MermaidNodeAccent
            if node.shape == .stateStart || node.shape == .stateEnd {
                accent = palette.accentColors(at: 0)
            } else {
                accent = palette.accentColors(at: nodeAccentIndex)
                nodeAccentIndex += 1
            }
            drawNode(node, accent: accent, in: ctx, palette: palette)
        }

        // 4. Edge Labels on top so they stay legible
        for edge in graph.edges {
            if let lf = edge.labelFrame, !edge.labelLines.isEmpty {
                drawEdgeLabelPill(lines: edge.labelLines, frame: lf, in: ctx, palette: palette)
            }
            if let srcLabel = edge.sourceLabel, !srcLabel.isEmpty, let first = edge.points.first {
                drawCardinalityLabel(srcLabel, near: first, toward: edge.points.dropFirst().first ?? first, in: ctx, palette: palette)
            }
            if let dstLabel = edge.targetLabel, !dstLabel.isEmpty, let last = edge.points.last {
                let prev = edge.points.dropLast().last ?? last
                drawCardinalityLabel(dstLabel, near: last, toward: prev, in: ctx, palette: palette)
            }
        }
    }

    private static func drawSubgraph(
        _ group: MermaidPositionedGroup,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = group.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(palette.groupFill.cgColor)
        ctx.fillPath()

        // Header strip
        ctx.addPath(path)
        ctx.clip()
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: group.headerHeight)
        ctx.setFillColor(palette.groupHeaderFill.cgColor)
        ctx.fill(headerRect)
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(palette.groupBorder.cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()

        if !group.title.isEmpty {
            let font = MermaidCoreTextMeasurer.font(for: .groupTitle)
            drawCenteredLines(
                [group.title],
                in: CGRect(x: rect.minX + 10, y: rect.minY, width: rect.width - 20, height: group.headerHeight),
                font: font,
                color: palette.groupText,
                alignment: .left,
                ctx: ctx
            )
        }
    }

    private static func drawEdgePath(
        _ edge: MermaidPositionedEdge,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        guard edge.points.count >= 2 else { return }

        ctx.saveGState()
        let lineWidth: CGFloat = edge.lineStyle == .thick ? 2.4 : 1.4
        ctx.setStrokeColor(palette.edgeLine.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if edge.lineStyle == .dotted {
            ctx.setLineDash(phase: 0, lengths: [5, 4])
        }

        let path = roundedPolylinePath(points: edge.points, cornerRadius: 10)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func roundedPolylinePath(points: [CGPoint], cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        for i in 1..<(points.count - 1) {
            let p0 = points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]

            let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
            let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
            let len1 = hypot(v1.x, v1.y)
            let len2 = hypot(v2.x, v2.y)

            if len1 < 1 || len2 < 1 {
                path.addLine(to: p1)
                continue
            }

            let r = min(cornerRadius, len1 * 0.45, len2 * 0.45)
            let startArc = CGPoint(x: p1.x + v1.x / len1 * r, y: p1.y + v1.y / len1 * r)
            let endArc = CGPoint(x: p1.x + v2.x / len2 * r, y: p1.y + v2.y / len2 * r)

            path.addLine(to: startArc)
            path.addQuadCurve(to: endArc, control: p1)
        }

        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }

    private static func drawArrowHeads(
        _ edge: MermaidPositionedEdge,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        guard edge.points.count >= 2 else { return }
        if edge.targetArrow != .none {
            let pPrev = edge.points[edge.points.count - 2]
            let pEnd = edge.points[edge.points.count - 1]
            let angle = atan2(pEnd.y - pPrev.y, pEnd.x - pPrev.x)
            drawMarker(edge.targetArrow, at: pEnd, angle: angle, in: ctx, palette: palette)
        }
        if edge.sourceArrow != .none {
            let pNext = edge.points[1]
            let pStart = edge.points[0]
            let angle = atan2(pStart.y - pNext.y, pStart.x - pNext.x)
            drawMarker(edge.sourceArrow, at: pStart, angle: angle, in: ctx, palette: palette)
        }
    }

    private static func drawMarker(
        _ kind: MermaidArrowHead,
        at tip: CGPoint,
        angle: CGFloat,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        ctx.rotate(by: angle)
        ctx.setStrokeColor(palette.edgeLine.cgColor)
        ctx.setFillColor(palette.edgeLine.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch kind {
        case .none:
            break

        case .normal:
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: -9, y: -4.2))
            p.addLine(to: CGPoint(x: -7, y: 0))
            p.addLine(to: CGPoint(x: -9, y: 4.2))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.fillPath()

        case .open:
            ctx.move(to: CGPoint(x: -9, y: -4.5))
            ctx.addLine(to: .zero)
            ctx.addLine(to: CGPoint(x: -9, y: 4.5))
            ctx.strokePath()

        case .circle:
            let r: CGFloat = 3.8
            let rect = CGRect(x: -r * 2, y: -r, width: r * 2, height: r * 2)
            ctx.setFillColor(palette.nodeFill.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)

        case .cross:
            ctx.move(to: CGPoint(x: -10, y: -4))
            ctx.addLine(to: CGPoint(x: -2, y: 4))
            ctx.move(to: CGPoint(x: -10, y: 4))
            ctx.addLine(to: CGPoint(x: -2, y: -4))
            ctx.strokePath()

        case .inheritance:
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: -10, y: -5))
            p.addLine(to: CGPoint(x: -10, y: 5))
            p.closeSubpath()
            ctx.setFillColor(palette.nodeFill.cgColor)
            ctx.addPath(p)
            ctx.fillPath()
            ctx.addPath(p)
            ctx.strokePath()

        case .composition, .aggregation:
            let p = CGMutablePath()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: -6, y: -4))
            p.addLine(to: CGPoint(x: -12, y: 0))
            p.addLine(to: CGPoint(x: -6, y: 4))
            p.closeSubpath()
            if kind == .composition {
                ctx.addPath(p)
                ctx.fillPath()
            } else {
                ctx.setFillColor(palette.nodeFill.cgColor)
                ctx.addPath(p)
                ctx.fillPath()
                ctx.addPath(p)
                ctx.strokePath()
            }

        case .erOnlyOne:
            ctx.move(to: CGPoint(x: -5, y: -5))
            ctx.addLine(to: CGPoint(x: -5, y: 5))
            ctx.move(to: CGPoint(x: -9, y: -5))
            ctx.addLine(to: CGPoint(x: -9, y: 5))
            ctx.strokePath()

        case .erZeroOrOne:
            ctx.move(to: CGPoint(x: -5, y: -5))
            ctx.addLine(to: CGPoint(x: -5, y: 5))
            ctx.strokePath()
            let r: CGFloat = 3.2
            let circleRect = CGRect(x: -12, y: -r, width: r * 2, height: r * 2)
            ctx.setFillColor(palette.nodeFill.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.strokeEllipse(in: circleRect)

        case .erOneOrMore:
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: -8, y: -5))
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: -8, y: 5))
            ctx.move(to: CGPoint(x: -9, y: -5))
            ctx.addLine(to: CGPoint(x: -9, y: 5))
            ctx.strokePath()

        case .erZeroOrMore:
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: -8, y: -5))
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: -8, y: 5))
            ctx.strokePath()
            let r: CGFloat = 3.2
            let circleRect = CGRect(x: -14, y: -r, width: r * 2, height: r * 2)
            ctx.setFillColor(palette.nodeFill.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.strokeEllipse(in: circleRect)
        }

        ctx.restoreGState()
    }

    private static func drawNode(
        _ node: MermaidPositionedNode,
        accent: MermaidNodeAccent,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = node.frame
        ctx.saveGState()

        switch node.shape {
        case .stateStart:
            ctx.setFillColor(palette.nodeText.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            return

        case .stateEnd:
            ctx.setStrokeColor(palette.nodeText.cgColor)
            ctx.setLineWidth(1.8)
            ctx.strokeEllipse(in: rect)
            ctx.setFillColor(palette.nodeText.cgColor)
            ctx.fillEllipse(in: rect.insetBy(dx: 5, dy: 5))
            ctx.restoreGState()
            return

        case .classBox:
            drawClassBox(node, accent: accent, in: ctx, palette: palette)
            ctx.restoreGState()
            return

        case .entityBox:
            drawEntityBox(node, accent: accent, in: ctx, palette: palette)
            ctx.restoreGState()
            return

        default:
            let path = shapePath(for: node.shape, in: rect)
            ctx.addPath(path)
            ctx.setFillColor(accent.fill.cgColor)
            ctx.fillPath()

            ctx.addPath(path)
            ctx.setStrokeColor(accent.stroke.cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokePath()

            drawShapeDecorations(for: node.shape, in: rect, strokeColor: accent.stroke, ctx: ctx)
        }

        ctx.restoreGState()

        if !node.wrappedLines.isEmpty {
            let textRect: CGRect
            if node.shape == .cylinder {
                textRect = CGRect(x: rect.minX + 8, y: rect.minY + 12, width: rect.width - 16, height: rect.height - 18)
            } else {
                textRect = rect.insetBy(dx: 8, dy: 4)
            }
            drawCenteredLines(
                node.wrappedLines,
                in: textRect,
                font: MermaidCoreTextMeasurer.font(for: .nodeLabel),
                color: palette.nodeText,
                alignment: .center,
                ctx: ctx
            )
        }
    }

    private static func shapePath(for shape: MermaidNodeShape, in rect: CGRect) -> CGPath {
        switch shape {
        case .rectangle, .subroutine:
            return CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        case .rounded:
            return CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)

        case .stadium:
            let r = min(rect.height / 2, rect.width / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

        case .circle, .doubleCircle:
            return CGPath(ellipseIn: rect, transform: nil)

        case .diamond:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p

        case .hexagon:
            let inset: CGFloat = min(14, rect.width * 0.18)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.closeSubpath()
            return p

        case .parallelogram:
            let skew: CGFloat = min(14, rect.width * 0.16)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p

        case .parallelogramAlt:
            let skew: CGFloat = min(14, rect.width * 0.16)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + skew, y: rect.maxY))
            p.closeSubpath()
            return p

        case .trapezoid:
            let skew: CGFloat = min(14, rect.width * 0.16)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p

        case .trapezoidAlt:
            let skew: CGFloat = min(14, rect.width * 0.16)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + skew, y: rect.maxY))
            p.closeSubpath()
            return p

        case .cylinder:
            let capH: CGFloat = 10
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + capH / 2))
            p.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + capH / 2),
                control1: CGPoint(x: rect.minX, y: rect.minY - capH * 0.3),
                control2: CGPoint(x: rect.maxX, y: rect.minY - capH * 0.3)
            )
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - capH / 2))
            p.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - capH / 2),
                control1: CGPoint(x: rect.maxX, y: rect.maxY + capH * 0.3),
                control2: CGPoint(x: rect.minX, y: rect.maxY + capH * 0.3)
            )
            p.closeSubpath()
            return p

        default:
            return CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        }
    }

    private static func drawShapeDecorations(
        for shape: MermaidNodeShape,
        in rect: CGRect,
        strokeColor: NSColor,
        ctx: CGContext
    ) {
        if shape == .doubleCircle {
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 4, dy: 4))
        } else if shape == .subroutine {
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.1)
            ctx.move(to: CGPoint(x: rect.minX + 8, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX + 8, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.maxX - 8, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY))
            ctx.strokePath()
        } else if shape == .cylinder {
            let capH: CGFloat = 10
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.1)
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + capH / 2))
            ctx.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + capH / 2),
                control1: CGPoint(x: rect.minX, y: rect.minY + capH * 1.3),
                control2: CGPoint(x: rect.maxX, y: rect.minY + capH * 1.3)
            )
            ctx.strokePath()
        }
    }

    private static func drawClassBox(
        _ node: MermaidPositionedNode,
        accent: MermaidNodeAccent,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = node.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(accent.fill.cgColor)
        ctx.fillPath()

        let headerFont = MermaidCoreTextMeasurer.font(for: .nodeHeader)
        let detailFont = MermaidCoreTextMeasurer.font(for: .nodeDetail)
        let lineH = ceil(detailFont.ascender - detailFont.descender + detailFont.leading + 3) + 2

        let headerLineH = ceil(headerFont.ascender - headerFont.descender + headerFont.leading + 3)
        let headerH = ceil(CGFloat(max(1, node.wrappedLines.count)) * headerLineH + 14)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(accent.headerFill.cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerH))
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(accent.stroke.cgColor)
        ctx.setLineWidth(1.3)
        ctx.strokePath()

        drawCenteredLines(
            node.wrappedLines,
            in: CGRect(x: rect.minX + 8, y: rect.minY, width: rect.width - 16, height: headerH),
            font: headerFont,
            color: palette.nodeText,
            alignment: .center,
            ctx: ctx
        )

        let attrsTop = rect.minY + headerH
        let attrsH = node.subtitleLines.isEmpty ? 12 : CGFloat(node.subtitleLines.count) * lineH + 10

        ctx.setStrokeColor(accent.stroke.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: rect.minX, y: attrsTop))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: attrsTop))
        ctx.strokePath()

        if !node.subtitleLines.isEmpty {
            drawCenteredLines(
                node.subtitleLines,
                in: CGRect(x: rect.minX + 10, y: attrsTop + 4, width: rect.width - 20, height: attrsH - 8),
                font: detailFont,
                color: palette.nodeText.withAlphaComponent(0.9),
                alignment: .left,
                ctx: ctx
            )
        }

        let methodsTop = attrsTop + attrsH
        ctx.move(to: CGPoint(x: rect.minX, y: methodsTop))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: methodsTop))
        ctx.strokePath()

        if !node.secondaryLines.isEmpty {
            let methodsH = rect.maxY - methodsTop
            drawCenteredLines(
                node.secondaryLines,
                in: CGRect(x: rect.minX + 10, y: methodsTop + 4, width: rect.width - 20, height: methodsH - 8),
                font: detailFont,
                color: palette.nodeText.withAlphaComponent(0.9),
                alignment: .left,
                ctx: ctx
            )
        }
    }

    private static func drawEntityBox(
        _ node: MermaidPositionedNode,
        accent: MermaidNodeAccent,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = node.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(accent.fill.cgColor)
        ctx.fillPath()

        let headerFont = MermaidCoreTextMeasurer.font(for: .nodeHeader)
        let detailFont = MermaidCoreTextMeasurer.font(for: .nodeDetail)
        let headerLineH = ceil(headerFont.ascender - headerFont.descender + headerFont.leading + 3)
        let headerH = ceil(CGFloat(max(1, node.wrappedLines.count)) * headerLineH + 14)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(accent.headerFill.cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerH))
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(accent.stroke.cgColor)
        ctx.setLineWidth(1.3)
        ctx.strokePath()

        ctx.setStrokeColor(accent.stroke.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + headerH))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + headerH))
        ctx.strokePath()

        drawCenteredLines(
            node.wrappedLines,
            in: CGRect(x: rect.minX + 8, y: rect.minY, width: rect.width - 16, height: headerH),
            font: headerFont,
            color: palette.nodeText,
            alignment: .center,
            ctx: ctx
        )

        if !node.subtitleLines.isEmpty {
            let rowsRect = CGRect(
                x: rect.minX + 10,
                y: rect.minY + headerH + 5,
                width: rect.width - 20,
                height: rect.maxY - (rect.minY + headerH) - 10
            )
            drawCenteredLines(
                node.subtitleLines,
                in: rowsRect,
                font: detailFont,
                color: palette.nodeText.withAlphaComponent(0.9),
                alignment: .left,
                ctx: ctx
            )
        }
    }

    private static func drawEdgeLabelPill(
        lines: [String],
        frame: CGRect,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let path = CGPath(roundedRect: frame, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(palette.edgeLabelFill.cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(palette.edgeLabelBorder.cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()

        drawCenteredLines(
            lines,
            in: frame.insetBy(dx: 4, dy: 2),
            font: MermaidCoreTextMeasurer.font(for: .edgeLabel),
            color: palette.edgeLabelText,
            alignment: .center,
            ctx: ctx
        )
    }

    private static func drawCardinalityLabel(
        _ text: String,
        near point: CGPoint,
        toward other: CGPoint,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let dx = other.x - point.x
        let dy = other.y - point.y
        let len = max(1, hypot(dx, dy))
        let pos = CGPoint(x: point.x + dx / len * 18, y: point.y + dy / len * 18)
        let box = CGRect(x: pos.x - 18, y: pos.y - 10, width: 36, height: 20)
        drawCenteredLines(
            [text],
            in: box,
            font: MermaidCoreTextMeasurer.font(for: .nodeDetail),
            color: palette.edgeLabelText,
            alignment: .center,
            ctx: ctx
        )
    }

    // MARK: - Sequence Diagram Drawing

    private static func drawSequence(
        _ seq: MermaidPositionedSequence,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        // 1. Control blocks (background)
        for block in seq.blocks {
            drawSequenceBlock(block, in: ctx, palette: palette)
        }

        // 2. Lifelines
        ctx.saveGState()
        ctx.setStrokeColor(palette.nodeBorder.withAlphaComponent(0.65).cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        for p in seq.participants {
            ctx.move(to: CGPoint(x: p.centerX, y: p.lifelineTopY))
            ctx.addLine(to: CGPoint(x: p.centerX, y: p.lifelineBottomY))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 3. Activations
        for act in seq.activations {
            let pIndex = seq.participants.firstIndex(where: { abs($0.centerX - act.frame.midX) < 20 }) ?? 0
            let accent = palette.accentColors(at: pIndex)
            let path = CGPath(roundedRect: act.frame, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(accent.headerFill.cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.stroke.cgColor)
            ctx.setLineWidth(1.1)
            ctx.strokePath()
        }

        // 4. Participant headers (top & bottom)
        for (index, p) in seq.participants.enumerated() {
            let accent = palette.accentColors(at: index)
            drawSequenceParticipant(p, frame: p.topFrame, accent: accent, in: ctx, palette: palette)
            drawSequenceParticipant(p, frame: p.bottomFrame, accent: accent, in: ctx, palette: palette)
        }

        // 5. Messages
        for msg in seq.messages {
            drawSequenceMessage(msg, in: ctx, palette: palette)
        }

        // 6. Notes
        for note in seq.notes {
            drawSequenceNote(note, in: ctx, palette: palette)
        }
    }

    private static func drawSequenceParticipant(
        _ p: MermaidPositionedSequenceParticipant,
        frame: CGRect,
        accent: MermaidNodeAccent,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        if p.kind == .actor {
            let cx = frame.midX
            let headR: CGFloat = 7
            let headCenterY = frame.minY + 10
            ctx.saveGState()
            ctx.setStrokeColor(accent.stroke.cgColor)
            ctx.setFillColor(accent.fill.cgColor)
            ctx.setLineWidth(1.5)
            let headRect = CGRect(x: cx - headR, y: headCenterY - headR, width: headR * 2, height: headR * 2)
            ctx.fillEllipse(in: headRect)
            ctx.strokeEllipse(in: headRect)
            // Body & limbs
            ctx.move(to: CGPoint(x: cx, y: headCenterY + headR))
            ctx.addLine(to: CGPoint(x: cx, y: headCenterY + headR + 11))
            ctx.move(to: CGPoint(x: cx - 9, y: headCenterY + headR + 4))
            ctx.addLine(to: CGPoint(x: cx + 9, y: headCenterY + headR + 4))
            ctx.move(to: CGPoint(x: cx, y: headCenterY + headR + 11))
            ctx.addLine(to: CGPoint(x: cx - 7, y: headCenterY + headR + 18))
            ctx.move(to: CGPoint(x: cx, y: headCenterY + headR + 11))
            ctx.addLine(to: CGPoint(x: cx + 7, y: headCenterY + headR + 18))
            ctx.strokePath()
            ctx.restoreGState()

            let labelRect = CGRect(x: frame.minX + 4, y: headCenterY + headR + 19, width: frame.width - 8, height: frame.maxY - (headCenterY + headR + 19))
            drawCenteredLines(
                p.labelLines,
                in: labelRect,
                font: MermaidCoreTextMeasurer.font(for: .sequenceParticipant),
                color: palette.nodeText,
                alignment: .center,
                ctx: ctx
            )
        } else {
            let path = CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(accent.fill.cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.stroke.cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokePath()

            drawCenteredLines(
                p.labelLines,
                in: frame.insetBy(dx: 6, dy: 4),
                font: MermaidCoreTextMeasurer.font(for: .sequenceParticipant),
                color: palette.nodeText,
                alignment: .center,
                ctx: ctx
            )
        }
    }

    private static func drawSequenceBlock(
        _ block: MermaidPositionedSequenceBlock,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = block.frame
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(palette.groupFill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(palette.groupBorder.cgColor)
        ctx.setLineWidth(1.1)
        ctx.strokePath()

        // Pentagon tag in top-left
        let tagText = block.kind.rawValue
        let tagW = max(44, CGFloat(tagText.count) * 8 + 18)
        let tagH: CGFloat = 20
        let tagPath = CGMutablePath()
        tagPath.move(to: CGPoint(x: rect.minX, y: rect.minY))
        tagPath.addLine(to: CGPoint(x: rect.minX + tagW, y: rect.minY))
        tagPath.addLine(to: CGPoint(x: rect.minX + tagW, y: rect.minY + tagH - 6))
        tagPath.addLine(to: CGPoint(x: rect.minX + tagW - 6, y: rect.minY + tagH))
        tagPath.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tagH))
        tagPath.closeSubpath()

        ctx.addPath(tagPath)
        ctx.setFillColor(palette.groupHeaderFill.cgColor)
        ctx.fillPath()
        ctx.addPath(tagPath)
        ctx.setStrokeColor(palette.groupBorder.cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()

        drawCenteredLines(
            [tagText],
            in: CGRect(x: rect.minX + 4, y: rect.minY, width: tagW - 8, height: tagH),
            font: MermaidCoreTextMeasurer.font(for: .groupTitle),
            color: palette.groupText,
            alignment: .center,
            ctx: ctx
        )

        if !block.label.isEmpty {
            drawCenteredLines(
                ["[\(block.label)]"],
                in: CGRect(x: rect.minX + tagW + 8, y: rect.minY, width: rect.width - tagW - 14, height: tagH),
                font: MermaidCoreTextMeasurer.font(for: .sequenceMessage),
                color: palette.groupText,
                alignment: .left,
                ctx: ctx
            )
        }

        // Dividers (else / and / option)
        for div in block.dividers {
            ctx.saveGState()
            ctx.setStrokeColor(palette.groupBorder.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: rect.minX, y: div.y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: div.y))
            ctx.strokePath()
            ctx.restoreGState()

            if !div.label.isEmpty {
                drawCenteredLines(
                    ["[\(div.label)]"],
                    in: CGRect(x: rect.minX + 10, y: div.y + 3, width: rect.width - 20, height: 18),
                    font: MermaidCoreTextMeasurer.font(for: .sequenceMessage),
                    color: palette.groupText,
                    alignment: .left,
                    ctx: ctx
                )
            }
        }
    }

    private static func drawSequenceMessage(
        _ msg: MermaidPositionedSequenceMessage,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(palette.edgeLine.cgColor)
        ctx.setLineWidth(1.4)
        if msg.lineStyle == .dotted {
            ctx.setLineDash(phase: 0, lengths: [5, 4])
        }

        if msg.isSelfMessage {
            let loopW: CGFloat = 30
            let loopH: CGFloat = 24
            let pts = [
                CGPoint(x: msg.fromX, y: msg.y),
                CGPoint(x: msg.fromX + loopW, y: msg.y),
                CGPoint(x: msg.fromX + loopW, y: msg.y + loopH),
                CGPoint(x: msg.fromX, y: msg.y + loopH)
            ]
            ctx.addPath(roundedPolylinePath(points: pts, cornerRadius: 6))
            ctx.strokePath()
            ctx.restoreGState()
            drawMarker(msg.arrowHead, at: pts[3], angle: .pi, in: ctx, palette: palette)
        } else {
            ctx.move(to: CGPoint(x: msg.fromX, y: msg.y))
            ctx.addLine(to: CGPoint(x: msg.toX, y: msg.y))
            ctx.strokePath()
            ctx.restoreGState()
            let angle: CGFloat = msg.toX >= msg.fromX ? 0 : .pi
            drawMarker(msg.arrowHead, at: CGPoint(x: msg.toX, y: msg.y), angle: angle, in: ctx, palette: palette)
        }

        if !msg.labelLines.isEmpty {
            drawCenteredLines(
                msg.labelLines,
                in: msg.labelFrame,
                font: MermaidCoreTextMeasurer.font(for: .sequenceMessage),
                color: palette.nodeText,
                alignment: msg.isSelfMessage ? .left : .center,
                ctx: ctx
            )
        }
    }

    private static func drawSequenceNote(
        _ note: MermaidPositionedSequenceNote,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        let rect = note.frame
        let fold: CGFloat = 8
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()

        ctx.addPath(p)
        ctx.setFillColor(palette.noteFill.cgColor)
        ctx.fillPath()

        ctx.addPath(p)
        ctx.setStrokeColor(palette.noteBorder.cgColor)
        ctx.setLineWidth(1.1)
        ctx.strokePath()

        ctx.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        ctx.strokePath()

        drawCenteredLines(
            note.labelLines,
            in: rect.insetBy(dx: 8, dy: 4),
            font: MermaidCoreTextMeasurer.font(for: .sequenceNote),
            color: palette.nodeText,
            alignment: .center,
            ctx: ctx
        )
    }

    // MARK: - Pie Chart Drawing

    private static func drawPie(
        _ pie: MermaidPositionedPie,
        in ctx: CGContext,
        palette: MermaidThemePalette
    ) {
        if let title = pie.title, let titleCenter = pie.titleCenter {
            let box = CGRect(x: 16, y: titleCenter.y - 12, width: pie.size.width - 32, height: 24)
            drawCenteredLines(
                [title],
                in: box,
                font: MermaidCoreTextMeasurer.font(for: .pieTitle),
                color: palette.nodeText,
                alignment: .center,
                ctx: ctx
            )
        }

        for slice in pie.slices {
            let color = palette.sliceColors[slice.colorIndex % palette.sliceColors.count]
            let p = CGMutablePath()
            p.move(to: pie.center)
            p.addArc(
                center: pie.center,
                radius: pie.radius,
                startAngle: slice.startAngle,
                endAngle: slice.endAngle,
                clockwise: false
            )
            p.closeSubpath()

            ctx.addPath(p)
            ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
            ctx.fillPath()

            ctx.addPath(p)
            ctx.setStrokeColor(palette.nodeBorder.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }

        // Legend
        let legendFont = MermaidCoreTextMeasurer.font(for: .pieLegend)
        for (idx, slice) in pie.slices.enumerated() {
            let y = pie.legendOrigin.y + CGFloat(idx) * 22
            let swatchRect = CGRect(x: pie.legendOrigin.x, y: y + 4, width: 12, height: 12)
            let color = palette.sliceColors[slice.colorIndex % palette.sliceColors.count]
            let swatchPath = CGPath(roundedRect: swatchRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(swatchPath)
            ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
            ctx.fillPath()

            let pct = Int(slice.percentage.rounded())
            let valStr = slice.value.rounded() == slice.value ? String(Int(slice.value)) : String(format: "%.1f", slice.value)
            let text = pie.showData ? "\(slice.label) (\(valStr), \(pct)%)" : "\(slice.label) (\(pct)%)"
            drawCenteredLines(
                [text],
                in: CGRect(x: pie.legendOrigin.x + 18, y: y, width: pie.size.width - pie.legendOrigin.x - 28, height: 20),
                font: legendFont,
                color: palette.nodeText,
                alignment: .left,
                ctx: ctx
            )
        }
    }

    // MARK: - CoreText Drawing Helper

    private static func drawCenteredLines(
        _ lines: [String],
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        ctx: CGContext
    ) {
        guard !lines.isEmpty else { return }
        let lineHeight = ceil(font.ascender - font.descender + font.leading + 3)
        let totalTextHeight = CGFloat(lines.count) * lineHeight
        let startY = rect.midY - totalTextHeight / 2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        for (idx, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let attr = NSAttributedString(string: line, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))

            let x: CGFloat
            switch alignment {
            case .left:
                x = rect.minX
            case .right:
                x = rect.maxX - width
            default:
                x = rect.midX - width / 2
            }

            let lineCenterY = startY + (CGFloat(idx) + 0.5) * lineHeight
            let baselineY = lineCenterY + (ascent - descent) / 2

            ctx.saveGState()
            ctx.translateBy(x: x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }
}
