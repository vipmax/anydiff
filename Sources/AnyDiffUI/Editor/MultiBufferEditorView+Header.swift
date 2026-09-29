import Foundation
import AppKit
import CoreText
import AnyDiffCore

extension MultiBufferEditorView {
    // MARK: - Sticky Excerpt Header Computation

    func currentStickyHeader() -> (info: ExcerptHeaderInfo, frame: CGRect)? {
        guard scrollOffsetY > 0, !cachedFileSections.isEmpty else { return nil }

        var low = 0
        var high = cachedFileSections.count - 1
        var candidateIdx: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if cachedFileSections[mid].headerMinY <= scrollOffsetY {
                candidateIdx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let idx = candidateIdx else { return nil }
        let section = cachedFileSections[idx]
        if scrollOffsetY > section.headerMinY && scrollOffsetY < section.contentMaxY {
            guard section.contentMaxY - section.headerMinY > excerptHeaderHeight else { return nil }

            let nextHeaderMinY: CGFloat? = (idx + 1 < cachedFileSections.count) ? cachedFileSections[idx + 1].headerMinY : nil

            var stickyScreenY: CGFloat = 0
            if let nextMinY = nextHeaderMinY {
                let nextScreenY = nextMinY - scrollOffsetY
                if nextScreenY < excerptHeaderHeight {
                    stickyScreenY = nextScreenY - excerptHeaderHeight
                }
            }
            let stickyFrame = CGRect(x: 0, y: stickyScreenY, width: bounds.width, height: excerptHeaderHeight)
            return (section.info, stickyFrame)
        }
        return nil
    }

    // MARK: - Excerpt Header Action Geometry

    func closeButtonRect(in headerRect: CGRect) -> CGRect {
        let size: CGFloat = 18
        let x: CGFloat = 26
        let y = headerRect.minY + (headerRect.height - size) / 2.0
        return CGRect(x: x, y: y, width: size, height: size)
    }

    func diffBadgesWidth(deletions: Int, additions: Int) -> CGFloat {
        var width: CGFloat = 0
        var hasDel = false
        if deletions > 0 {
            let delStr = NSAttributedString(string: "-\(deletions)", attributes: [.font: Self.badgeFont])
            let line = CTLineCreateWithAttributedString(delStr)
            width += CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            hasDel = true
        }
        if additions > 0 {
            let addStr = NSAttributedString(string: "+\(additions)", attributes: [.font: Self.badgeFont])
            let line = CTLineCreateWithAttributedString(addStr)
            width += CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if hasDel {
                width += 10.0 // badgeSpacing
            }
        }
        return width
    }

    func previewButtonRect(in headerRect: CGRect, for info: ExcerptHeaderInfo) -> CGRect {
        let btnWidth: CGFloat = 20
        let btnHeight: CGFloat = 20
        let rightMargin: CGFloat = 16
        let badgeW = diffBadgesWidth(deletions: info.deletions, additions: info.additions)
        let spacing: CGFloat = badgeW > 0 ? 8 : 0
        let x = bounds.width - rightMargin - badgeW - spacing - btnWidth
        let y = headerRect.minY + (headerRect.height - btnHeight) / 2.0 + 0.5
        return CGRect(x: x, y: y, width: btnWidth, height: btnHeight)
    }

    func previewButtonRect(in headerRect: CGRect) -> CGRect {
        let btnWidth: CGFloat = 20
        let btnHeight: CGFloat = 20
        let x: CGFloat = bounds.width - 16 - btnWidth
        let y = headerRect.minY + (headerRect.height - btnHeight) / 2.0 + 0.5
        return CGRect(x: x, y: y, width: btnWidth, height: btnHeight)
    }

    public func currentFocusedFilePath() -> String? {
        guard let dm = displayMap else { return nil }
        if let loc = dm.excerptLocation(for: cursorPoint) {
            return loc.filePath
        }
        if let (stickyInfo, _) = currentStickyHeader() {
            return stickyInfo.filePath
        }
        return dm.multiBuffer.excerpts.first?.filePath
    }

    // MARK: - Excerpt Header Drawing

    func drawExcerptHeader(info: ExcerptHeaderInfo, in rect: CGRect, isSticky: Bool = false, context: CGContext) {
        context.saveGState()

        let fullWidth = bounds.width
        let headerRect = CGRect(x: 0, y: rect.minY, width: fullWidth, height: rect.height)

        // 1. Header background spanning full width (always 100% opaque to prevent code bleed-through)
        context.setFillColor(theme.excerptHeaderBackground.cgColor)
        context.fill(headerRect)

        // 2. Strong, fast fade out for title, icon, and badges as soon as header starts being pushed
        let contentAlpha: CGFloat
        if isSticky && rect.minY < 0 {
            // Fades out completely within the first ~45% of being pushed
            let rawProgress = max(0, min(1, (rect.minY + rect.height * 0.45) / (rect.height * 0.45)))
            contentAlpha = pow(rawProgress, 2.0)
        } else {
            contentAlpha = 1.0
        }

        if contentAlpha <= 0.001 {
            context.restoreGState()
            return
        }

        context.saveGState()
        context.setAlpha(contentAlpha)

        // Smooth rounded vector chevron indicator matching native macOS
        let cx: CGFloat = 16
        let cy: CGFloat = rect.minY + (rect.height / 2)
        context.saveGState()
        context.setStrokeColor(theme.gutterForeground.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if info.isCollapsed {
            // chevron.right (>)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 2.5, y: cy - 4.5))
            context.addLine(to: CGPoint(x: cx + 2.5, y: cy))
            context.addLine(to: CGPoint(x: cx - 2.5, y: cy + 4.5))
            context.strokePath()
        } else {
            // chevron.down (v)
            context.beginPath()
            context.move(to: CGPoint(x: cx - 4.5, y: cy - 2.5))
            context.addLine(to: CGPoint(x: cx, y: cy + 2.5))
            context.addLine(to: CGPoint(x: cx + 4.5, y: cy - 2.5))
            context.strokePath()
        }
        context.restoreGState()

        // File Icon / Close Button on Hover
        let iconSize: CGFloat = 14
        let iconX: CGFloat = 28
        let iconY = rect.minY + (rect.height - iconSize) / 2.0
        let closeRect = closeButtonRect(in: headerRect)
        let isCloseHovered = (hoveredCloseFilePath == info.filePath)

        if isCloseHovered {
            // Subtle rounded hover background
            let bgRect = closeRect.insetBy(dx: 1, dy: 1)
            context.saveGState()
            context.setFillColor(theme.gutterForeground.withAlphaComponent(0.18).cgColor)
            let path = CGPath(roundedRect: bgRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

            // Close ✕
            context.saveGState()
            context.setStrokeColor(theme.foreground.cgColor)
            context.setLineWidth(1.4)
            context.setLineCap(.round)
            let cMidX = closeRect.midX
            let cMidY = closeRect.midY
            let d: CGFloat = 3.5
            context.beginPath()
            context.move(to: CGPoint(x: cMidX - d, y: cMidY - d))
            context.addLine(to: CGPoint(x: cMidX + d, y: cMidY + d))
            context.move(to: CGPoint(x: cMidX - d, y: cMidY + d))
            context.addLine(to: CGPoint(x: cMidX + d, y: cMidY - d))
            context.strokePath()
            context.restoreGState()
        } else {
            let icon = FileIconProvider.shared.image(for: info.filePath, pointSize: 12, weight: .medium)

            icon.draw(
                in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize),
                from: .zero,
                operation: .sourceOver,
                fraction: contentAlpha,
                respectFlipped: true,
                hints: nil
            )
        }

        // Title and Breadcrumbs Text
        let titleColor: NSColor
        switch info.fileStatus {
        case .added:
            titleColor = theme.diffAddedGutter
        case .deleted:
            titleColor = theme.diffDeletedGutter
        case .renamed:
            titleColor = theme.diffModifiedGutter
        default:
            titleColor = theme.foreground
        }

        let fileName = (info.filePath as NSString).lastPathComponent
        let dir = (info.filePath as NSString).deletingLastPathComponent

        let titleAttrString = NSMutableAttributedString()
        let fileNameAttr: [NSAttributedString.Key: Any] = [
            .font: Self.headerTitleFont,
            .foregroundColor: titleColor
        ]
        titleAttrString.append(NSAttributedString(string: fileName, attributes: fileNameAttr))

        if !dir.isEmpty && dir != "." {
            let dirAttr: [NSAttributedString.Key: Any] = [
                .font: Self.headerDirectoryFont,
                .foregroundColor: theme.gutterForeground
            ]
            titleAttrString.append(NSAttributedString(string: "  " + dir, attributes: dirAttr))
        }

        let ctLine = CTLineCreateWithAttributedString(titleAttrString)
        let titleWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let titleStartX: CGFloat = iconX + iconSize + 6
        let titleEndX = titleStartX + titleWidth

        // Diff Badges (+N -M) matching sidebar style and active theme
        var delLine: CTLine?
        var delWidth: CGFloat = 0
        if info.deletions > 0 {
            let delAttr: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: theme.diffDeletedGutter
            ]
            let delStr = NSAttributedString(string: "-\(info.deletions)", attributes: delAttr)
            let line = CTLineCreateWithAttributedString(delStr)
            delWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            delLine = line
        }

        var addLine: CTLine?
        var addWidth: CGFloat = 0
        if info.additions > 0 {
            let addAttr: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: theme.diffAddedGutter
            ]
            let addStr = NSAttributedString(string: "+\(info.additions)", attributes: addAttr)
            let line = CTLineCreateWithAttributedString(addStr)
            addWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            addLine = line
        }

        let isMarkdown = info.filePath.hasSuffix(".md") || info.filePath.hasSuffix(".markdown") || info.filePath.hasSuffix(".mdx")
        let badgeRightMargin: CGFloat = 16
        let badgeSpacing: CGFloat = 10
        var totalBadgeWidth: CGFloat = 0
        if delLine != nil { totalBadgeWidth += delWidth }
        if addLine != nil { totalBadgeWidth += addWidth }
        if delLine != nil && addLine != nil { totalBadgeWidth += badgeSpacing }

        let badgeStartX = bounds.width - badgeRightMargin - totalBadgeWidth
        let prevRect = previewButtonRect(in: headerRect, for: info)
        let rightElementsStartX = isMarkdown ? prevRect.minX : (totalBadgeWidth > 0 ? badgeStartX : bounds.width - badgeRightMargin)
        let minGap: CGFloat = 16
        let shouldDrawRightElements = rightElementsStartX >= titleEndX + minGap

        // Draw title
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: titleStartX, y: rect.minY + 22)
        context.scaleBy(x: 1.0, y: -1.0)
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Draw badges (pinned to right edge of viewport, hidden if title is too long)
        if shouldDrawRightElements && totalBadgeWidth > 0 {
            var rightBadgeX = bounds.width - badgeRightMargin

            if let delLine = delLine {
                rightBadgeX -= delWidth
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: rightBadgeX, y: rect.minY + 22)
                context.scaleBy(x: 1.0, y: -1.0)
                CTLineDraw(delLine, context)
                context.restoreGState()
                rightBadgeX -= badgeSpacing // Spacing between + and - badges
            }

            if let addLine = addLine {
                rightBadgeX -= addWidth
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: rightBadgeX, y: rect.minY + 22)
                context.scaleBy(x: 1.0, y: -1.0)
                CTLineDraw(addLine, context)
                context.restoreGState()
            }
        }

        if isMarkdown && shouldDrawRightElements {
            let isPrevHovered = (hoveredPreviewFilePath == info.filePath)

            // Only show subtle hover pill when mouse is over button, completely clear background by default
            if isPrevHovered {
                let bgPath = CGPath(roundedRect: prevRect.insetBy(dx: 1, dy: 1), cornerWidth: 4.0, cornerHeight: 4.0, transform: nil)
                context.saveGState()
                let bgAlpha: CGFloat = theme.isDark ? 0.18 : 0.10
                let bgBaseColor = theme.isDark ? NSColor.white : NSColor.black
                context.setFillColor(bgBaseColor.withAlphaComponent(bgAlpha).cgColor)
                context.addPath(bgPath)
                context.fillPath()
                context.restoreGState()
            }

            // Icon - clean, perfectly centered vertically and aligned with the badges
            let iconColor = isPrevHovered
                ? (theme.isDark ? NSColor.white : theme.foreground)
                : theme.foreground.withAlphaComponent(0.85)

            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
                .applying(.init(paletteColors: [iconColor]))

            if let img = Self.previewSymbolImage?.withSymbolConfiguration(symbolConfig) {
                let imgW = img.size.width
                let imgH = img.size.height
                let imgRect = CGRect(
                    x: round(prevRect.midX - imgW / 2.0),
                    y: round(prevRect.midY - imgH / 2.0),
                    width: imgW,
                    height: imgH
                )
                img.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: contentAlpha, respectFlipped: true, hints: nil)
            }
        }

        context.restoreGState() // Restore contentAlpha state
        context.restoreGState() // Restore outer header state
    }

}
