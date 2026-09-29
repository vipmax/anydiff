import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

/// Lightweight, non-interactive tool output used while the chat scrolling path
/// is being tuned. The expandable color card remains implemented below and can
/// be restored by flipping `usesSimpleToolCalls` in `AgentMessageCell`.
public final class AgentSimpleToolCallView: AgentFlippedView {
    private let textLabel = AgentStaticTextField(wrappingLabelWithString: "")
    private let text: NSAttributedString

    public init(item: ToolCallItem, theme: Theme) {
        let typeFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let titleFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let typeColor = NSColor(cgColor: theme.keyword.cgColor) ?? .controlAccentColor
        let titleColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        let detailColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: item.shortToolName, attributes: [
            .font: typeFont,
            .foregroundColor: typeColor,
            .paragraphStyle: paragraphStyle
        ]))
        result.append(NSAttributedString(string: "  ", attributes: [
            .font: detailFont,
            .foregroundColor: detailColor,
            .paragraphStyle: paragraphStyle
        ]))
        result.append(NSAttributedString(string: item.displayTitle, attributes: [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraphStyle
        ]))

        if let detail = item.descriptionText ?? item.summary, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: detailFont,
                .foregroundColor: detailColor,
                .paragraphStyle: paragraphStyle
            ]))
        }

        if item.status == .running {
            result.append(NSAttributedString(string: "\nRunning…", attributes: [
                .font: detailFont,
                .foregroundColor: detailColor,
                .paragraphStyle: paragraphStyle
            ]))
        } else if item.status == .failed {
            result.append(NSAttributedString(string: "\nFailed", attributes: [
                .font: detailFont,
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: paragraphStyle
            ]))
        }

        self.text = result
        super.init(frame: .zero)

        textLabel.attributedStringValue = result
        textLabel.isBezeled = false
        textLabel.drawsBackground = false
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.usesSingleLineMode = false
        addSubview(textLabel)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        let measured = measureAttributedTextHeight(text, maxWidth: max(50, width - 16))
        return min(58, max(20, measured + 2))
    }

    public func applyLayout(width: CGFloat) {
        let height = measureHeight(width: width)
        textLabel.frame = NSRect(x: 8, y: 2, width: max(50, width - 16), height: height - 2)
    }
}

public final class AgentDiffStatsButton: AgentFlippedView {
    private var trackingArea: NSTrackingArea?
    public let badgeLabel = AgentStaticTextField(labelWithString: "")
    public var onClick: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.alignment = .center
        badgeLabel.usesSingleLineMode = true
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.cell?.wraps = false
        badgeLabel.cell?.truncatesLastVisibleLine = false
        addSubview(badgeLabel)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.pointingHand.set()
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    public override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick?()
        }
    }

    public override func layout() {
        super.layout()
        badgeLabel.frame = NSRect(x: 4, y: 1, width: max(0, bounds.width - 8), height: bounds.height - 2)
    }
}

private final class ToolCardHeaderContainer: AgentFlippedView {
    var onHeaderClicked: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return }
        for sv in subviews where !sv.isHidden && sv.alphaValue > 0.01 {
            if (sv is AgentHoverButton || sv is AgentDiffStatsButton) && sv.frame.contains(pt) {
                return
            }
        }
        onHeaderClicked?()
    }
}

public final class AgentToolCardView: AgentFlippedView {
    public private(set) var item: ToolCallItem
    private var theme: Theme
    private var toolcallColorMode: ToolcallColorMode
    public var isExpanded: Bool = false
    public var onToggle: (() -> Void)?
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    private weak var parentCell: AgentMessageCell?
    private let headerContainer = ToolCardHeaderContainer()
    private let openInEditorButton = AgentHoverButton(frame: .zero)
    private let diffStatsButton = AgentDiffStatsButton()
    private let actionPillView = AgentFlippedView()
    private let actionIconView = NSImageView()
    private let actionTextLabel = AgentStaticTextField(labelWithString: "")
    private let titleLabel = AgentStaticTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let errorLabel = AgentStaticTextField(labelWithString: "")
    private let chevronImageView = NSImageView()
    private let descriptionLabel = AgentStaticTextField(wrappingLabelWithString: "")
    public let detailContainer = AgentFlippedView()
    private var virtualizedDetailView: MultiBufferEditorView?
    private var cachedDetailAttributedString: NSAttributedString?
    private var cachedDetailHeightWidth: CGFloat = -1
    private var cachedDetailHeight: CGFloat = 0
    private var cachedDescriptionHeightWidth: CGFloat = -1
    private var cachedDescriptionHeight: CGFloat = 0
    private var cachedLayoutWidth: CGFloat = -1
    private var cachedLayoutHeight: CGFloat = 0
    private var cachedTitleText: String?
    private var cachedTitleWidth: CGFloat = 0

    public init(
        item: ToolCallItem,
        theme: Theme,
        index: Int,
        parentCell: AgentMessageCell,
        toolcallColorMode: ToolcallColorMode = .full,
        initiallyExpanded: Bool = false
    ) {
        self.item = item
        self.theme = theme
        self.parentCell = parentCell
        self.toolcallColorMode = toolcallColorMode
        self.isExpanded = initiallyExpanded
        super.init(frame: .zero)
        setup(index: index, parentCell: parentCell)
        if initiallyExpanded {
            installVirtualizedDetailView()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var isEditToolCall: Bool {
        item.isEditToolCall
    }

    private func hunksFromParentMessage(for item: ToolCallItem) -> [DiffHunk]? {
        guard isEditToolCall else { return nil }
        guard let itemPath = item.path ?? (!item.displayTitle.isEmpty ? item.displayTitle : nil),
              !itemPath.isEmpty else {
            return nil
        }
        return parentCell?.parsedDiffHunks(for: itemPath)
    }

    private func hunkFromParentMessage(for item: ToolCallItem) -> DiffHunk? {
        hunksFromParentMessage(for: item)?.first
    }

    private var effectiveAdditionsCount: Int? {
        guard isEditToolCall else { return nil }
        if let files = parentCell?.message.editedFilesSummary?.files,
           let itemPath = item.path ?? (!item.displayTitle.isEmpty ? item.displayTitle : nil),
           let file = files.first(where: { $0.path == itemPath || $0.path.hasSuffix(itemPath) || itemPath.hasSuffix($0.path) }) {
            return file.additions
        }
        if let adds = item.additionsCount { return adds }
        return nil
    }

    private var effectiveDeletionsCount: Int? {
        guard isEditToolCall else { return nil }
        if let files = parentCell?.message.editedFilesSummary?.files,
           let itemPath = item.path ?? (!item.displayTitle.isEmpty ? item.displayTitle : nil),
           let file = files.first(where: { $0.path == itemPath || $0.path.hasSuffix(itemPath) || itemPath.hasSuffix($0.path) }) {
            return file.deletions
        }
        if let dels = item.deletionsCount { return dels }
        return nil
    }

    public var hasExpandableContent: Bool {
        hasExpandableContent(for: item)
    }

    private func hasExpandableContent(for item: ToolCallItem) -> Bool {
        if item.oldContent != nil || item.newContent != nil { return true }
        if item.shortToolName == "Edit" || item.shortToolName == "Create" {
            return hunksFromParentMessage(for: item) != nil
        }
        if item.shortToolName == "Run" { return true }
        if let cmd = item.command, !cmd.isEmpty { return true }
        if let out = item.output, !out.isEmpty { return true }
        if let sum = item.summary, !sum.isEmpty { return true }
        if let desc = item.descriptionText, !desc.isEmpty { return true }
        return false
    }

    private var hasDiffStats: Bool {
        (effectiveAdditionsCount ?? 0) > 0 || (effectiveDeletionsCount ?? 0) > 0
    }

    private var shouldShowOpenInEditorButton: Bool {
        hasExpandableContent && !hasDiffStats
    }



    public func canUpdateInPlace(with newItem: ToolCallItem) -> Bool {
        if item.id == newItem.id { return true }
        return item.toolName == newItem.toolName &&
            item.path == newItem.path &&
            item.command == newItem.command
    }

    public func update(item newItem: ToolCallItem, theme newTheme: Theme) {
        let titleChanged = item.displayTitle != newItem.displayTitle
        let (bgCol, fgCol, symbolName) = actionColorsAndSymbol(for: newItem.shortToolName)
        item = newItem
        theme = newTheme

        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        cachedDescriptionHeightWidth = -1
        cachedDescriptionHeight = 0
        cachedDetailHeightWidth = -1
        cachedDetailHeight = 0
        cachedDetailAttributedString = nil
        if titleChanged {
            cachedTitleText = nil
            cachedTitleWidth = 0
        }

        virtualizedDetailView?.removeFromSuperview()
        virtualizedDetailView = nil
        if isExpanded {
            installVirtualizedDetailView()
        }

        // Action badge update
        applyActionAppearance(background: bgCol, foreground: fgCol)
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        actionIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        actionTextLabel.stringValue = newItem.shortToolName

        titleLabel.stringValue = newItem.displayTitle
        titleLabel.textColor = NSColor(cgColor: newTheme.foreground.cgColor) ?? .textColor

        let descText = newItem.descriptionText?.isEmpty == false ? newItem.descriptionText : ((!hasExpandableContent(for: newItem)) ? (newItem.summary ?? newItem.output) : nil)
        if let description = descText, !description.isEmpty {
            descriptionLabel.stringValue = description
            descriptionLabel.font = (newItem.descriptionText?.isEmpty == false) ? NSFont.systemFont(ofSize: 11) : NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            descriptionLabel.textColor = (newItem.descriptionText?.isEmpty == false)
                ? (NSColor(cgColor: newTheme.foreground.cgColor)?.withAlphaComponent(0.85) ?? .textColor)
                : (NSColor(cgColor: newTheme.gutterForeground.cgColor) ?? .secondaryLabelColor)
            if descriptionLabel.superview == nil {
                addSubview(descriptionLabel)
            }
        } else {
            descriptionLabel.stringValue = ""
            descriptionLabel.removeFromSuperview()
        }

        // Diff stats (+ / -)
        let adds = effectiveAdditionsCount
        let dels = effectiveDeletionsCount
        if adds != nil || dels != nil {
            let statsAttr = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

            if let adds = adds, adds > 0 {
                statsAttr.append(NSAttributedString(string: "+\(adds)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemGreen : neutralToolColor
                ]))
            }
            if let dels = dels, dels > 0 {
                if statsAttr.length > 0 {
                    statsAttr.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                statsAttr.append(NSAttributedString(string: "-\(dels)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemRed : neutralToolColor
                ]))
            }

            if statsAttr.length > 0 {
                diffStatsButton.badgeLabel.attributedStringValue = statsAttr
                diffStatsButton.isHidden = false
                if diffStatsButton.superview == nil {
                    headerContainer.addSubview(diffStatsButton)
                }
            } else {
                diffStatsButton.isHidden = true
                diffStatsButton.removeFromSuperview()
            }
        } else {
            diffStatsButton.isHidden = true
            diffStatsButton.removeFromSuperview()
        }

        if let progressIndicator = headerContainer.subviews.compactMap({ $0 as? NSProgressIndicator }).first {
            progressIndicator.isHidden = newItem.status != .running
            if newItem.status == .running {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
        }
        if newItem.status == .failed {
            errorLabel.stringValue = "✕"
            if errorLabel.superview == nil {
                headerContainer.addSubview(errorLabel)
            }
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        if hasExpandableContent {
            let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            chevronImageView.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(chevConfig)
            chevronImageView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.8) ?? .secondaryLabelColor
            chevronImageView.imageScaling = .scaleProportionallyDown
            if chevronImageView.superview == nil {
                headerContainer.addSubview(chevronImageView)
            }
            if shouldShowOpenInEditorButton {
                openInEditorButton.alphaValue = 0.65
                openInEditorButton.isHidden = false
                if openInEditorButton.superview == nil {
                    headerContainer.addSubview(openInEditorButton)
                }
            } else {
                openInEditorButton.isHidden = true
                openInEditorButton.removeFromSuperview()
            }
        } else {
            chevronImageView.removeFromSuperview()
            openInEditorButton.removeFromSuperview()
        }

        applyCardAppearance(foreground: fgCol, isRunning: newItem.status == .running)
    }

    private func setup(index: Int, parentCell: AgentMessageCell) {
        // Action badge (pill with SF Symbol + text)
        let (bgCol, fgCol, symbolName) = actionColorsAndSymbol(for: item.shortToolName)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        applyCardAppearance(foreground: fgCol, isRunning: item.status == .running)

        // Header Container
        headerContainer.wantsLayer = true
        headerContainer.layerContentsRedrawPolicy = .onSetNeedsDisplay
        headerContainer.onHeaderClicked = { [weak self] in
            self?.headerClicked()
        }
        addSubview(headerContainer)

        actionPillView.wantsLayer = true
        actionPillView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyActionAppearance(background: bgCol, foreground: fgCol)
        actionPillView.layer?.cornerRadius = 6

        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        actionIconView.wantsLayer = true
        actionIconView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        actionIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        actionIconView.imageScaling = .scaleProportionallyDown
        actionPillView.addSubview(actionIconView)

        actionTextLabel.stringValue = item.shortToolName
        actionTextLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        actionTextLabel.usesSingleLineMode = true
        actionTextLabel.lineBreakMode = .byClipping
        actionTextLabel.isBezeled = false
        actionTextLabel.drawsBackground = false
        actionTextLabel.isEditable = false
        actionTextLabel.isSelectable = false
        actionPillView.addSubview(actionTextLabel)

        headerContainer.addSubview(actionPillView)

        // Title
        titleLabel.stringValue = item.displayTitle
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.truncatesLastVisibleLine = true
        headerContainer.addSubview(titleLabel)

        // Diff stats (+ / -)
        let adds = effectiveAdditionsCount
        let dels = effectiveDeletionsCount
        if adds != nil || dels != nil {
            let statsAttr = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

            if let adds = adds, adds > 0 {
                statsAttr.append(NSAttributedString(string: "+\(adds)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemGreen : neutralToolColor
                ]))
            }
            if let dels = dels, dels > 0 {
                if statsAttr.length > 0 {
                    statsAttr.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                statsAttr.append(NSAttributedString(string: "-\(dels)", attributes: [
                    .font: font,
                    .foregroundColor: shouldColorEditStats ? NSColor.systemRed : neutralToolColor
                ]))
            }

            if statsAttr.length > 0 {
                diffStatsButton.badgeLabel.attributedStringValue = statsAttr
                diffStatsButton.isHidden = false
                diffStatsButton.onClick = { [weak self] in
                    self?.diffStatsClicked()
                }
                headerContainer.addSubview(diffStatsButton)
            }
        }

        // Status indicator: spinner when running, ✕ when failed, none when completed
        switch item.status {
        case .running:
            progressIndicator.style = .spinning
            progressIndicator.controlSize = .small
            progressIndicator.startAnimation(nil)
            headerContainer.addSubview(progressIndicator)
        case .failed:
            errorLabel.stringValue = "✕"
            errorLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            errorLabel.textColor = isFullColorMode ? .systemRed : neutralToolColor
            errorLabel.isBezeled = false
            errorLabel.drawsBackground = false
            errorLabel.isEditable = false
            errorLabel.isSelectable = false
            headerContainer.addSubview(errorLabel)
        case .completed:
            break
        }

        // Chevron
        if hasExpandableContent {
            let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
            chevronImageView.wantsLayer = true
            chevronImageView.layerContentsRedrawPolicy = .onSetNeedsDisplay
            chevronImageView.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(chevConfig)
            chevronImageView.contentTintColor = NSColor(cgColor: theme.gutterForeground.cgColor)?.withAlphaComponent(0.8) ?? .secondaryLabelColor
            chevronImageView.imageScaling = .scaleProportionallyDown
            headerContainer.addSubview(chevronImageView)
        }

        // Open the complete tool buffer in the main Review editor.
        if shouldShowOpenInEditorButton {
            openInEditorButton.isBordered = false
            openInEditorButton.title = ""
            openInEditorButton.imagePosition = .imageOnly
            openInEditorButton.image = NSImage(
                systemSymbolName: "arrow.left",
                accessibilityDescription: "Open in editor"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            openInEditorButton.contentTintColor = (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
                .withAlphaComponent(0.7)
            openInEditorButton.imageScaling = .scaleProportionallyDown
            openInEditorButton.target = self
            openInEditorButton.action = #selector(openInEditorClicked)
            openInEditorButton.alphaValue = 0.65
            openInEditorButton.isHidden = false
            headerContainer.addSubview(openInEditorButton)
        }

        // Description
        let descText = item.descriptionText?.isEmpty == false ? item.descriptionText : ((!hasExpandableContent) ? (item.summary ?? item.output) : nil)
        if let desc = descText, !desc.isEmpty {
            descriptionLabel.stringValue = desc
            descriptionLabel.font = (item.descriptionText?.isEmpty == false) ? NSFont.systemFont(ofSize: 11) : NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            descriptionLabel.textColor = (item.descriptionText?.isEmpty == false)
                ? (NSColor(cgColor: theme.foreground.cgColor)?.withAlphaComponent(0.85) ?? .textColor)
                : (NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor)
            addSubview(descriptionLabel)
        }

        // Detail Container
        if hasExpandableContent {
            detailContainer.wantsLayer = true
            detailContainer.layerContentsRedrawPolicy = .onSetNeedsDisplay
            detailContainer.layer?.backgroundColor = NSColor.clear.cgColor
            detailContainer.layer?.cornerRadius = 8
            detailContainer.layer?.borderWidth = 0
            detailContainer.layer?.borderColor = NSColor.clear.cgColor
            detailContainer.layer?.masksToBounds = true

            if isExpanded {
                addSubview(detailContainer)
                installVirtualizedDetailView()
            }
        }
    }

    @objc private func headerClicked() {
        guard hasExpandableContent else { return }
        isExpanded.toggle()
        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        cachedDetailHeightWidth = -1
        cachedDetailHeight = 0
        if isExpanded {
            if detailContainer.superview == nil {
                addSubview(detailContainer)
            }
            installVirtualizedDetailView()
        } else {
            detailContainer.removeFromSuperview()
        }
        let chevConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
        chevronImageView.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(chevConfig)
        onToggle?()
    }

    @objc private func diffStatsClicked() {
        var summary = item.createEditedFilesSummary()
        if summary?.rawDiffData == nil, let parentDiff = parentCell?.message.editedFilesSummary?.rawDiffData {
            if let p = item.path ?? (item.shortToolName == "Edit" ? item.displayTitle : nil), !p.isEmpty {
                let parsed = parentCell?.parsedDiffFiles() ?? GitDiffParser.shared.parse(data: parentDiff)
                if parsed.contains(where: {
                    let path = $0.displayPath
                    return path == p || path.hasSuffix(p) || p.hasSuffix(path)
                }) {
                    summary = AgentEditedFilesSummary(
                        files: [AgentEditedFileItem(path: p, additions: effectiveAdditionsCount ?? 0, deletions: effectiveDeletionsCount ?? 0)],
                        baseCommitHash: parentCell?.message.editedFilesSummary?.baseCommitHash,
                        rawDiffData: parentDiff
                    )
                }
            }
        }
        guard let finalSummary = summary else { return }
        onReview?(finalSummary)
    }

    @objc private func openInEditorClicked() {
        let content = virtualizedDetailContent()
        guard !content.lines.isEmpty else { return }

        let path = item.path ?? "agent/\(item.shortToolName.lowercased())-\(item.id.prefix(8)).txt"

        let summary = AgentEditedFilesSummary(
            files: [AgentEditedFileItem(path: path, additions: 0, deletions: 0)],
            rawTextData: Data(content.lines.joined(separator: "\n").utf8),
            contentMode: .text
        )
        onReview?(summary)
    }

    private func installVirtualizedDetailView() {
        guard virtualizedDetailView == nil else { return }

        let multiBuffer = MultiBuffer()
        let editorPath = item.path ?? item.displayTitle
        let language = Buffer.detectLanguage(for: editorPath)

        // 1. Prefer Git diff hunks from parent message if available (exact match with main review diff)
        if (item.shortToolName == "Edit" || item.shortToolName == "Create"),
           let parentHunks = hunksFromParentMessage(for: item), !parentHunks.isEmpty {
            multiBuffer.setContentMode(.diff)
            for (hIdx, hunk) in parentHunks.enumerated() {
                let startLine = hunk.newRange.lowerBound
                let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                let buffer = Buffer(
                    filePath: editorPath,
                    lines: newFileLines,
                    language: language,
                    baselineLines: oldBaselineLines,
                    startLineNumber: startLine,
                    diskFileLineCount: newFileLines.count
                )
                multiBuffer.addBuffer(buffer)
                multiBuffer.addExcerpt(Excerpt(
                    bufferId: buffer.id,
                    filePath: buffer.filePath,
                    fileStatus: .modified,
                    bufferRange: 0..<buffer.lineCount,
                    hunk: hunk,
                    isFileStart: hIdx == 0
                ))
            }
        } else if let new = item.newContent, let old = item.oldContent {
            // 2. Diff old and new content with real hunks and context lines
            let oLines = old.components(separatedBy: "\n")
            let nLines = new.components(separatedBy: "\n")
            let hunks = LineDiffEngine.shared.diff(oldLines: oLines, newLines: nLines, contextLines: 3, enablePrefixSuffixPruning: false)
            if !hunks.isEmpty {
                multiBuffer.setContentMode(.diff)
                for (hIdx, hunk) in hunks.enumerated() {
                    let startLine = hunk.newRange.lowerBound
                    let newFileLines = hunk.lines.filter { $0.kind == .added || $0.kind == .unchanged }.map(\.text)
                    let oldBaselineLines = hunk.lines.filter { $0.kind == .deleted || $0.kind == .unchanged }.map(\.text)
                    let buffer = Buffer(
                        filePath: editorPath,
                        lines: newFileLines,
                        language: language,
                        baselineLines: oldBaselineLines,
                        startLineNumber: startLine,
                        diskFileLineCount: newFileLines.count
                    )
                    multiBuffer.addBuffer(buffer)
                    multiBuffer.addExcerpt(Excerpt(
                        bufferId: buffer.id,
                        filePath: buffer.filePath,
                        fileStatus: .modified,
                        bufferRange: 0..<buffer.lineCount,
                        hunk: hunk,
                        isFileStart: hIdx == 0
                    ))
                }
            } else {
                // When there are no differences (e.g. identical content / no-op edit),
                // display the file as normal plain text without diff markings
                let lines = nLines.isEmpty ? [""] : nLines
                let buffer = Buffer(
                    filePath: editorPath,
                    lines: lines,
                    language: language,
                    baselineLines: [],
                    startLineNumber: 1,
                    diskFileLineCount: lines.count
                )
                multiBuffer.setContentMode(.text)
                multiBuffer.addBuffer(buffer)
                multiBuffer.addExcerpt(Excerpt(
                    bufferId: buffer.id,
                    filePath: buffer.filePath,
                    fileStatus: .unmodified,
                    bufferRange: 0..<buffer.lineCount,
                    hunk: nil,
                    isFileStart: true
                ))
            }
        } else {
            // 3. Fallback for command outputs, tool summaries, single texts
            let content = virtualizedDetailContent()
            let buffer = Buffer(
                filePath: editorPath,
                lines: content.lines,
                language: language,
                baselineLines: content.hunk == nil ? [] : nil,
                startLineNumber: 1,
                diskFileLineCount: content.lines.count
            )
            multiBuffer.setContentMode(content.hunk == nil ? .text : .diff)
            multiBuffer.addBuffer(buffer)
            multiBuffer.addExcerpt(Excerpt(
                bufferId: buffer.id,
                filePath: buffer.filePath,
                fileStatus: .modified,
                bufferRange: 0..<buffer.lineCount,
                hunk: content.hunk,
                isFileStart: true
            ))
        }

        let displayMap = DisplayMap(
            multiBuffer: multiBuffer,
            reviewManager: ReviewManager(),
            showsExcerptHeaders: false
        )
        let editor = MultiBufferEditorView(displayMap: displayMap, theme: displayTheme)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 8
        editor.layer?.masksToBounds = true
        editor.contentCornerRadius = 8
        editor.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        editor.isEditable = false
        editor.ignoreEdits = true
        editor.invalidateLayout()

        detailContainer.addSubview(editor)
        virtualizedDetailView = editor
        cachedDetailHeightWidth = -1
        cachedDetailHeight = 0
    }

    private func virtualizedDetailContent() -> (lines: [String], hunk: DiffHunk?) {
        if (item.shortToolName == "Edit" || item.shortToolName == "Create"),
           let parentHunks = hunksFromParentMessage(for: item), let firstHunk = parentHunks.first {
            let lines = firstHunk.lines.filter { $0.kind != .deleted }.map(\.text)
            return (lines.isEmpty ? [""] : lines, firstHunk)
        }

        if let new = item.newContent, let old = item.oldContent {
            let oLines = old.components(separatedBy: "\n")
            let nLines = new.components(separatedBy: "\n")
            let hunks = LineDiffEngine.shared.diff(oldLines: oLines, newLines: nLines, contextLines: 3, enablePrefixSuffixPruning: false)
            if let firstHunk = hunks.first {
                let lines = firstHunk.lines.filter { $0.kind != .deleted }.map(\.text)
                return (lines.isEmpty ? [""] : lines, firstHunk)
            }
            return (nLines.isEmpty ? [""] : nLines, nil)
        }

        if let new = item.newContent {
            let lines = new.components(separatedBy: "\n")
            return (lines.isEmpty ? [""] : lines, nil)
        }
        if let old = item.oldContent {
            let lines = old.components(separatedBy: "\n")
            return (lines.isEmpty ? [""] : lines, nil)
        }

        // Fallback for file edits when old/new content wasn't captured directly:
        // Attempt to extract hunk from parent message's rawDiffData
        if item.shortToolName == "Edit" || item.shortToolName == "Create" {
            if let parentHunk = hunkFromParentMessage(for: item) {
                let lines = parentHunk.lines.filter { $0.kind != .deleted }.map(\.text)
                return (lines.isEmpty ? [""] : lines, parentHunk)
            }
        }

        var lines: [String] = []
        if lines.isEmpty {
            if let command = item.command, !command.isEmpty {
                lines.append("$ \(command)")
            } else if item.shortToolName == "Run", !item.displayTitle.isEmpty {
                lines.append("$ \(item.displayTitle)")
            }
            if item.shortToolName != "Edit" && item.shortToolName != "Create" {
                if let output = item.output, !output.isEmpty {
                    let boundedOutput = output.count > 200_000
                        ? String(output.prefix(180_000)) + "\n\n... output truncated ...\n"
                        : output
                    lines.append(contentsOf: boundedOutput.components(separatedBy: "\n"))
                }
            }
        }

        if lines.isEmpty, item.shortToolName != "Edit" && item.shortToolName != "Create" {
            if let summary = item.summary, !summary.isEmpty {
                lines = summary.components(separatedBy: "\n")
            }
            if lines.isEmpty, let description = item.descriptionText, !description.isEmpty {
                lines = description.components(separatedBy: "\n")
            }
        }
        return (lines.isEmpty ? [""] : lines, nil)
    }

    private func actionColorsAndSymbol(for name: String) -> (bg: NSColor, fg: NSColor, symbol: String) {
        if toolcallColorMode == .none {
            let symbol: String
            switch name {
            case "Edit": symbol = "pencil"
            case "Create": symbol = "doc.badge.plus"
            case "Run": symbol = "terminal"
            case "Search": symbol = "magnifyingglass"
            case "Read": symbol = "doc.text"
            default: symbol = "gearshape"
            }
            return (.clear, neutralToolColor, symbol)
        }

        switch name {
        case "Edit":
            return (NSColor.systemOrange.withAlphaComponent(0.24), .systemOrange, "pencil")
        case "Create":
            return (NSColor.systemBlue.withAlphaComponent(0.24), .systemBlue, "doc.badge.plus")
        case "Run":
            return (NSColor.systemPurple.withAlphaComponent(0.24), .systemPurple, "terminal")
        case "Search":
            return (NSColor.systemYellow.withAlphaComponent(0.24), .systemYellow, "magnifyingglass")
        case "Read":
            return (NSColor.systemTeal.withAlphaComponent(0.24), .systemTeal, "doc.text")
        default:
            return (NSColor.systemGray.withAlphaComponent(0.24), .systemGray, "gearshape")
        }
    }

    private var neutralToolColor: NSColor {
        NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor
    }

    private var isFullColorMode: Bool {
        toolcallColorMode == .full
    }

    private var shouldColorEditStats: Bool {
        isFullColorMode || item.shortToolName == "Edit"
    }

    private var showsBadgeBackground: Bool {
        toolcallColorMode == .badge || toolcallColorMode == .full
    }

    private var showsActionIconColor: Bool {
        toolcallColorMode != .none
    }

    private var showsActionLabelColor: Bool {
        toolcallColorMode == .label || showsBadgeBackground
    }

    private func applyActionAppearance(background: NSColor, foreground: NSColor) {
        actionPillView.layer?.backgroundColor = showsBadgeBackground
            ? background.cgColor
            : NSColor.clear.cgColor
        actionIconView.contentTintColor = showsActionIconColor ? foreground : neutralToolColor
        actionTextLabel.textColor = showsActionLabelColor ? foreground : neutralToolColor
    }

    private var displayTheme: Theme {
        isFullColorMode ? theme : theme.monochromeForAgent
    }

    private func applyCardAppearance(foreground: NSColor, isRunning: Bool) {
        layer?.removeAnimation(forKey: "pulseBg")
        layer?.removeAnimation(forKey: "pulseBorder")

        if !isFullColorMode {
            layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            return
        }

        // Temporarily keep toolcall cards borderless in every color mode.
        layer?.borderWidth = 0
        if isRunning {
            layer?.backgroundColor = foreground.withAlphaComponent(0.08).cgColor
            layer?.borderColor = foreground.withAlphaComponent(0.26).cgColor

            let pulseBg = CABasicAnimation(keyPath: "backgroundColor")
            pulseBg.fromValue = foreground.withAlphaComponent(0.07).cgColor
            pulseBg.toValue = foreground.withAlphaComponent(0.22).cgColor
            pulseBg.duration = 0.95
            pulseBg.autoreverses = true
            pulseBg.repeatCount = .infinity
            pulseBg.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulseBg, forKey: "pulseBg")

            let pulseBorder = CABasicAnimation(keyPath: "borderColor")
            pulseBorder.fromValue = foreground.withAlphaComponent(0.24).cgColor
            pulseBorder.toValue = foreground.withAlphaComponent(0.60).cgColor
            pulseBorder.duration = 0.95
            pulseBorder.autoreverses = true
            pulseBorder.repeatCount = .infinity
            pulseBorder.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulseBorder, forKey: "pulseBorder")
        } else {
            layer?.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
            layer?.borderColor = foreground.withAlphaComponent(0.32).cgColor
        }
    }

    private func detailAttributedString() -> NSAttributedString {
        if let cachedDetailAttributedString {
            return cachedDetailAttributedString
        }

        let result = NSMutableAttributedString()
        let language = Buffer.detectLanguage(for: item.path ?? item.displayTitle)
        let renderTheme = displayTheme
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5

        if item.oldContent != nil || item.newContent != nil {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            // Diff semantics stay visible in every toolcall color mode.
            let redColor = NSColor.systemRed.withAlphaComponent(0.92)
            let redBg = NSColor.systemRed.withAlphaComponent(0.12)
            let greenColor = NSColor.systemGreen.withAlphaComponent(0.92)
            let greenBg = NSColor.systemGreen.withAlphaComponent(0.12)

            if let old = item.oldContent, !old.isEmpty {
                let lines = old.components(separatedBy: "\n")
                let displayLines = lines.prefix(350)
                for (lIdx, line) in displayLines.enumerated() {
                    let prefix = NSAttributedString(string: "- ", attributes: [
                        .font: font,
                        .foregroundColor: redColor,
                        .backgroundColor: redBg,
                        .paragraphStyle: style
                    ])
                    let highlighted = lIdx < 150 ? SyntaxHighlighter.shared.highlight(line: line, language: language, font: font, theme: renderTheme) : NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: redColor])
                    let lineAttr = NSMutableAttributedString(attributedString: highlighted)
                    let range = NSRange(location: 0, length: lineAttr.length)
                    lineAttr.addAttribute(NSAttributedString.Key.backgroundColor, value: redBg, range: range)
                    lineAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: range)

                    result.append(prefix)
                    result.append(lineAttr)
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .backgroundColor: redBg,
                        .paragraphStyle: style
                    ]))
                }
                if lines.count > 350 {
                    result.append(NSAttributedString(string: "... (\(lines.count - 350) more deleted lines truncated)\n", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
            if let new = item.newContent, !new.isEmpty {
                let lines = new.components(separatedBy: "\n")
                let displayLines = lines.prefix(350)
                for (lIdx, line) in displayLines.enumerated() {
                    let prefix = NSAttributedString(string: "+ ", attributes: [
                        .font: font,
                        .foregroundColor: greenColor,
                        .backgroundColor: greenBg,
                        .paragraphStyle: style
                    ])
                    let highlighted = lIdx < 150 ? SyntaxHighlighter.shared.highlight(line: line, language: language, font: font, theme: renderTheme) : NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: greenColor])
                    let lineAttr = NSMutableAttributedString(attributedString: highlighted)
                    let range = NSRange(location: 0, length: lineAttr.length)
                    lineAttr.addAttribute(NSAttributedString.Key.backgroundColor, value: greenBg, range: range)
                    lineAttr.addAttribute(NSAttributedString.Key.paragraphStyle, value: style, range: range)

                    result.append(prefix)
                    result.append(lineAttr)
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: font,
                        .backgroundColor: greenBg,
                        .paragraphStyle: style
                    ]))
                }
                if lines.count > 350 {
                    result.append(NSAttributedString(string: "... (\(lines.count - 350) more added lines truncated)\n", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
            }
        } else if item.shortToolName == "Run" || (item.command != nil && !(item.command?.isEmpty ?? true)) || (item.output != nil && !(item.output?.isEmpty ?? true)) {
            let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            let cmdFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let textColor = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor

            let cmd = item.command ?? (item.shortToolName == "Run" ? item.displayTitle : nil)
            if let cmd, !cmd.isEmpty {
                let prefix = NSAttributedString(string: "$ ", attributes: [
                    .font: cmdFont,
                    .foregroundColor: renderTheme.keyword,
                    .paragraphStyle: style
                ])
                let cmdHighlighted = SyntaxHighlighter.shared.highlight(line: cmd, language: "shell", font: cmdFont, theme: renderTheme)
                result.append(prefix)
                result.append(cmdHighlighted)
                if let out = item.output, !out.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: cmdFont,
                        .paragraphStyle: style
                    ]))
                }
            }
            if let out = item.output, !out.isEmpty {
                // Tool output is diagnostic content; rendering an unbounded
                // command result can monopolize the main thread during a
                // toggle. Keep enough head and tail to inspect the result
                // while bounding TextKit work.
                let maxChars = 24_000
                let safeOut: String
                if out.count > maxChars {
                    let head = out.prefix(16_000)
                    let tail = out.suffix(6_000)
                    safeOut = "\(head)\n\n... [\(out.count - 22_000) characters truncated for performance] ...\n\n\(tail)"
                } else {
                    safeOut = out
                }
                result.append(NSAttributedString(string: safeOut, attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: style
                ]))
            }
        } else if let sum = item.summary, !sum.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let textColor = NSColor(cgColor: theme.foreground.cgColor)?.withAlphaComponent(0.88) ?? .textColor
            result.append(NSAttributedString(string: sum, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ]))
        }

        cachedDetailAttributedString = result
        return result
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        if abs(cachedLayoutWidth - width) < 0.5, cachedLayoutHeight > 0 {
            return cachedLayoutHeight
        }

        let padding: CGFloat = 8
        let innerWidth = max(50, width - (padding * 2))
        var currentY: CGFloat = 32

        if !descriptionLabel.stringValue.isEmpty {
            let descHeight = descriptionHeight(width: innerWidth)
            currentY += descHeight + 6
        }

        if hasExpandableContent && isExpanded {
            if virtualizedDetailView == nil {
                installVirtualizedDetailView()
            }
            let detailTVWidth = max(40, innerWidth - 12)
            let maxDetailHeight: CGFloat = 320
            let rawHeight = detailContentHeight(width: detailTVWidth)
            let containerHeight = min(maxDetailHeight, rawHeight + 12)
            currentY += containerHeight + 8
        } else {
            currentY += 2
        }

        cachedLayoutWidth = width
        cachedLayoutHeight = currentY
        return currentY
    }

    private func descriptionHeight(width: CGFloat) -> CGFloat {
        if abs(cachedDescriptionHeightWidth - width) < 0.5, cachedDescriptionHeight > 0 {
            return cachedDescriptionHeight
        }
        let measured = measureAttributedTextHeight(descriptionLabel.attributedStringValue, maxWidth: width)
        cachedDescriptionHeightWidth = width
        cachedDescriptionHeight = measured
        return measured
    }

    public func applyLayout(width: CGFloat, animated: Bool) {
        let padding: CGFloat = 8
        let innerWidth = max(50, width - (padding * 2))

        // 1. Header Layout (Unified coordinate system with height 22 and center line at y = 11.0)
        headerContainer.frame = NSRect(x: padding, y: 6, width: innerWidth, height: 22)

        // Action badge size with icon + text (height 20, y: 1.0 -> center = 11.0)
        let textSize = actionTextLabel.intrinsicContentSize
        let iconWidth: CGFloat = 12
        let pillPaddingH: CGFloat = 6
        let pillSpacing: CGFloat = 4
        // Keep the action badge intact when the command title or right-side
        // metadata gets tight. The title is the expendable part of the row.
        let actionTextWidth = max(ceil(textSize.width) + 2, 28)
        let pillWidth = max(58, pillPaddingH + iconWidth + pillSpacing + actionTextWidth + pillPaddingH)
        let pillHeight: CGFloat = 20
        actionPillView.frame = NSRect(x: 0, y: 1.0, width: pillWidth, height: pillHeight)
        actionIconView.frame = NSRect(x: pillPaddingH, y: 4.0, width: iconWidth, height: 12)
        actionTextLabel.frame = NSRect(x: pillPaddingH + iconWidth + pillSpacing, y: 4.0, width: actionTextWidth + 2, height: 14)

        let leftX = pillWidth + 8

        // Right side metadata items (right-to-left layout to guarantee zero overlaps)
        var rightX = innerWidth
        if hasExpandableContent {
            rightX -= 10
            chevronImageView.frame = NSRect(x: rightX, y: 6.0, width: 10, height: 10)
            rightX -= 6

            if shouldShowOpenInEditorButton {
                rightX -= 18
                openInEditorButton.frame = NSRect(x: rightX, y: 3.0, width: 16, height: 16)
                openInEditorButton.alphaValue = 0.65
                openInEditorButton.isHidden = false
                rightX -= 6
            } else {
                openInEditorButton.alphaValue = 0.0
                openInEditorButton.isHidden = true
            }
        } else {
            openInEditorButton.alphaValue = 0.0
            openInEditorButton.isHidden = true
        }

        if item.status == .running {
            rightX -= 14
            progressIndicator.frame = NSRect(x: rightX, y: 4.0, width: 14, height: 14)
            rightX -= 6
        } else if item.status == .failed {
            rightX -= 14
            errorLabel.frame = NSRect(x: rightX, y: 3.5, width: 14, height: 15)
            rightX -= 6
        }

        // Diff stats (+ / -) (height 18, y: 2.0 -> center = 11.0)
        if diffStatsButton.badgeLabel.attributedStringValue.length > 0 {
            let dsSize = diffStatsButton.badgeLabel.attributedStringValue.size()
            let dsWidth = ceil(dsSize.width) + 12
            rightX -= dsWidth
            diffStatsButton.frame = NSRect(x: rightX, y: 2.0, width: dsWidth, height: 18)
            diffStatsButton.isHidden = false
            if diffStatsButton.superview == nil {
                headerContainer.addSubview(diffStatsButton)
            }
            rightX -= 6
        } else {
            diffStatsButton.isHidden = true
        }

        // Title (takes remaining space between leftX and rightX, height 14, y: 4.0 -> center = 11.0)
        let availableTitleWidth = max(20, rightX - leftX)
        let titleText = titleLabel.attributedStringValue.string
        let measuredTitleWidth: CGFloat
        if cachedTitleText == titleText {
            measuredTitleWidth = cachedTitleWidth
        } else {
            measuredTitleWidth = titleLabel.attributedStringValue.size().width
            cachedTitleText = titleText
            cachedTitleWidth = measuredTitleWidth
        }
        let titleWidth = min(measuredTitleWidth + 4, availableTitleWidth)
        titleLabel.frame = NSRect(x: leftX, y: 4.0, width: titleWidth, height: 14)

        var currentY: CGFloat = 32

        // 2. Description
        if !descriptionLabel.stringValue.isEmpty {
            let descHeight = descriptionHeight(width: innerWidth)
            let descFrame = NSRect(x: padding, y: currentY, width: innerWidth, height: descHeight)
            if animated {
                descriptionLabel.animator().frame = descFrame
            } else {
                descriptionLabel.frame = descFrame
            }
            currentY += descHeight + 6
        }

        // 3. Detail Container & Virtualized Editor
        if hasExpandableContent {
            let detailContentWidth = max(40, innerWidth - 12)
            let maxDetailHeight: CGFloat = 320

            if isExpanded {
                if detailContainer.superview == nil {
                    addSubview(detailContainer)
                }
                if virtualizedDetailView == nil {
                    installVirtualizedDetailView()
                }

                let rawHeight = detailContentHeight(width: detailContentWidth)
                let containerHeight = min(maxDetailHeight, rawHeight + 12)
                let detailFrame = NSRect(x: padding, y: currentY, width: innerWidth, height: containerHeight)
                let contentFrame = NSRect(x: 6, y: 6, width: detailContentWidth, height: max(10, containerHeight - 12))

                detailContainer.isHidden = false

                // The custom editor owns a small viewport and virtualizes the
                // lines it draws. Keep its frame at the viewport size; its
                // internal scrollOffsetY handles the full output height.
                virtualizedDetailView?.isHidden = false
                virtualizedDetailView?.frame = contentFrame
                virtualizedDetailView?.needsDisplay = true

                if animated {
                    detailContainer.animator().frame = detailFrame
                    detailContainer.animator().alphaValue = 1
                } else {
                    detailContainer.frame = detailFrame
                    detailContainer.alphaValue = 1
                }
                currentY += containerHeight + 8
            } else {
                if animated {
                    detailContainer.animator().alphaValue = 0
                    detailContainer.animator().frame = NSRect(x: padding, y: currentY, width: innerWidth, height: 0)
                } else {
                    detailContainer.alphaValue = 0
                    detailContainer.isHidden = true
                    detailContainer.removeFromSuperview()
                }
                virtualizedDetailView?.isHidden = true
                currentY += 2
            }
        }
    }

    public func finishAnimation() {
        if !isExpanded {
            detailContainer.isHidden = true
            detailContainer.removeFromSuperview()
        }
    }

    private func detailContentHeight(width: CGFloat) -> CGFloat {
        if abs(cachedDetailHeightWidth - width) < 0.5, cachedDetailHeight > 0 {
            return cachedDetailHeight
        }

        if virtualizedDetailView == nil, hasExpandableContent {
            installVirtualizedDetailView()
        }

        let measured = max(18, virtualizedDetailView?.totalDocumentHeight ?? 18)
        cachedDetailHeightWidth = width
        cachedDetailHeight = measured
        return measured
    }
}
