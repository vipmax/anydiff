import AppKit
import CoreGraphics

/// Direct vector renderer for Unicode Box-Drawing (U+2500...U+257F) and Block Elements (U+2580...U+259F).
/// Renders perfectly aligned, pixel-crisp borders without font metrics gaps.
enum TerminalBoxDrawingRenderer {
    /// Returns true if the character is a box-drawing or block element symbol that should be rendered via direct vectors.
    static func isBoxDrawingCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
        let val = scalar.value
        return (val >= 0x2500 && val <= 0x257F) || (val >= 0x2580 && val <= 0x259F)
    }

    /// Draws the character using direct CoreGraphics lines/fills inside the specified cell rectangle.
    static func draw(character: Character, in rect: CGRect, context: CGContext, color: NSColor) {
        guard let scalar = character.unicodeScalars.first else { return }
        let val = scalar.value

        context.saveGState()
        color.setFill()
        color.setStroke()

        let midX = rect.midX.rounded()
        let midY = rect.midY.rounded()
        let strokeWidth: CGFloat = max(1.0, (rect.width * 0.08).rounded())

        // 1. Block Elements (U+2580 ... U+259F)
        switch val {
        case 0x2588: // Full block █
            context.fill(rect)
            context.restoreGState()
            return
        case 0x2580: // Upper half block ▀
            let topRect = CGRect(x: rect.minX, y: midY, width: rect.width, height: rect.maxY - midY)
            context.fill(topRect)
            context.restoreGState()
            return
        case 0x2584: // Lower half block ▄
            let botRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: midY - rect.minY)
            context.fill(botRect)
            context.restoreGState()
            return
        case 0x258C: // Left half block ▌
            let leftRect = CGRect(x: rect.minX, y: rect.minY, width: midX - rect.minX, height: rect.height)
            context.fill(leftRect)
            context.restoreGState()
            return
        case 0x2590: // Right half block ▐
            let rightRect = CGRect(x: midX, y: rect.minY, width: rect.maxX - midX, height: rect.height)
            context.fill(rightRect)
            context.restoreGState()
            return
        default:
            break
        }

        // 2. Box Drawing (U+2500 ... U+257F)
        // Determine line directions: up, down, left, right
        var up = false
        var down = false
        var left = false
        var right = false

        switch val {
        case 0x2500, 0x2501: // ─, ━ (Horizontal)
            left = true; right = true
        case 0x2502, 0x2503: // │, ┃ (Vertical)
            up = true; down = true
        case 0x250C, 0x250D, 0x250E, 0x250F: // ┌, ┍, ┎, ┏ (Top-Left)
            down = true; right = true
        case 0x2510, 0x2511, 0x2512, 0x2513: // ┐, ┑, ┒, ┓ (Top-Right)
            down = true; left = true
        case 0x2514, 0x2515, 0x2516, 0x2517: // └, ┕, ┖, ┗ (Bottom-Left)
            up = true; right = true
        case 0x2518, 0x2519, 0x251A, 0x251B: // ┘, ┙, ┚, ┛ (Bottom-Right)
            up = true; left = true
        case 0x251C, 0x251D, 0x251E, 0x251F, 0x2520, 0x2521, 0x2522, 0x2523: // ├, ┝... (Vertical + Right)
            up = true; down = true; right = true
        case 0x2524, 0x2525, 0x2526, 0x2527, 0x2528, 0x2529, 0x252A, 0x252B: // ┤... (Vertical + Left)
            up = true; down = true; left = true
        case 0x252C, 0x252D, 0x252E, 0x252F, 0x2530, 0x2531, 0x2532, 0x2533: // ┬... (Horizontal + Down)
            left = true; right = true; down = true
        case 0x2534, 0x2535, 0x2536, 0x2537, 0x2538, 0x2539, 0x253A, 0x253B: // ┴... (Horizontal + Up)
            left = true; right = true; up = true
        case 0x253C, 0x253D, 0x253E, 0x253F, 0x2540, 0x2541, 0x2542, 0x2543, 0x2544, 0x2545, 0x2546, 0x2547, 0x2548, 0x2549, 0x254A, 0x254B: // ┼... (Cross)
            up = true; down = true; left = true; right = true
        case 0x2574: // ╴ (Left only)
            left = true
        case 0x2575: // ╵ (Up only)
            up = true
        case 0x2576: // ╶ (Right only)
            right = true
        case 0x2577: // ╷ (Down only)
            down = true
        default:
            context.restoreGState()
            return
        }

        context.setLineWidth(strokeWidth)
        context.setLineCap(.square)

        let halfStroke = strokeWidth / 2.0

        if left {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addLine(to: CGPoint(x: midX + halfStroke, y: midY))
            context.addPath(path)
            context.strokePath()
        }
        if right {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: midX - halfStroke, y: midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            context.addPath(path)
            context.strokePath()
        }
        if up {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: midX, y: midY - halfStroke))
            path.addLine(to: CGPoint(x: midX, y: rect.maxY))
            context.addPath(path)
            context.strokePath()
        }
        if down {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: midX, y: rect.minY))
            path.addLine(to: CGPoint(x: midX, y: midY + halfStroke))
            context.addPath(path)
            context.strokePath()
        }

        context.restoreGState()
    }
}
