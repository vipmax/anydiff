import AppKit
import CoreText
import AnyDiffCore

public struct MermaidNodeAccent: Sendable {
    public let fill: NSColor
    public let stroke: NSColor
    public let headerFill: NSColor

    public init(fill: NSColor, stroke: NSColor, headerFill: NSColor) {
        self.fill = fill
        self.stroke = stroke
        self.headerFill = headerFill
    }
}

public struct MermaidThemePalette: Sendable {
    public let themeID: String
    public let isDark: Bool
    public let canvasBackground: NSColor
    public let nodeFill: NSColor
    public let nodeBorder: NSColor
    public let nodeText: NSColor
    public let headerFill: NSColor
    public let secondaryFill: NSColor
    public let edgeLine: NSColor
    public let edgeLabelFill: NSColor
    public let edgeLabelBorder: NSColor
    public let edgeLabelText: NSColor
    public let groupFill: NSColor
    public let groupHeaderFill: NSColor
    public let groupBorder: NSColor
    public let groupText: NSColor
    public let noteFill: NSColor
    public let noteBorder: NSColor
    public let activationFill: NSColor
    public let accent: NSColor
    public let sliceColors: [NSColor]
    public let nodeAccents: [MermaidNodeAccent]

    public func accentColors(at index: Int) -> MermaidNodeAccent {
        guard !nodeAccents.isEmpty else {
            return MermaidNodeAccent(fill: nodeFill, stroke: nodeBorder, headerFill: headerFill)
        }
        let safeIndex = ((index % nodeAccents.count) + nodeAccents.count) % nodeAccents.count
        return nodeAccents[safeIndex]
    }

    public init(theme: Theme) {
        self.themeID = theme.id
        self.isDark = theme.isDark

        let bg = Self.srgb(theme.background)
        let gutter = Self.srgb(theme.gutterBackground)
        let headerBg = Self.srgb(theme.excerptHeaderBackground)
        let border = Self.srgb(theme.excerptHeaderBorder)
        let fg = Self.srgb(theme.foreground)
        let mutedFg = Self.srgb(theme.gutterForeground)
        let accent = Self.srgb(theme.accentColor)

        let cardBg = theme.isDark ? Self.blend(bg, with: gutter, fraction: 0.28) : bg

        self.canvasBackground = .clear
        self.nodeFill = theme.isDark
            ? Self.blend(gutter, with: headerBg, fraction: 0.45)
            : Self.blend(bg, with: gutter, fraction: 0.35)
        self.nodeBorder = border.withAlphaComponent(theme.isDark ? 0.85 : 0.75)
        self.nodeText = fg
        self.headerFill = accent.withAlphaComponent(theme.isDark ? 0.22 : 0.14)
        self.secondaryFill = gutter.withAlphaComponent(theme.isDark ? 0.55 : 0.45)
        self.edgeLine = mutedFg.withAlphaComponent(theme.isDark ? 0.85 : 0.80)
        self.edgeLabelFill = cardBg
        self.edgeLabelBorder = border.withAlphaComponent(theme.isDark ? 0.25 : 0.22)
        self.edgeLabelText = fg.withAlphaComponent(0.92)
        self.groupFill = gutter.withAlphaComponent(theme.isDark ? 0.28 : 0.30)
        self.groupHeaderFill = gutter.withAlphaComponent(theme.isDark ? 0.65 : 0.55)
        self.groupBorder = border.withAlphaComponent(0.60)
        self.groupText = fg.withAlphaComponent(0.85)
        self.noteFill = Self.blend(cardBg, with: Self.srgb(theme.string), fraction: theme.isDark ? 0.16 : 0.12)
        self.noteBorder = Self.srgb(theme.string).withAlphaComponent(theme.isDark ? 0.70 : 0.65)
        self.activationFill = Self.blend(cardBg, with: accent, fraction: theme.isDark ? 0.26 : 0.18)
        self.accent = accent

        self.sliceColors = [
            accent,
            Self.srgb(theme.function),
            Self.srgb(theme.string),
            Self.srgb(theme.type),
            Self.srgb(theme.keyword),
            Self.srgb(theme.number),
            Self.srgb(theme.property)
        ]

        self.nodeAccents = Self.buildNodeAccents(theme: theme, surfaceBackground: cardBg)
    }

    private static func buildNodeAccents(theme: Theme, surfaceBackground: NSColor) -> [MermaidNodeAccent] {
        // Zed-style chromatic cycle: pull distinct theme syntax accents first, then fill up to 8 hues.
        let themeCandidates: [NSColor] = [
            srgb(theme.accentColor),
            srgb(theme.function),
            srgb(theme.number),
            srgb(theme.keyword),
            srgb(theme.type),
            srgb(theme.string),
            srgb(theme.property),
            srgb(theme.operator)
        ]
        let fallbackHues: [NSColor] = theme.isDark ? [
            NSColor(srgbRed: 0.38, green: 0.68, blue: 0.94, alpha: 1), // blue
            NSColor(srgbRed: 0.30, green: 0.78, blue: 0.80, alpha: 1), // cyan
            NSColor(srgbRed: 0.88, green: 0.54, blue: 0.28, alpha: 1), // orange
            NSColor(srgbRed: 0.72, green: 0.52, blue: 0.92, alpha: 1), // purple
            NSColor(srgbRed: 0.45, green: 0.78, blue: 0.46, alpha: 1), // green
            NSColor(srgbRed: 0.90, green: 0.45, blue: 0.64, alpha: 1), // pink
            NSColor(srgbRed: 0.86, green: 0.70, blue: 0.32, alpha: 1), // amber
            NSColor(srgbRed: 0.88, green: 0.42, blue: 0.42, alpha: 1)  // red/coral
        ] : [
            NSColor(srgbRed: 0.16, green: 0.45, blue: 0.82, alpha: 1),
            NSColor(srgbRed: 0.08, green: 0.56, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.80, green: 0.40, blue: 0.10, alpha: 1),
            NSColor(srgbRed: 0.54, green: 0.28, blue: 0.78, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.56, blue: 0.24, alpha: 1),
            NSColor(srgbRed: 0.76, green: 0.22, blue: 0.48, alpha: 1),
            NSColor(srgbRed: 0.70, green: 0.50, blue: 0.08, alpha: 1),
            NSColor(srgbRed: 0.76, green: 0.22, blue: 0.22, alpha: 1)
        ]

        var distinct: [NSColor] = []
        for candidate in themeCandidates + fallbackHues {
            guard isChromatic(candidate) else { continue }
            if !distinct.contains(where: { rgbDistance($0, candidate) < 0.18 }) {
                distinct.append(candidate)
            }
            if distinct.count >= 8 { break }
        }
        if distinct.isEmpty {
            distinct = fallbackHues
        }

        let fillFraction: CGFloat = theme.isDark ? 0.16 : 0.11
        let headerFraction: CGFloat = theme.isDark ? 0.26 : 0.18
        let strokeAlpha: CGFloat = theme.isDark ? 0.78 : 0.85

        return distinct.map { base in
            MermaidNodeAccent(
                fill: blend(surfaceBackground, with: base, fraction: fillFraction),
                stroke: base.withAlphaComponent(strokeAlpha),
                headerFill: blend(surfaceBackground, with: base, fraction: headerFraction)
            )
        }
    }

    private static func isChromatic(_ color: NSColor) -> Bool {
        let c = srgb(color)
        let maxC = max(c.redComponent, max(c.greenComponent, c.blueComponent))
        let minC = min(c.redComponent, min(c.greenComponent, c.blueComponent))
        return (maxC - minC) > 0.14
    }

    private static func rgbDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let ca = srgb(a)
        let cb = srgb(b)
        let dr = ca.redComponent - cb.redComponent
        let dg = ca.greenComponent - cb.greenComponent
        let db = ca.blueComponent - cb.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    private static func srgb(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func blend(_ a: NSColor, with b: NSColor, fraction: CGFloat) -> NSColor {
        let ca = srgb(a)
        let cb = srgb(b)
        let t = max(0, min(1, fraction))
        return NSColor(
            srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * t
        )
    }
}

public struct MermaidCoreTextMeasurer: MermaidTextMeasurer {
    public init() {}

    public static func font(for role: MermaidTextRole) -> NSFont {
        switch role {
        case .nodeHeader:
            return NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        case .nodeLabel, .sequenceParticipant:
            return NSFont.systemFont(ofSize: 12.5, weight: .medium)
        case .nodeDetail:
            return NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case .edgeLabel, .sequenceMessage, .sequenceNote:
            return NSFont.systemFont(ofSize: 11.5, weight: .medium)
        case .groupTitle:
            return NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        case .pieTitle:
            return NSFont.systemFont(ofSize: 14, weight: .semibold)
        case .pieLegend:
            return NSFont.systemFont(ofSize: 12, weight: .regular)
        }
    }

    public func measureText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> CGSize {
        wrapText(text, role: role, maxWidth: maxWidth).size
    }

    public func wrapText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> (lines: [String], size: CGSize) {
        let font = Self.font(for: role)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = ceil(font.ascender - font.descender + font.leading + 3)

        let rawParagraphs = text.components(separatedBy: "\n")
        var wrappedLines: [String] = []
        var maxMeasuredWidth: CGFloat = 0

        for paragraph in rawParagraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                wrappedLines.append("")
                continue
            }

            let singleWidth = ceil((trimmed as NSString).size(withAttributes: attrs).width)
            if singleWidth <= maxWidth {
                wrappedLines.append(trimmed)
                maxMeasuredWidth = max(maxMeasuredWidth, singleWidth)
                continue
            }

            let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var currentLine = ""
            for word in words {
                let candidate = currentLine.isEmpty ? word : "\(currentLine) \(word)"
                let w = ceil((candidate as NSString).size(withAttributes: attrs).width)
                if w <= maxWidth || currentLine.isEmpty {
                    currentLine = candidate
                } else {
                    let curW = ceil((currentLine as NSString).size(withAttributes: attrs).width)
                    maxMeasuredWidth = max(maxMeasuredWidth, curW)
                    wrappedLines.append(currentLine)
                    currentLine = word
                }
            }
            if !currentLine.isEmpty {
                let curW = ceil((currentLine as NSString).size(withAttributes: attrs).width)
                maxMeasuredWidth = max(maxMeasuredWidth, curW)
                wrappedLines.append(currentLine)
            }
        }

        if wrappedLines.isEmpty {
            wrappedLines = [""]
        }

        let totalHeight = max(lineHeight, CGFloat(wrappedLines.count) * lineHeight)
        return (wrappedLines, CGSize(width: ceil(maxMeasuredWidth), height: ceil(totalHeight)))
    }
}
