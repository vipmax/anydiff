import Foundation
import AppKit
import SwiftUI
import AnyDiffCore

extension MultiBufferEditorView {

    // MARK: - Cursor Visual Screen Rect

    public func cursorScreenRect() -> CGRect? {
        guard let dm = displayMap else { return nil }
        syncLayoutIfNeeded()
        guard let y = yOffset(for: cursorPoint.row) else { return nil }
        let screenY = y - scrollOffsetY

        let text = activeLineText(at: cursorPoint.row) ?? ""
        let clampedCol = min(text.count, max(0, cursorPoint.column))

        let codeStartX: CGFloat
        if dm.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: screenY, height: lineHeight)
            let baseX = splitActiveColumn == .left ? geom.leftCodeRect.minX : geom.rightCodeRect.minX
            codeStartX = baseX + Self.codeLeftPadding - scrollOffsetX
        } else {
            codeStartX = gutterWidth + Self.codeLeftPadding - scrollOffsetX
        }

        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        let xOffset = ctLine.xOffset(forCharacterIndex: clampedCol, in: text)
        let cursorX = codeStartX + xOffset

        return CGRect(x: cursorX, y: screenY, width: 2, height: lineHeight)
    }

    // MARK: - Trigger Completions

    public func showCompletions(triggerCharacter: String? = nil) {
        hideHover()
        guard editingEnabled, let dm = displayMap else { return }
        guard let loc = dm.fastSourceLocation(forCodeRow: cursorPoint.row) else { return }

        let filePath = loc.filePath
        let line = loc.lineNumber
        let col = cursorPoint.column + 1
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

        // Determine trigger point and initial prefix
        if let _ = triggerCharacter {
            completionTriggerPoint = cursorPoint
            completionPrefix = ""
            if let loc = dm.bufferLocation(for: cursorPoint) {
                completionTriggerBufferId = loc.buffer.id
                completionTriggerBufferRow = loc.point.row
                completionTriggerBufferCol = loc.point.column
            }
        } else {
            // Invoked via Ctrl+Space: find word prefix before cursor
            let text = activeLineText(at: cursorPoint.row) ?? ""
            let wordStart = findWordStartBeforeCursor(in: text, col: cursorPoint.column)
            completionTriggerPoint = MultiBufferPoint(row: cursorPoint.row, column: wordStart)
            if let loc = dm.bufferLocation(for: cursorPoint) {
                completionTriggerBufferId = loc.buffer.id
                completionTriggerBufferRow = loc.point.row
                completionTriggerBufferCol = wordStart
            }
            if wordStart <= cursorPoint.column {
                let u16Start = text.utf16Offset(forCharacterIndex: wordStart)
                let u16End = text.utf16Offset(forCharacterIndex: cursorPoint.column)
                let startIdx = text.utf16.index(text.startIndex, offsetBy: min(text.utf16.count, u16Start))
                let endIdx = text.utf16.index(text.startIndex, offsetBy: min(text.utf16.count, u16End))
                completionPrefix = String(text[startIdx..<endIdx])
            } else {
                completionPrefix = ""
            }
        }

        completionStateModel.selectedIndex = 0

        // If we already have active completions (e.g. cursor moved Left/Right), filter immediately
        if !activeCompletions.isEmpty {
            filterAndPresentCompletions()
        }

        completionTask?.cancel()
        completionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let items = try await LSPWorkspaceService.shared.getCompletions(
                    filePath: absFilePath,
                    line: line,
                    column: col,
                    rootPath: root,
                    triggerCharacter: triggerCharacter,
                    contentSupplier: contentSupplier
                )

                if Task.isCancelled { return }

                guard !items.isEmpty else {
                    self.hideCompletionMenu()
                    return
                }

                self.activeCompletions = items
                self.completionStateModel.selectedIndex = 0
                self.filterAndPresentCompletions()
            } catch {
                self.hideCompletionMenu()
            }
        }
    }

    private func findWordStartBeforeCursor(in text: String, col: Int) -> Int {
        let chars = Array(text)
        var i = min(col, chars.count)
        while i > 0 && isWordChar(chars[i - 1]) {
            i -= 1
        }
        return max(0, i)
    }

    public func currentPrefixAtCursor() -> String {
        let triggerCol: Int
        if let triggerBufId = completionTriggerBufferId,
           let triggerBufRow = completionTriggerBufferRow,
           let loc = displayMap?.bufferLocation(for: cursorPoint) {
            guard loc.buffer.id == triggerBufId && loc.point.row == triggerBufRow else { return "" }
            triggerCol = completionTriggerBufferCol ?? 0
        } else if let trigger = completionTriggerPoint {
            guard trigger.row == cursorPoint.row else { return "" }
            triggerCol = trigger.column
        } else {
            return ""
        }
        let text = activeLineText(at: cursorPoint.row) ?? ""
        let chars = Array(text)
        let start = min(triggerCol, chars.count)
        let end = min(max(start, cursorPoint.column), chars.count)
        return String(chars[start..<end])
    }

    public func updateCompletionsFilter() {
        guard !activeCompletions.isEmpty else { return }
        completionPrefix = currentPrefixAtCursor()
        filterAndPresentCompletions()
    }

    private func filterAndPresentCompletions() {
        let prefix = completionPrefix.lowercased()
        let filtered: [LSPCompletionItem]
        if prefix.isEmpty {
            filtered = activeCompletions
        } else {
            // Sort by: exact start with prefix, then contains, then sortText
            let matches = activeCompletions.compactMap { item -> (LSPCompletionItem, Int)? in
                let target = (item.filterText ?? item.label).lowercased()
                if target.hasPrefix(prefix) {
                    return (item, 0)
                } else if target.contains(prefix) {
                    return (item, 1)
                }
                return nil
            }
            filtered = matches.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                let s0 = $0.0.sortText ?? $0.0.label
                let s1 = $1.0.sortText ?? $1.0.label
                return s0 < s1
            }.map(\.0)
        }

        guard !filtered.isEmpty else {
            hideCompletionMenu()
            return
        }

        self.filteredCompletions = filtered
        self.completionStateModel.items = filtered
        self.completionStateModel.queryPrefix = completionPrefix
        self.completionStateModel.selectedIndex = min(completionStateModel.selectedIndex, filtered.count - 1)
        if self.completionStateModel.selectedIndex < 0 {
            self.completionStateModel.selectedIndex = 0
        }

        presentCompletionMenu()
    }

    private func presentCompletionMenu() {
        guard let cursorRect = cursorScreenRect() else { return }

        let popover: NSPopover
        if let existing = completionPopover {
            popover = existing
        } else {
            let p = NSPopover()
            p.animates = false
            p.behavior = .applicationDefined
            completionStateModel.onSelect = { [weak self] item in
                self?.confirmCompletion(item: item)
            }
            let hc = NSHostingController(rootView: CompletionMenuView(model: completionStateModel, theme: theme))
            p.contentViewController = hc
            completionPopover = p
            popover = p
        }

        popover.appearance = effectiveAppearance

        let menuHeight = CompletionMenuView.calculateHeight(itemCount: filteredCompletions.count)
        popover.contentSize = NSSize(width: CompletionMenuView.defaultWidth, height: menuHeight)

        if !popover.isShown {
            popover.show(relativeTo: cursorRect, of: self, preferredEdge: .maxY)
        } else {
            popover.positioningRect = cursorRect
        }

        alignCompletionPopover(popover, cursorRect: cursorRect)

        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self = self, let popover = popover, popover.isShown else { return }
            guard let rect = self.cursorScreenRect() else { return }
            self.alignCompletionPopover(popover, cursorRect: rect)
        }
    }

    public func updateCompletionMenuFrame() {
        guard let popover = completionPopover, !filteredCompletions.isEmpty else {
            completionPopover?.close()
            return
        }

        guard let cursorRect = cursorScreenRect() else {
            popover.close()
            return
        }

        // If cursor is scrolled outside visible viewport bounds, close completion popup
        if cursorRect.maxY < 0 || cursorRect.minY > bounds.height {
            popover.close()
            return
        }

        let menuHeight = CompletionMenuView.calculateHeight(itemCount: filteredCompletions.count)
        popover.contentSize = NSSize(width: CompletionMenuView.defaultWidth, height: menuHeight)

        if popover.isShown {
            popover.positioningRect = cursorRect
            alignCompletionPopover(popover, cursorRect: cursorRect)
        }
    }

    public func completionWordStartColumn() -> Int {
        if let triggerBufId = completionTriggerBufferId,
           let triggerBufRow = completionTriggerBufferRow,
           let loc = displayMap?.bufferLocation(for: cursorPoint),
           loc.buffer.id == triggerBufId && loc.point.row == triggerBufRow,
           let col = completionTriggerBufferCol {
            return col
        }
        if let trigger = completionTriggerPoint, trigger.row == cursorPoint.row {
            return trigger.column
        }
        let text = activeLineText(at: cursorPoint.row) ?? ""
        return findWordStartBeforeCursor(in: text, col: cursorPoint.column)
    }

    public func wordStartScreenRect() -> CGRect? {
        guard let dm = displayMap else { return nil }
        syncLayoutIfNeeded()
        guard let y = yOffset(for: cursorPoint.row) else { return nil }
        let screenY = y - scrollOffsetY

        let text = activeLineText(at: cursorPoint.row) ?? ""
        let wordCol = completionWordStartColumn()
        let clampedCol = min(text.count, max(0, wordCol))

        let codeStartX: CGFloat
        if dm.effectiveLayoutMode == .sideBySide {
            let geom = splitGeometry(atY: screenY, height: lineHeight)
            let baseX = splitActiveColumn == .left ? geom.leftCodeRect.minX : geom.rightCodeRect.minX
            codeStartX = baseX + Self.codeLeftPadding - scrollOffsetX
        } else {
            codeStartX = gutterWidth + Self.codeLeftPadding - scrollOffsetX
        }

        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attr)
        let xOffset = ctLine.xOffset(forCharacterIndex: clampedCol, in: text)
        let wordX = codeStartX + xOffset

        return CGRect(x: wordX, y: screenY, width: 2, height: lineHeight)
    }

    public func alignCompletionPopover(_ popover: NSPopover, cursorRect: CGRect) {
        guard let hostWindow = self.window,
              let popWindow = popover.contentViewController?.view.window else {
            return
        }

        let wordRect = wordStartScreenRect() ?? cursorRect

        let cursorPtInSelf = NSPoint(x: cursorRect.midX, y: cursorRect.minY)
        let wordStartPtInSelf = NSPoint(x: wordRect.minX, y: wordRect.minY)

        let screenCursorX = hostWindow.convertPoint(toScreen: convert(cursorPtInSelf, to: nil)).x
        let screenWordStartX = hostWindow.convertPoint(toScreen: convert(wordStartPtInSelf, to: nil)).x

        // Distance from popWindow.frame.origin.x to the beginning of the label in CompletionItemRow:
        // Window inset = 13 pt
        // ScrollView horizontal padding = 5 pt
        // Row horizontal padding = 8 pt
        // Badge width = 20 pt
        // Spacing between badge and label = 8 pt
        // Total = 13 + 5 + 8 + 20 + 8 = 54 pt
        let labelOffsetInPopWindow: CGFloat = 54.0

        var desiredOriginX = screenWordStartX - labelOffsetInPopWindow

        // Constraints:
        // 1. Popover arrow must stay on the flat top/bottom edge of popWindow
        let minArrowMargin: CGFloat = 28.0
        let maxOriginX = screenCursorX - minArrowMargin
        let minOriginX = screenCursorX - (popWindow.frame.width - minArrowMargin)
        desiredOriginX = max(minOriginX, min(maxOriginX, desiredOriginX))

        // 2. Popover window must stay within visible screen bounds
        let screen = popWindow.screen ?? hostWindow.screen ?? NSScreen.main
        if let screen = screen {
            let screenMinX = screen.visibleFrame.minX + 8.0
            let screenMaxX = screen.visibleFrame.maxX - 8.0 - popWindow.frame.width
            if screenMinX <= screenMaxX {
                desiredOriginX = max(screenMinX, min(screenMaxX, desiredOriginX))
            }
        }

        var f = popWindow.frame
        f.origin.x = round(desiredOriginX)
        popWindow.setFrame(f, display: true)
    }

    public func selectNextCompletion() {
        guard !filteredCompletions.isEmpty else { return }
        let next = (completionStateModel.selectedIndex + 1) % filteredCompletions.count
        completionStateModel.selectedIndex = next
    }

    public func selectPreviousCompletion() {
        guard !filteredCompletions.isEmpty else { return }
        let count = filteredCompletions.count
        let prev = (completionStateModel.selectedIndex - 1 + count) % count
        completionStateModel.selectedIndex = prev
    }

    public func confirmSelectedCompletion() {
        guard !filteredCompletions.isEmpty else { return }
        let idx = max(0, min(completionStateModel.selectedIndex, filteredCompletions.count - 1))
        let item = filteredCompletions[idx]
        confirmCompletion(item: item)
    }

    public func confirmCompletion(item: LSPCompletionItem) {
        guard editingEnabled, let _ = displayMap else { return }

        let textToInsert = item.sanitizedInsertText
        let startCol: Int
        if let triggerBufId = completionTriggerBufferId,
           let triggerBufRow = completionTriggerBufferRow,
           let loc = displayMap?.bufferLocation(for: cursorPoint),
           loc.buffer.id == triggerBufId && loc.point.row == triggerBufRow {
            startCol = completionTriggerBufferCol ?? cursorPoint.column
        } else if let trigger = completionTriggerPoint, trigger.row == cursorPoint.row {
            startCol = trigger.column
        } else {
            let text = activeLineText(at: cursorPoint.row) ?? ""
            startCol = findWordStartBeforeCursor(in: text, col: cursorPoint.column)
        }

        let startPoint = MultiBufferPoint(row: cursorPoint.row, column: max(0, startCol))
        let endPoint = cursorPoint

        // Select the range from start of prefix to cursor
        selectionAnchor = startPoint
        cursorPoint = endPoint

        hideCompletionMenu()

        // Replace with completion text using standard insertion pipeline
        insertText(textToInsert, replacementRange: NSRange(location: NSNotFound, length: 0), coalesceTyping: false)
        SoundFeedback.play(.completion)
    }

    public func moveCompletionCursorLeft() {
        moveCursorLeft(expandSelection: false)
        if isCompletionMenuVisible {
            completionStateModel.selectedIndex = 0
            showCompletions()
        }
    }

    public func moveCompletionCursorRight() {
        moveCursorRight(expandSelection: false)
        if isCompletionMenuVisible {
            completionStateModel.selectedIndex = 0
            showCompletions()
        }
    }

    public func hideCompletionMenu() {
        completionTask?.cancel()
        completionTask = nil
        completionPopover?.close()
        activeCompletions.removeAll(keepingCapacity: true)
        filteredCompletions.removeAll(keepingCapacity: true)
        completionTriggerPoint = nil
        completionTriggerBufferId = nil
        completionTriggerBufferRow = nil
        completionTriggerBufferCol = nil
        completionPrefix = ""
        completionStateModel.selectedIndex = 0
    }
}
