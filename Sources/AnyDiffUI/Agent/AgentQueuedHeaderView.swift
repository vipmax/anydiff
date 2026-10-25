import AppKit
import SwiftUI
import AnyDiffCore

public final class AgentQueuedHeaderView: NSView {
    public var onMoveUp: (() -> Void)?
    public var onMoveDown: (() -> Void)?
    public var onEdit: (() -> Void)?
    public var onDelete: (() -> Void)?

    private let badgeContainer = NSView()
    private let badgeIconView = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let separatorView = NSView()

    private let actionsContainer = NSView()
    private let moveUpButton = AgentHoverButton()
    private let moveDownButton = AgentHoverButton()
    private let editButton = AgentHoverButton()
    private let deleteButton = AgentHoverButton()

    private var currentPosition: Int = 1
    private var currentTotal: Int = 1
    private var currentTheme: Theme?
    private var currentAccentColor: Color = .accentColor

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        badgeContainer.wantsLayer = true
        badgeContainer.layerContentsRedrawPolicy = .onSetNeedsDisplay
        badgeContainer.layer?.cornerRadius = 6
        badgeContainer.layer?.masksToBounds = true
        badgeContainer.layer?.borderWidth = 1
        addSubview(badgeContainer)

        badgeIconView.wantsLayer = true
        badgeIconView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        badgeIconView.imageScaling = .scaleProportionallyDown
        badgeContainer.addSubview(badgeIconView)

        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.drawsBackground = false
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeContainer.addSubview(badgeLabel)

        separatorView.wantsLayer = true
        separatorView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        badgeContainer.addSubview(separatorView)

        actionsContainer.wantsLayer = true
        badgeContainer.addSubview(actionsContainer)

        configureActionButton(moveUpButton, symbolName: "chevron.up", pointSize: 9.5, weight: .bold, action: #selector(handleMoveUp))
        configureActionButton(moveDownButton, symbolName: "chevron.down", pointSize: 9.5, weight: .bold, action: #selector(handleMoveDown))
        configureActionButton(editButton, symbolName: "pencil", pointSize: 10, weight: .medium, action: #selector(handleEdit))
        configureActionButton(deleteButton, symbolName: "xmark", pointSize: 9.5, weight: .semibold, action: #selector(handleDelete))

        actionsContainer.addSubview(moveUpButton)
        actionsContainer.addSubview(moveDownButton)
        actionsContainer.addSubview(editButton)
        actionsContainer.addSubview(deleteButton)
    }

    private func configureActionButton(
        _ button: AgentHoverButton,
        symbolName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        action: Selector
    ) {
        button.wantsLayer = true
        button.layerContentsRedrawPolicy = .onSetNeedsDisplay
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.layer?.cornerRadius = 4
        button.layer?.masksToBounds = true

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    @objc private func handleMoveUp() { onMoveUp?() }
    @objc private func handleMoveDown() { onMoveDown?() }
    @objc private func handleEdit() { onEdit?() }
    @objc private func handleDelete() { onDelete?() }

    public func configure(
        position: Int,
        total: Int,
        theme: Theme,
        accentColor: Color
    ) {
        currentPosition = position
        currentTotal = total
        currentTheme = theme
        currentAccentColor = accentColor

        let accentNSColor = NSColor(accentColor)
        let fgNSColor = NSColor(cgColor: theme.foreground.cgColor) ?? .labelColor

        badgeContainer.layer?.backgroundColor = accentNSColor.withAlphaComponent(0.12).cgColor
        badgeContainer.layer?.borderColor = accentNSColor.withAlphaComponent(0.28).cgColor
        separatorView.layer?.backgroundColor = accentNSColor.withAlphaComponent(0.28).cgColor

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        badgeIconView.image = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
        badgeIconView.contentTintColor = accentNSColor

        let attr = NSMutableAttributedString()
        let posStr = NSAttributedString(
            string: "Queued #\(position)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accentNSColor
            ]
        )
        let subStr = NSAttributedString(
            string: " • sends after turn",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: fgNSColor.withAlphaComponent(0.65)
            ]
        )
        attr.append(posStr)
        attr.append(subStr)
        badgeLabel.attributedStringValue = attr

        let btnDefaultBg = NSColor.clear
        let btnHoverBg = accentNSColor.withAlphaComponent(0.22)
        let btnTint = accentNSColor

        for btn in [moveUpButton, moveDownButton, editButton] {
            btn.defaultBackgroundColor = btnDefaultBg
            btn.hoverBackgroundColor = btnHoverBg
            btn.contentTintColor = btnTint
        }

        deleteButton.defaultBackgroundColor = btnDefaultBg
        deleteButton.hoverBackgroundColor = NSColor.systemRed.withAlphaComponent(0.22)
        deleteButton.contentTintColor = btnTint

        moveUpButton.toolTip = "Move up"
        moveDownButton.toolTip = "Move down"
        editButton.toolTip = "Edit queued message"
        deleteButton.toolTip = "Remove from queue"

        let canMoveUp = position > 1
        let canMoveDown = position < total
        moveUpButton.isEnabled = canMoveUp
        moveUpButton.alphaValue = canMoveUp ? 1.0 : 0.35
        moveDownButton.isEnabled = canMoveDown
        moveDownButton.alphaValue = canMoveDown ? 1.0 : 0.35

        let showReorder = total > 1
        moveUpButton.isHidden = !showReorder
        moveDownButton.isHidden = !showReorder
    }

    public func applyLayout(width: CGFloat) {
        let headerHeight: CGFloat = 24
        let labelSize = badgeLabel.attributedStringValue.size()
        let textWidth = ceil(labelSize.width) + 2

        badgeIconView.frame = NSRect(x: 6, y: 5, width: 14, height: 14)
        badgeLabel.frame = NSRect(x: 24, y: 3, width: textWidth, height: 18)

        let separatorX = 24 + textWidth + 6
        separatorView.frame = NSRect(x: separatorX, y: 5, width: 1, height: 14)

        let btnSize: CGFloat = 20
        let btnSpacing: CGFloat = 2
        var visibleButtons: [AgentHoverButton] = []
        if currentTotal > 1 {
            visibleButtons.append(moveUpButton)
            visibleButtons.append(moveDownButton)
        }
        visibleButtons.append(editButton)
        visibleButtons.append(deleteButton)

        let actionsWidth = CGFloat(visibleButtons.count) * btnSize + CGFloat(max(0, visibleButtons.count - 1)) * btnSpacing
        let actionsStartX = separatorX + 6
        actionsContainer.frame = NSRect(x: actionsStartX, y: 2, width: actionsWidth, height: btnSize)

        var currentBtnX: CGFloat = 0
        for btn in visibleButtons {
            btn.frame = NSRect(x: currentBtnX, y: 0, width: btnSize, height: btnSize)
            currentBtnX += btnSize + btnSpacing
        }

        let totalBadgeWidth = min(width, actionsStartX + actionsWidth + 4)
        badgeContainer.frame = NSRect(x: 0, y: 0, width: totalBadgeWidth, height: headerHeight)
    }
}
