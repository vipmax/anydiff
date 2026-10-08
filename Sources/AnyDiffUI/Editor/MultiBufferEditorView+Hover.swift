import Foundation
import AppKit
import SwiftUI
import AnyDiffCore

extension MultiBufferEditorView {

    // MARK: - Token Screen Rect & Target Detection

    public struct HoverTargetInfo {
        public let rect: CGRect
        public let point: MultiBufferPoint
        public let word: String
    }

    public func hoverTarget(atDisplayLineIndex lineIdx: Int, screenX: CGFloat) -> HoverTargetInfo? {
        guard let dm = displayMap else { return nil }
        syncLayoutIfNeeded()
        guard lineIdx >= 0 && lineIdx < dm.displayLineCount,
              let displayLine = dm.displayLine(at: lineIdx) else { return nil }

        let text: String
        let language: String?
        let codeStartX: CGFloat
        let multiBufferRow: MultiBufferRow

        let lineY = yOffset(forDisplayLineIndex: lineIdx) - scrollOffsetY
        let lineH = lineHeight(forDisplayLineIndex: lineIdx)

        if dm.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: lineY, height: lineH)
            let isLeft = screenX < geom.dividerRect.minX
            guard case .splitCode(let splitInfo) = displayLine else { return nil }
            let cell = isLeft ? splitInfo.left : splitInfo.right
            guard let mbRow = (isLeft ? splitInfo.left.multiBufferRow : splitInfo.right.multiBufferRow) ?? cell.multiBufferRow else { return nil }
            multiBufferRow = mbRow
            text = cell.text
            language = splitInfo.language
            let baseX = isLeft ? geom.leftCodeRect.minX : geom.rightCodeRect.minX
            codeStartX = baseX + Self.codeLeftPadding - scrollOffsetX
        } else {
            guard case .code(let codeInfo) = displayLine else { return nil }
            multiBufferRow = codeInfo.multiBufferRow
            text = codeInfo.text
            language = codeInfo.language
            codeStartX = gutterWidth + Self.codeLeftPadding - scrollOffsetX
        }

        guard !text.isEmpty else { return nil }

        let ctLine = getOrCreateCTLine(for: lineIdx, text: text, language: language ?? "")
        let xOffsetInCode = max(0, screenX + scrollOffsetX - codeStartX)
        let col = ctLine.characterIndex(at: xOffsetInCode, in: text)

        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let clampedCol = min(chars.count - 1, max(0, col))

        // Only trigger hover on actual identifiers/words
        guard isWordChar(chars[clampedCol]) else { return nil }

        var startCol = clampedCol
        while startCol > 0 && isWordChar(chars[startCol - 1]) {
            startCol -= 1
        }
        var endCol = clampedCol
        while endCol < chars.count && isWordChar(chars[endCol]) {
            endCol += 1
        }

        let word = String(chars[startCol..<endCol])
        let startX = ctLine.xOffset(forCharacterIndex: startCol, in: text)
        let endX = ctLine.xOffset(forCharacterIndex: endCol, in: text)
        let tokenWidth = max(cachedCharWidth, endX - startX)
        let tokenRect = CGRect(x: codeStartX + startX, y: lineY, width: tokenWidth, height: lineH)

        return HoverTargetInfo(
            rect: tokenRect,
            point: MultiBufferPoint(row: multiBufferRow, column: clampedCol),
            word: word
        )
    }

    // MARK: - Hover Trigger & Request

    public func requestHover(at point: MultiBufferPoint, targetRect: CGRect) {
        guard let dm = displayMap else { return }
        guard let loc = dm.fastSourceLocation(forCodeRow: point.row) else { return }

        let filePath = loc.filePath
        let line = loc.lineNumber
        let col = point.column + 1
        let root = workspaceRootPath ?? FileManager.default.currentDirectoryPath
        let absFilePath = (filePath as NSString).isAbsolutePath ? filePath : (root as NSString).appendingPathComponent(filePath)

        let contentSupplier: () -> String = { [weak dm, weak self] in
            if let dm = dm, let content = dm.multiBuffer.fullFileContent(for: filePath, baseDirectory: self?.workspaceRootPath) {
                return content
            }
            if let disk = try? String(contentsOfFile: absFilePath, encoding: .utf8) {
                return disk
            }
            if let buf = dm?.multiBuffer.buffer(forFilePath: filePath) {
                return buf.text()
            }
            return ""
        }

        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let hover = try await LSPWorkspaceService.shared.getHover(
                    filePath: absFilePath,
                    line: line,
                    column: col,
                    rootPath: root,
                    contentSupplier: contentSupplier
                )

                if Task.isCancelled { return }

                guard let hover = hover, !hover.contents.isEmpty else {
                    self.hideHover()
                    return
                }

                // If completion menu popped up in the meantime, don't show hover
                if self.isCompletionMenuVisible {
                    return
                }

                self.activeHover = hover
                self.lastHoverPoint = point
                self.hoveredTokenScreenRect = targetRect
                self.presentHoverPopover(hover: hover, targetRect: targetRect)
            } catch {
                self.hideHover()
            }
        }
    }

    // MARK: - Popover Presentation

    public func presentHoverPopover(hover: LSPHover, targetRect: CGRect) {
        // If target rect is scrolled out of view, don't show
        if targetRect.maxY < 0 || targetRect.minY > bounds.height {
            hideHover()
            return
        }

        let onHoverChanged: (Bool) -> Void = { [weak self] isHovered in
            guard let self = self else { return }
            if !isHovered {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self, self.isHoverVisible else { return }
                    let mouseScreen = NSEvent.mouseLocation
                    if let popWin = self.hoverPopover?.contentViewController?.view.window {
                        let expanded = popWin.frame.insetBy(dx: -14, dy: -14)
                        if expanded.contains(mouseScreen) {
                            return
                        }
                    }
                    if let tokenRect = self.hoveredTokenScreenRect, let win = self.window {
                        let tokenScreen = win.convertToScreen(self.convert(tokenRect, to: nil))
                        if tokenScreen.insetBy(dx: -10, dy: -10).contains(mouseScreen) {
                            return
                        }
                    }
                    self.hideHover()
                }
            }
        }

        let popoverView = HoverPopoverView(hover: hover, theme: theme, onHoverChanged: onHoverChanged)

        // Measure true wrapped content height using unconstrained-scrollview contentView
        let measurementHC = NSHostingController(rootView: popoverView.contentView)
        let fitting = measurementHC.view.fittingSize
        let maxAllowedWidth: CGFloat = 560
        let targetWidth = max(160, min(maxAllowedWidth, ceil(fitting.width)))
        let trueSize = measurementHC.sizeThatFits(in: CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
        let contentHeight = max(28, min(320, ceil(trueSize.height)))
        let targetSize = CGSize(width: targetWidth, height: contentHeight)

        let hostingController = NSHostingController(rootView: popoverView)
        hostingController.preferredContentSize = targetSize

        let popover: NSPopover
        if let existing = hoverPopover {
            popover = existing
            popover.contentViewController = hostingController
        } else {
            let p = NSPopover()
            p.animates = false
            p.behavior = .applicationDefined
            p.contentViewController = hostingController
            hoverPopover = p
            popover = p
        }

        popover.contentSize = targetSize
        popover.appearance = effectiveAppearance

        if popover.isShown {
            popover.close()
        }
        popover.show(relativeTo: targetRect, of: self, preferredEdge: .minY)

        alignHoverPopoverToScreenToken(targetRect: targetRect)
        DispatchQueue.main.async { [weak self] in
            self?.alignHoverPopoverToScreenToken(targetRect: targetRect)
        }
    }

    private func alignHoverPopoverToScreenToken(targetRect: CGRect) {
        guard let popover = hoverPopover,
              popover.isShown,
              let popWin = popover.contentViewController?.view.window,
              let win = window else { return }

        let inWin = convert(targetRect, to: nil)
        let onScreen = win.convertToScreen(inWin)

        let deltaY: CGFloat
        if popWin.frame.midY >= onScreen.midY {
            // Popover is above token: bottom of popover touches top of token
            deltaY = onScreen.maxY - popWin.frame.minY
        } else {
            // Popover is below token: top of popover touches bottom of token
            deltaY = onScreen.minY - popWin.frame.maxY
        }

        if abs(deltaY) > 0.5 {
            var origin = popWin.frame.origin
            origin.y += deltaY
            popWin.setFrameOrigin(origin)
        }
    }

    public func hideHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverPopover?.close()
        activeHover = nil
        lastHoverPoint = nil
        hoveredTokenScreenRect = nil
    }

    public func isMouseInsideHoverPopoverOrBridge(mouseScreen: CGPoint = NSEvent.mouseLocation) -> Bool {
        guard let popoverWindow = hoverPopover?.contentViewController?.view.window else { return false }
        let popFrame = popoverWindow.frame.insetBy(dx: -16, dy: -16)
        if popFrame.contains(mouseScreen) {
            return true
        }

        // Hover bridge: the corridor connecting the hovered token to the popover window
        if let tokenRect = hoveredTokenScreenRect, let win = window {
            let tokenScreen = win.convertToScreen(convert(tokenRect, to: nil))
            let bridge = tokenScreen.union(popoverWindow.frame).insetBy(dx: -16, dy: -10)
            if bridge.contains(mouseScreen) {
                return true
            }
        }
        return false
    }

    // MARK: - Mouse Hover Handling

    public func handleMouseMovedForHover(at screenPoint: CGPoint) {
        // Don't show hover while completions menu is visible or while selecting
        if isCompletionMenuVisible || isDraggingSelection {
            hideHover()
            return
        }

        // If hover is already open, check if mouse moved outside token and outside popover
        if isHoverVisible {
            let mouseScreen = NSEvent.mouseLocation
            var isInsideToken = false
            if let tokenRect = hoveredTokenScreenRect {
                let slopRect = tokenRect.insetBy(dx: -10, dy: -10)
                if slopRect.contains(screenPoint) {
                    isInsideToken = true
                }
            }

            if isMouseInsideHoverPopoverOrBridge(mouseScreen: mouseScreen) {
                // Mouse is inside or transitioning into the popover window! Keep it active.
                hoverTimer?.invalidate()
                return
            }

            if !isInsideToken {
                hideHover()
            }
        }

        // Check if mouse moved slightly (jitter filtering)
        if let lastLoc = lastHoverMouseLocation {
            let dx = abs(screenPoint.x - lastLoc.x)
            let dy = abs(screenPoint.y - lastLoc.y)
            if dx < 3 && dy < 3 {
                return
            }
        }
        lastHoverMouseLocation = screenPoint

        hoverTimer?.invalidate()

        // Only start timer if inside editor bounds and not in gutter
        guard screenPoint.x >= gutterWidth, screenPoint.x <= bounds.width,
              screenPoint.y >= 0, screenPoint.y <= bounds.height,
              let dm = displayMap else {
            return
        }

        let docY = screenPoint.y + scrollOffsetY
        let lineIdx = lineIndex(atY: docY)
        guard lineIdx >= 0 && lineIdx < dm.displayLineCount else { return }

        guard let targetInfo = hoverTarget(atDisplayLineIndex: lineIdx, screenX: screenPoint.x) else {
            return
        }

        // Debounce: 250ms rest before fetching hover
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // При триггере проверяем: если зажата command, то hover
                guard NSEvent.modifierFlags.contains(.command) else { return }
                if self.isHoverVisible && self.lastHoverPoint == targetInfo.point {
                    return
                }
                self.requestHover(at: targetInfo.point, targetRect: targetInfo.rect)
            }
        }
    }

    // MARK: - Keyboard Hover Trigger

    public func showHoverAtCursor() {
        guard let dm = displayMap else { return }
        if let codeInfo = dm.codeInfo(for: cursorPoint.row) {
            let lineIdx = codeInfo.displayLineIndex
            let text = activeLineText(at: cursorPoint.row) ?? ""
            let chars = Array(text)
            let col = min(chars.count - 1, max(0, cursorPoint.column))

            let ctLine = getOrCreateCTLine(for: lineIdx, text: text, language: codeInfo.language)
            let xOffset = ctLine.xOffset(forCharacterIndex: col, in: text)
            let codeStartX = gutterWidth + Self.codeLeftPadding - scrollOffsetX
            let screenX = codeStartX + xOffset

            if let target = hoverTarget(atDisplayLineIndex: lineIdx, screenX: screenX) {
                requestHover(at: target.point, targetRect: target.rect)
                return
            }
        }

        if let cursorRect = cursorScreenRect() {
            requestHover(at: cursorPoint, targetRect: cursorRect)
        }
    }
}
